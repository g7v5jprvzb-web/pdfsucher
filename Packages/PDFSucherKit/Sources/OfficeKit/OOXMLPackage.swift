// OOXMLPackage.swift — 1.3 Office: the small XML reader and ZIP access shared by `PresentationSlides` (Task 6) and
// `WordPageSetup` (Task 7). Audit 2026-11-15: the ZIP reading goes through OOXMLKit's `ZipArchive` (one reader, one
// set of limits and ZIP64 rules) instead of a second reader of its own; XMLScan refuses entity declarations.
import Foundation
import OOXMLKit

/// Streams the start tags of an XML document (local names, namespace prefixes stripped).
final class XMLScan: NSObject, XMLParserDelegate {
    /// Return false to stop.
    private let visit: (String, [String: String]) -> Bool
    private init(visit: @escaping (String, [String: String]) -> Bool) { self.visit = visit }

    static func elements(in data: Data, visit: @escaping (_ localName: String, _ attributes: [String: String]) -> Bool) {
        let parser = XMLParser(data: data)
        let scan = XMLScan(visit: visit)
        parser.delegate = scan
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    /// The `r:id` attribute (officeDocument relationships namespace), whatever its prefix.
    static func relationshipID(_ attributes: [String: String]) -> String? {
        attributes.first { $0.key.hasSuffix(":id") }?.value
    }

    // Like OOXMLNode: no DOCTYPE entities in Office parts, so a "billion laughs" part stops at its declaration.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if !visit(local, attributeDict) { parser.abortParsing() }
    }
}

extension ZipArchive {
    /// Largest uncompressed part OfficeKit reads: only the small XML parts of a package (OOXMLKit allows 512 MB).
    static let officePartLimit = 64 * 1024 * 1024

    /// The package at `url`. I/O errors reading the file are thrown unchanged; a file that is no readable ZIP
    /// throws `ZipError`.
    init(officePackage url: URL) throws {
        // `.mappedIfSafe`, not `.alwaysMapped`: Foundation maps only files on local volumes; a mapped file on a
        // network share or USB stick that is truncated or unmounted while we read would end in SIGBUS.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    /// The uncompressed part, or nil when missing, damaged, larger than `officePartLimit` or in an unsupported format.
    func data(at path: String) -> Data? {
        try? data(path, maxSize: UInt64(Self.officePartLimit))
    }
}
