// OOXMLNode.swift — Task 2 (OOXMLKit)
// Immutable XML tree built with Foundation's XMLParser (namespace processing on). mc:AlternateContent is
// resolved while parsing; DTDs are rejected outright (OOXML never contains one).
import Foundation

/// Namespace URIs (transitional ECMA-376). Strict-OOXML (purl.oclc.org/ooxml/...) is not mapped.
public enum NS {
    public static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    public static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    public static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    public static let c = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    public static let dgm = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    public static let dsp = "http://schemas.microsoft.com/office/drawing/2008/diagram"
    public static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    public static let v = "urn:schemas-microsoft-com:vml"
    public static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    public static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    public static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    /// Package relationships (`.rels` files).
    public static let relPkg = "http://schemas.openxmlformats.org/package/2006/relationships"
    /// The reserved `xml:` prefix (xml:space, xml:lang).
    public static let xml = "http://www.w3.org/XML/1998/namespace"
}

public enum XMLError: Error, Equatable {
    case malformed(String)
    case doctypeNotAllowed
    case tooDeep
}

public final class OOXMLNode: Sendable {
    /// Local name (no prefix).
    public let name: String
    /// Namespace URI, "" if none.
    public let ns: String
    /// Unprefixed attributes by local name; namespaced ones as "<namespaceURI>|<local>".
    public let attributes: [String: String]
    public let children: [OOXMLNode]
    /// Concatenated direct character data (raw). See `parse` for the whitespace rule.
    public let text: String

    public init(name: String, ns: String = "", attributes: [String: String] = [:],
                children: [OOXMLNode] = [], text: String = "") {
        self.name = name
        self.ns = ns
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    public func child(_ local: String, ns: String? = nil) -> OOXMLNode? {
        children.first { $0.name == local && (ns == nil || $0.ns == ns) }
    }

    public func children(_ local: String) -> [OOXMLNode] {
        children.filter { $0.name == local }
    }

    public func attr(_ local: String) -> String? { attributes[local] }

    public func attr(_ local: String, ns: String) -> String? { attributes[ns + "|" + local] }

    // MARK: parsing

    /// Namespaces whose mc:Choice we take (the renderer understands or safely ignores their content).
    static let supportedMCNamespaces: Set<String> = [
        "http://schemas.microsoft.com/office/powerpoint/2010/main",          // p14
        "http://schemas.microsoft.com/office/drawing/2010/main",             // a14
        "http://schemas.microsoft.com/office/powerpoint/2012/main",          // p15
        "http://schemas.microsoft.com/office/drawing/2014/main",             // a16
        "http://schemas.microsoft.com/office/word/2010/wordprocessingShape", // wps
        "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup", // wpg
        "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing", // wp14
        "http://schemas.microsoft.com/office/word/2010/wordml",              // w14
        "http://schemas.microsoft.com/office/word/2012/wordml",              // w15
        NS.v,
    ]

    static let maxDepth = 256

    /// Parses a document and returns its root element.
    ///
    /// Whitespace-only text of an element that has child elements is dropped (pretty-printing), unless
    /// `xml:space="preserve"` is set on it or an ancestor. `a:t` / `w:t` text is always verbatim.
    /// `mc:AlternateContent` is replaced by the children of the first supported `mc:Choice`, else of
    /// `mc:Fallback`, else removed.
    public static func parse(_ data: Data) throws -> OOXMLNode {
        try parse(data, preferringFallbackOver: [])
    }

    /// Like `parse(_:)`, but a supported `mc:Choice` that requires one of `deferred` is taken only when the
    /// AlternateContent has no other supported Choice and no Fallback (SlideKit: legacy VML OLE choices carry no
    /// image; their Fallback has the `p:pic`).
    public static func parse(_ data: Data, preferringFallbackOver deferred: Set<String>) throws -> OOXMLNode {
        if containsDoctype(data) { throw XMLError.doctypeNotAllowed }
        let builder = TreeBuilder(deferred: deferred)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let ok = parser.parse()
        if let e = builder.failure { throw e }
        guard ok, let root = builder.root else {
            throw XMLError.malformed(parser.parserError?.localizedDescription ?? "no root element")
        }
        return root
    }

    /// Byte search for "<!DOCTYPE" in UTF-8 and UTF-16 (either byte order).
    private static func containsDoctype(_ data: Data) -> Bool {
        let word = Array("<!DOCTYPE".utf8)
        let patterns: [[UInt8]] = [
            word,
            word.flatMap { [$0, 0] },
            word.flatMap { [0, $0] },
        ]
        let bytes = [UInt8](data)
        for pat in patterns where bytes.count >= pat.count {
            let first = pat[0]
            var i = 0
            let last = bytes.count - pat.count
            while i <= last {
                if bytes[i] == first && bytes[i..<(i + pat.count)].elementsEqual(pat) { return true }
                i += 1
            }
        }
        return false
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    final class Open {
        let name: String
        let ns: String
        let attributes: [String: String]
        let preserve: Bool
        var children: [OOXMLNode] = []
        var text = ""
        var isAlternateContent = false
        var isChoice = false
        var isFallback = false
        var choiceSupported = false
        /// A supported Choice that requires a deferred namespace.
        var choiceDeferred = false
        // For AlternateContent: the chosen replacement, resolved as the choices end.
        var chosen: [OOXMLNode]?
        var fallback: [OOXMLNode]?
        var deferredChoice: [OOXMLNode]?
        init(name: String, ns: String, attributes: [String: String], preserve: Bool) {
            self.name = name; self.ns = ns; self.attributes = attributes; self.preserve = preserve
        }
    }

    var root: OOXMLNode?
    var failure: XMLError?
    /// Namespaces whose Choices lose against a Fallback (`OOXMLNode.parse(_:preferringFallbackOver:)`).
    private let deferred: Set<String>
    private var stack: [Open] = []
    private var scopes: [[String: String]] = [["xml": NS.xml]]
    private var pending: [String: String] = [:]

    init(deferred: Set<String>) {
        self.deferred = deferred
    }

    private func fail(_ e: XMLError, _ parser: XMLParser) {
        if failure == nil { failure = e }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        pending[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(.doctypeNotAllowed, parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(.doctypeNotAllowed, parser)
    }

    private static func split(_ qualified: String) -> (prefix: String, local: String) {
        if let i = qualified.firstIndex(of: ":") {
            return (String(qualified[..<i]), String(qualified[qualified.index(after: i)...]))
        }
        return ("", qualified)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if stack.count >= OOXMLNode.maxDepth { return fail(.tooDeep, parser) }
        if root != nil && stack.isEmpty { return fail(.malformed("multiple root elements"), parser) }
        var scope = scopes.last ?? [:]
        if !pending.isEmpty {
            for (k, v) in pending { scope[k] = v }
            pending.removeAll()
        }
        scopes.append(scope)

        let local = Self.split(qName ?? elementName).local
        let ns = namespaceURI ?? ""

        var attrs: [String: String] = [:]
        for (key, value) in attributeDict {
            let (prefix, name) = Self.split(key)
            if prefix.isEmpty {
                attrs[name] = value
            } else if let uri = scope[prefix] {
                attrs[uri + "|" + name] = value
            } else {
                attrs[key] = value   // undeclared prefix (parser normally rejects this)
            }
        }
        let explicit = attrs[NS.xml + "|space"]
        let preserve = explicit.map { $0 == "preserve" } ?? (stack.last?.preserve ?? false)
        let node = Open(name: local, ns: ns, attributes: attrs, preserve: preserve)
        if ns == NS.mc {
            switch local {
            case "AlternateContent": node.isAlternateContent = true
            case "Choice":
                node.isChoice = true
                if let req = attrs["Requires"] {
                    let prefixes = req.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                    node.choiceSupported = !prefixes.isEmpty && prefixes.allSatisfy {
                        scope[String($0)].map(OOXMLNode.supportedMCNamespaces.contains) ?? false
                    }
                    node.choiceDeferred = prefixes.contains { scope[String($0)].map(deferred.contains) ?? false }
                }
            case "Fallback": node.isFallback = true
            default: break
            }
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        _ = scopes.popLast()
        let parent = stack.last

        if node.isChoice, let parent, parent.isAlternateContent {
            if node.choiceSupported, node.choiceDeferred {
                if parent.deferredChoice == nil { parent.deferredChoice = node.children }
            } else if node.choiceSupported, parent.chosen == nil {
                parent.chosen = node.children
            }
            return
        }
        if node.isFallback, let parent, parent.isAlternateContent {
            if parent.fallback == nil { parent.fallback = node.children }
            return
        }
        if node.isAlternateContent {
            let replacement = node.chosen ?? node.fallback ?? node.deferredChoice ?? []
            if let parent { parent.children.append(contentsOf: replacement) }
            else if root == nil { root = nil; fail(.malformed("AlternateContent as root"), parser) }
            return
        }

        var text = node.text
        let verbatim = node.name == "t" && (node.ns == NS.a || node.ns == NS.w)
        if !verbatim, !node.preserve, !node.children.isEmpty,
           text.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            text = ""
        }
        let built = OOXMLNode(name: node.name, ns: node.ns, attributes: node.attributes,
                            children: node.children, text: text)
        if let parent { parent.children.append(built) } else { root = built }
    }
}
