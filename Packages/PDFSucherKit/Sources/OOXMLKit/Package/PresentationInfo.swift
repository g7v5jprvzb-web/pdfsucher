// PresentationInfo.swift — Task 2 addendum (OOXMLKit)
// Slide list, visibility, numbering and size of a .pptx/.pptm package.
import CoreGraphics
import Foundation

public enum PresentationInfoError: Error, Equatable {
    case noPresentation
    case malformed(String)
}

public struct PresentationInfo: Sendable {
    public struct Slide: Sendable, Equatable {
        public let partPath: String
        public let hidden: Bool
        public let powerPointNumber: Int

        public init(partPath: String, hidden: Bool, powerPointNumber: Int) {
            self.partPath = partPath
            self.hidden = hidden
            self.powerPointNumber = powerPointNumber
        }
    }

    public let presentationPart: String
    /// All slides in p:sldIdLst order, hidden ones included.
    public let slides: [Slide]
    public var visibleSlides: [Slide] { slides.filter { !$0.hidden } }
    /// p:sldSz in points (EMU / 12700); 720×540 if missing.
    public let slideSize: CGSize

    static let contentTypes = [
        "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
        "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
    ]

    public init(package: OPCPackage) throws {
        var part: String?
        for rel in package.relationships(of: "").values.sorted(by: { $0.id < $1.id })
        where rel.type.hasSuffix("/officeDocument") && !rel.external {
            let p = package.resolve(rel.target, from: "")
            if (try? package.data(p)) != nil { part = p; break }
        }
        if part == nil {
            for t in Self.contentTypes {
                if let p = package.mainPart(forType: t) { part = p; break }
            }
        }
        guard let presentationPart = part else { throw PresentationInfoError.noPresentation }
        self.presentationPart = presentationPart

        let root: OOXMLNode
        do { root = try package.xml(presentationPart) }
        catch { throw PresentationInfoError.malformed("\(presentationPart): \(error)") }

        let first = root.attr("firstSlideNum").flatMap { Int($0) } ?? 1
        let rels = package.relationships(of: presentationPart)
        var slides: [Slide] = []
        for id in root.child("sldIdLst", ns: NS.p)?.children("sldId") ?? [] {
            guard let rid = id.attr("id", ns: NS.r), let rel = rels[rid], !rel.external else { continue }
            let path = package.resolve(rel.target, from: presentationPart)
            guard let data = try? package.data(path) else { continue }
            var hidden = false
            // office-speed: the root tag alone decides (parsing every slide whole took two thirds of opening a deck);
            // only a slide whose root says hidden is parsed whole, so one that does not parse stays visible as before.
            if Self.rootShowsHidden(data), let sld = try? OOXMLNode.parse(data) {
                let show = sld.attr("show")?.lowercased()
                hidden = show == "0" || show == "false"
            }
            slides.append(Slide(partPath: path, hidden: hidden, powerPointNumber: slides.count + first))
        }
        self.slides = slides

        var size = CGSize(width: 720, height: 540)
        if let sz = root.child("sldSz", ns: NS.p),
           let cx = sz.attr("cx").flatMap({ Double($0) }), let cy = sz.attr("cy").flatMap({ Double($0) }),
           cx > 0, cy > 0 {
            size = CGSize(width: cx / 12700, height: cy / 12700)
        }
        self.slideSize = size
    }

    /// Whether the first element of `data` has `show="0"`/`"false"` (any case): the parser stops after that tag. A
    /// DOCTYPE or entity declaration stops it before any element (false; such a part does not parse anyway).
    static func rootShowsHidden(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        let reader = RootShowReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        let show = reader.show?.lowercased()
        return show == "0" || show == "false"
    }
}

/// Reads the `show` attribute of the first element, then stops the parser.
private final class RootShowReader: NSObject, XMLParserDelegate {
    var show: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        show = attributeDict["show"]
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }
}
