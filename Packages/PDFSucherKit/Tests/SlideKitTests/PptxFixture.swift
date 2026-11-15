// PptxFixture.swift — Task 9 (SlideKit tests)
// Writes a minimal .pptx (presentation, master, layout, slides, theme, media) for rendering tests, and reads
// pixels back from a rendered slide.
import CoreGraphics
import Foundation
import ImageIO
import OOXMLKit
import TestSupport
@testable import SlideKit

private let relNS = NS.relPkg
private let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
let pNS = "xmlns:p=\"\(NS.p)\" xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\""

/// Fixture XML snippets. Coordinates are in points (converted to EMU).
enum X {
    static func emu(_ pt: Double) -> Int { Int(pt * 12700) }

    static func xfrm(_ r: CGRect?) -> String {
        guard let r else { return "" }
        return "<a:xfrm><a:off x=\"\(emu(r.minX))\" y=\"\(emu(r.minY))\"/><a:ext cx=\"\(emu(r.width))\" cy=\"\(emu(r.height))\"/></a:xfrm>"
    }

    static func solid(_ hex: String) -> String { "<a:solidFill><a:srgbClr val=\"\(hex)\"/></a:solidFill>" }

    /// `ph` is the inner attributes of `p:ph`, e.g. `type="title"` or `idx="1"`.
    static func sp(_ id: Int = 2, _ frame: CGRect?, fill: String? = nil, ph: String? = nil, hidden: Bool = false,
                   extra: String = "", txBody: String? = nil) -> String {
        let nvPr = ph.map { "<p:nvPr><p:ph \($0)/></p:nvPr>" } ?? "<p:nvPr/>"
        let geom = frame == nil && ph != nil ? "" : "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"s\(id)\"\(hidden ? " hidden=\"1\"" : "")/><p:cNvSpPr/>\(nvPr)</p:nvSpPr>"
            + "<p:spPr>\(xfrm(frame))\(geom)\(fill.map(solid) ?? "")\(extra)</p:spPr>\(txBody ?? "")</p:sp>"
    }

    static func pic(_ id: Int = 3, _ frame: CGRect, rId: String) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"p\(id)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
            + "<p:blipFill><a:blip r:embed=\"\(rId)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
            + "<p:spPr>\(xfrm(frame))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    static func bgColor(_ hex: String) -> String { "<p:bg><p:bgPr>\(solid(hex))<a:effectLst/></p:bgPr></p:bg>" }
}

struct PptxFixture {
    struct Slide {
        var shapes = ""
        var bg: String?
        var rootAttrs = ""
        var clrMapOvr: String?
        /// Extra `Relationship` elements of the slide.
        var rels = ""
        var hasLayoutRel = true
    }

    var cx = 12_192_000, cy = 6_858_000
    /// Raw attributes of `p:sldSz` (overrides cx/cy), e.g. `cx="0" cy="1"`.
    var sldSzAttrs: String?
    var theme = PptxFixture.defaultTheme
    var includeTheme = true
    var includeMaster = true
    var includeLayout = true
    var masterBg: String? = X.bgColor("FFFFFF")
    var masterShapes = ""
    /// Content of the master's `p:txStyles` (titleStyle, bodyStyle, otherStyle).
    var masterTxStyles = ""
    /// Extra children of `p:presentation`, e.g. `p:defaultTextStyle`.
    var presentationExtra = ""
    var masterClrMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
    var layoutBg: String?
    var layoutShapes = ""
    var layoutAttrs = ""
    var layoutClrMapOvr: String?
    var slides: [Slide] = [Slide()]
    /// Extra package parts (path → data), e.g. media.
    var media: [String: Data] = [:]
    /// Content of `ppt/tableStyles.xml` (an `a:tblStyleLst`), linked from the presentation; nil = no part.
    var tableStyles: String?

    static let defaultTheme = """
    <a:theme xmlns:a="\(NS.a)" name="T"><a:themeElements>
    <a:clrScheme name="C"><a:dk1><a:srgbClr val="111111"/></a:dk1><a:lt1><a:srgbClr val="EEEEEE"/></a:lt1>
    <a:dk2><a:srgbClr val="222222"/></a:dk2><a:lt2><a:srgbClr val="DDDDDD"/></a:lt2>
    <a:accent1><a:srgbClr val="0000FF"/></a:accent1><a:accent2><a:srgbClr val="00FF00"/></a:accent2>
    <a:accent3><a:srgbClr val="FF0000"/></a:accent3><a:accent4><a:srgbClr val="FFFF00"/></a:accent4>
    <a:accent5><a:srgbClr val="00FFFF"/></a:accent5><a:accent6><a:srgbClr val="FF00FF"/></a:accent6>
    <a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="F"><a:majorFont><a:latin typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="S"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    <a:solidFill><a:srgbClr val="808080"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
    </a:themeElements></a:theme>
    """

    private static func rel(_ id: String, _ type: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(relBase)\(type)\" Target=\"\(target)\"/>"
    }

    private static func cSld(_ bg: String?, _ shapes: String) -> String {
        "<p:cSld>\(bg ?? "")<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr/>\(shapes)</p:spTree></p:cSld>"
    }

    func data() -> Data {
        var b = OOXMLBuilder()
        b.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\">\(Self.rel("r1", "officeDocument", "ppt/presentation.xml"))</Relationships>")
        let ids = slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 10)\"/>" }.joined()
        b.add("ppt/presentation.xml", "<p:presentation \(pNS)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
              + "<p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz \(sldSzAttrs ?? "cx=\"\(cx)\" cy=\"\(cy)\"")/>\(presentationExtra)</p:presentation>")
        var presRels = Self.rel("rId1", "slideMaster", "slideMasters/slideMaster1.xml")
        for i in slides.indices { presRels += Self.rel("rId\(i + 10)", "slide", "slides/slide\(i + 1).xml") }
        if let tableStyles {
            presRels += Self.rel("rId2", "tableStyles", "tableStyles.xml")
            b.add("ppt/tableStyles.xml", tableStyles)
        }
        b.add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relNS)\">\(presRels)</Relationships>")

        if includeMaster {
            b.add("ppt/slideMasters/slideMaster1.xml", "<p:sldMaster \(pNS)>\(Self.cSld(masterBg, masterShapes))\(masterClrMap)"
                  + (masterTxStyles.isEmpty ? "" : "<p:txStyles>\(masterTxStyles)</p:txStyles>") + "</p:sldMaster>")
            b.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", "<Relationships xmlns=\"\(relNS)\">"
                  + Self.rel("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")
                  + Self.rel("rId2", "theme", "../theme/theme1.xml") + "</Relationships>")
        }
        if includeTheme { b.add("ppt/theme/theme1.xml", theme) }
        if includeLayout {
            let ovr = layoutClrMapOvr ?? "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
            b.add("ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout \(pNS) \(layoutAttrs)>\(Self.cSld(layoutBg, layoutShapes))\(ovr)</p:sldLayout>")
            b.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", "<Relationships xmlns=\"\(relNS)\">"
                  + Self.rel("rId1", "slideMaster", "../slideMasters/slideMaster1.xml") + "</Relationships>")
        }
        for (i, s) in slides.enumerated() {
            let ovr = s.clrMapOvr ?? "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
            b.add("ppt/slides/slide\(i + 1).xml", "<p:sld \(pNS) \(s.rootAttrs)>\(Self.cSld(s.bg, s.shapes))\(ovr)</p:sld>")
            let layoutRel = s.hasLayoutRel ? Self.rel("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") : ""
            b.add("ppt/slides/_rels/slide\(i + 1).xml.rels", "<Relationships xmlns=\"\(relNS)\">\(layoutRel)\(s.rels)</Relationships>")
        }
        for (path, d) in media.sorted(by: { $0.key < $1.key }) { b.addData(path, d) }
        return b.build()
    }

    /// Writes the deck to a temporary file and opens it. The file is removed when the returned holder dies.
    func open() throws -> OpenedDeck {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slidekit-\(UUID().uuidString).pptx")
        try data().write(to: url)
        return OpenedDeck(url: url, deck: try SlideDeck(url: url))
    }

    /// Writes the deck once and opens it with each substitution (same file, separate decks).
    func open(_ subs: [FontSubstitution]) throws -> (holder: OpenedDeck, decks: [SlideDeck]) {
        let first = try open()
        return (first, try subs.map { try SlideDeck(url: first.url, fontSubstitution: $0) })
    }

    static func imageRel(_ id: String, _ target: String) -> String { rel(id, "image", target) }
}

final class OpenedDeck {
    let url: URL
    let deck: SlideDeck
    init(url: URL, deck: SlideDeck) { self.url = url; self.deck = deck }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A 4×4 PNG of one color.
func pngData(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// RGBA8 sRGB pixels, row 0 = top.
struct Pixels: Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, draw: (CGContext) -> Void) {
        self.width = width
        self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(ctx)
        }
        bytes = buf
    }

    init(image: CGImage) {
        self.init(width: image.width, height: image.height) {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// "RRGGBB" at (x, y) from the top left; "transparent" for alpha 0.
    func hex(_ x: Int, _ y: Int) -> String {
        let i = (y * width + x) * 4
        if bytes[i + 3] == 0 { return "transparent" }
        return String(format: "%02X%02X%02X", bytes[i], bytes[i + 1], bytes[i + 2])
    }
}

extension SlideDeck {
    /// Slide i drawn 1:1 (1 px per point) into a bitmap.
    func pixels(_ i: Int) -> Pixels {
        let w = Int(slideSize.width), h = Int(slideSize.height)
        return Pixels(width: w, height: h) { draw(i, in: $0, rect: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
}
