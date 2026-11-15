// PresentationSlides.swift — 1.3 Office Task 6: which slides of a .pptx PowerPoint shows, with PowerPoint's numbers.
// Minimal own reader with the same semantics as OOXMLKit's `PresentationInfo` (branch `slidekit`); to be replaced by
// it once that branch is merged (decisions.md).
import CoreGraphics
import Foundation
import IndexKit

enum PresentationSlides {
    /// One entry of `p:sldIdLst`, in presentation order.
    struct Slide: Equatable {
        /// Package path without leading slash, e.g. `ppt/slides/slide1.xml`.
        let partPath: String
        /// `show="0"` on `p:sld`: PowerPoint skips it in the show, Quick Look leaves it out of the preview.
        let hidden: Bool
        /// The number PowerPoint shows for it: position in `p:sldIdLst` (hidden slides count) + `firstSlideNum` − 1.
        let powerPointNumber: Int
    }

    /// PowerPoint numbers of the visible slides, in presentation order (what Quick Look's HTML contains).
    /// Throws `LayoutSourceError.unreadable` when the file is not a readable presentation package (not a ZIP, no
    /// `ppt/presentation.xml`, a slide relationship missing); I/O errors reading the file propagate unchanged.
    static let unreadableReason = "Vorschau nicht möglich"

    static func visibleSlideNumbers(of url: URL) throws -> [Int] {
        try slides(of: url).filter { !$0.hidden }.map(\.powerPointNumber)
    }

    static func slides(of url: URL) throws -> [Slide] {
        let unreadable = LayoutSourceError.unreadable(url, reason: unreadableReason)
        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch is ZipArchive.Failure { throw unreadable }
        guard let presentation = archive.data(at: "ppt/presentation.xml") else { throw unreadable }
        let relationships = archive.data(at: "ppt/_rels/presentation.xml.rels").map(Self.relationships) ?? [:]
        let first = firstSlideNumber(inPresentationXML: presentation)
        var result: [Slide] = []
        for (index, id) in slideRelationshipIDs(inPresentationXML: presentation).enumerated() {
            guard let target = relationships[id] else { throw unreadable }
            let path = resolve(target, base: "ppt")
            let hidden = archive.data(at: path).map(isHidden) ?? false
            result.append(Slide(partPath: path, hidden: hidden, powerPointNumber: first + index))
        }
        return result
    }

    /// PowerPoint's default slide size (4:3, `p:sldSz` 9144000 × 6858000 EMU) in points.
    static let defaultSlideSize = CGSize(width: 720, height: 540)

    /// The slide size from `p:sldSz` in points (EMU / 12 700), `defaultSlideSize` when the presentation has none (or
    /// an unusable one). Nil when the file is not a readable presentation package. Reads the link target.
    static func slideSize(of url: URL) -> CGSize? {
        guard let archive = try? ZipArchive(url: url.resolvingSymlinksInPath()),
              let presentation = archive.data(at: "ppt/presentation.xml") else { return nil }
        var size = defaultSlideSize
        XMLScan.elements(in: presentation) { name, attributes in
            guard name == "sldSz" else { return true }
            if let cx = attributes["cx"].flatMap(Double.init), let cy = attributes["cy"].flatMap(Double.init),
               cx > 0, cy > 0, cx.isFinite, cy.isFinite {
                size = CGSize(width: cx / 12_700, height: cy / 12_700)
            }
            return false
        }
        return size
    }

    // MARK: XML

    /// `p:presentation@firstSlideNum`, default 1.
    static func firstSlideNumber(inPresentationXML data: Data) -> Int {
        var number = 1
        XMLScan.elements(in: data) { name, attributes in
            guard name == "presentation" else { return true }
            if let value = attributes["firstSlideNum"], let parsed = Int(value) { number = parsed }
            return false
        }
        return number
    }

    /// `r:id` of each `p:sldId` inside `p:sldIdLst`, in order.
    private static func slideRelationshipIDs(inPresentationXML data: Data) -> [String] {
        var ids: [String] = []
        XMLScan.elements(in: data) { name, attributes in
            if name == "sldId", let id = XMLScan.relationshipID(attributes) { ids.append(id) }
            return true
        }
        return ids
    }

    /// Relationship id → target of the slide relationships.
    private static func relationships(_ data: Data) -> [String: String] {
        var map: [String: String] = [:]
        XMLScan.elements(in: data) { name, attributes in
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"],
               attributes["Type"]?.hasSuffix("/slide") ?? false, attributes["TargetMode"] != "External" {
                map[id] = target
            }
            return true
        }
        return map
    }

    private static func isHidden(_ slideXML: Data) -> Bool {
        var hidden = false
        XMLScan.elements(in: slideXML) { name, attributes in
            guard name == "sld" else { return true }
            hidden = attributes["show"] == "0" || attributes["show"] == "false"
            return false
        }
        return hidden
    }

    /// Package path of a relationship target: absolute (`/ppt/…`) or relative to the source part's folder.
    static func resolve(_ target: String, base: String) -> String {
        var parts: [Substring] = target.hasPrefix("/") ? [] : base.split(separator: "/")
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}
