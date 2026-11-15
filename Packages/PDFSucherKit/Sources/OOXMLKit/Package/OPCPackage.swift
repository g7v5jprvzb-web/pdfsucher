// OPCPackage.swift — Task 2 (OOXMLKit)
// Open Packaging Conventions on top of ZipArchive: parts, relationships, content types.
import Foundation

public struct Relationship: Sendable, Equatable, Hashable {
    public let id: String
    public let type: String
    public let target: String
    public let external: Bool

    public init(id: String, type: String, target: String, external: Bool) {
        self.id = id
        self.type = type
        self.target = target
        self.external = external
    }
}

public struct OPCPackage: Sendable {
    private let zip: ZipArchive
    /// Lower-cased entry name -> actual entry name (first wins); OPC part names are case-insensitive.
    private let lowerNames: [String: String]
    /// Overrides in document order: part path without leading slash, content type.
    private let overrides: [(part: String, type: String)]

    public init(zip: ZipArchive) {
        self.zip = zip
        var lower: [String: String] = [:]
        for n in zip.entryNames where lower[n.lowercased()] == nil { lower[n.lowercased()] = n }
        self.lowerNames = lower

        var found: [(String, String)] = []
        let ctName = "[Content_Types].xml"
        if let actual = zip.contains(ctName) ? ctName : lower[ctName.lowercased()],
           let data = try? zip.data(actual),
           let root = try? OOXMLNode.parse(data) {
            for o in root.children("Override") {
                if let part = o.attr("PartName"), let type = o.attr("ContentType") {
                    found.append((part.hasPrefix("/") ? String(part.dropFirst()) : part, type))
                }
            }
        }
        self.overrides = found
    }

    private func entryName(_ partPath: String) -> String {
        let p = partPath.hasPrefix("/") ? String(partPath.dropFirst()) : partPath
        if zip.contains(p) { return p }
        return lowerNames[p.lowercased()] ?? p
    }

    public func data(_ partPath: String) throws -> Data {
        try zip.data(entryName(partPath))
    }

    public func xml(_ partPath: String) throws -> OOXMLNode {
        try OOXMLNode.parse(try data(partPath))
    }

    /// Relationships of a part, keyed by Id. "" is the package root. Missing or unreadable rels → [:].
    public func relationships(of partPath: String) -> [String: Relationship] {
        let part = partPath.hasPrefix("/") ? String(partPath.dropFirst()) : partPath
        let relsPath: String
        if part.isEmpty {
            relsPath = "_rels/.rels"
        } else if let slash = part.lastIndex(of: "/") {
            relsPath = part[..<slash] + "/_rels/" + part[part.index(after: slash)...] + ".rels"
        } else {
            relsPath = "_rels/" + part + ".rels"
        }
        guard let root = try? xml(relsPath) else { return [:] }
        var out: [String: Relationship] = [:]
        for r in root.children("Relationship") {
            guard let id = r.attr("Id"), let target = r.attr("Target") else { continue }
            let external = r.attr("TargetMode")?.lowercased() == "external"
            if out[id] == nil {
                out[id] = Relationship(id: id, type: r.attr("Type") ?? "", target: target, external: external)
            }
        }
        return out
    }

    /// Resolves an internal relationship target against the part that holds it. Result has no leading slash.
    /// External targets must not be passed in (they are not paths).
    public func resolve(_ target: String, from partPath: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var comps: [Substring] = []
        if !decoded.hasPrefix("/") {
            let part = partPath.hasPrefix("/") ? String(partPath.dropFirst()) : partPath
            comps = part.split(separator: "/", omittingEmptySubsequences: true)
            if !comps.isEmpty { comps.removeLast() }
        }
        for c in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch c {
            case ".": continue
            case "..": if !comps.isEmpty { comps.removeLast() }
            default: comps.append(c)
            }
        }
        return comps.joined(separator: "/")
    }

    /// Part path (no leading slash) of the first Override with this content type.
    public func mainPart(forType contentType: String) -> String? {
        overrides.first { $0.type == contentType }?.part
    }
}
