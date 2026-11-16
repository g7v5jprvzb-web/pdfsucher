// WordPreviewText.swift — 1.4.0 P5: the body text of a .docx at once, before its layout
import Foundation
import IndexKit
import OOXMLKit

/// The text of the main document part of a Word package (`.docx`, `.docm`, `.dotx`, `.dotm`), read straight from its
/// XML: every `w:t`, a line break per paragraph, `w:br`/`w:cr`, a space per `w:tab`; deleted revisions (`w:delText`),
/// headers, footers and notes are left out. Normalized like every stored page (`TextNormalizer`). Phase 1 stores it as one
/// provisional page so the document can be searched before the layout phase replaces it with the real pages and word
/// boxes. nil when the package or its main part cannot be read (the document then just waits for its layout, as before).
public enum WordPreviewText {
    static let extensions: Set<String> = ["docx", "docm", "dotx", "dotm"]

    public static func text(of url: URL) -> String? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let archive = try? ZipArchive(officePackage: url) else { return nil }
        var part = "word/document.xml"
        if let rels = archive.data(at: "_rels/.rels") {
            XMLScan.elements(in: rels) { name, attributes in
                guard name == "Relationship", attributes["Type"]?.hasSuffix("/officeDocument") ?? false,
                      let target = attributes["Target"] else { return true }
                part = PresentationSlides.resolve(target, base: "")
                return false
            }
        }
        guard let xml = archive.data(at: part) else { return nil }
        let collector = Collector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return TextNormalizer.normalize(collector.text)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var text = ""
        private var inText = false

        private static func local(_ name: String) -> Substring { name.split(separator: ":").last ?? Substring(name) }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch Self.local(elementName) {
            case "t": inText = true
            case "tab": text += " "
            case "br", "cr": text += "\n"
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            switch Self.local(elementName) {
            case "t": inText = false
            case "p": text += "\n"
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { text += string }
        }
    }
}
