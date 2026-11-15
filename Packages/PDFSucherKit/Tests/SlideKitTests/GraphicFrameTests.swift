// GraphicFrameTests.swift — Task 12b (SlideKit tests)
// SmartArt (the stored dsp drawing), OLE still images (oleObj/p:pic, mc:Fallback, legacy VML), video posters and
// unknown graphic frames.
import CoreGraphics
import Foundation
import ImageIO
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

extension X {
    static let dspNS = "http://schemas.microsoft.com/office/drawing/2008/diagram"
    static let diagramURI = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let oleURI = "http://schemas.openxmlformats.org/presentationml/2006/ole"
    static let relTypeBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// A `Relationship` element; `type` is a full URI or a suffix of the officeDocument relationship base.
    static func rel(_ id: String, _ type: String, _ target: String) -> String {
        let t = type.hasPrefix("http") ? type : relTypeBase + type
        return "<Relationship Id=\"\(id)\" Type=\"\(t)\" Target=\"\(target)\"/>"
    }

    /// A `p:graphicFrame` at `frame` with the given graphicData content.
    static func frame(_ id: Int, _ frame: CGRect, uri: String, _ content: String, hidden: Bool = false) -> String {
        "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"f\(id)\"\(hidden ? " hidden=\"1\"" : "")/>"
            + "<p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"\(emu(frame.minX))\" y=\"\(emu(frame.minY))\"/><a:ext cx=\"\(emu(frame.width))\" cy=\"\(emu(frame.height))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"\(uri)\">\(content)</a:graphicData></a:graphic></p:graphicFrame>"
    }

    static let relIds = "<dgm:relIds xmlns:dgm=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\" r:dm=\"rId5\" r:lo=\"rId6\" r:qs=\"rId7\" r:cs=\"rId8\"/>"

    /// A diagram data part, optionally with the `dsp:dataModelExt` that names the drawing relationship.
    static func diagramData(drawingRel: String?) -> String {
        let ext = drawingRel.map {
            "<dgm:extLst><a:ext uri=\"http://schemas.microsoft.com/office/drawing/2008/diagram\">"
                + "<dsp:dataModelExt xmlns:dsp=\"\(dspNS)\" relId=\"\($0)\" minVer=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\"/></a:ext></dgm:extLst>"
        } ?? ""
        return "<dgm:dataModel xmlns:dgm=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\" xmlns:a=\"\(NS.a)\"><dgm:ptLst/>\(ext)</dgm:dataModel>"
    }

    /// A dsp drawing part: one red shape at (20, 10) 100×50 in frame space with the text `text`, its text rect
    /// `txXfrm` (frame space) if given.
    static func diagramDrawing(text: String, txXfrm: CGRect?, extra: String = "") -> String {
        let tx = txXfrm.map {
            "<dsp:txXfrm><a:off x=\"\(emu($0.minX))\" y=\"\(emu($0.minY))\"/><a:ext cx=\"\(emu($0.width))\" cy=\"\(emu($0.height))\"/></dsp:txXfrm>"
        } ?? ""
        return "<dsp:drawing xmlns:dsp=\"\(dspNS)\" xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\"><dsp:spTree>"
            + "<dsp:nvGrpSpPr><dsp:cNvPr id=\"0\" name=\"\"/><dsp:cNvGrpSpPr/></dsp:nvGrpSpPr><dsp:grpSpPr/>"
            + "<dsp:sp modelId=\"{1}\"><dsp:nvSpPr><dsp:cNvPr id=\"0\" name=\"\"/><dsp:cNvSpPr/></dsp:nvSpPr>"
            + "<dsp:spPr>\(xfrm(CGRect(x: 20, y: 10, width: 100, height: 50)))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            + "\(solid("FF0000"))<a:ln><a:noFill/></a:ln></dsp:spPr>"
            + "<dsp:style><a:lnRef idx=\"0\"><a:scrgbClr r=\"0\" g=\"0\" b=\"0\"/></a:lnRef><a:fillRef idx=\"1\"><a:scrgbClr r=\"0\" g=\"0\" b=\"0\"/></a:fillRef>"
            + "<a:effectRef idx=\"0\"><a:scrgbClr r=\"0\" g=\"0\" b=\"0\"/></a:effectRef><a:fontRef idx=\"minor\"><a:schemeClr val=\"dk1\"/></a:fontRef></dsp:style>"
            + "<dsp:txBody><a:bodyPr \(noInsets) anchor=\"t\"/><a:lstStyle/><a:p><a:r><a:rPr lang=\"de-DE\" sz=\"1000\"/><a:t>\(text)</a:t></a:r></a:p></dsp:txBody>"
            + tx + "</dsp:sp>\(extra)</dsp:spTree></dsp:drawing>"
    }

    /// `p:pic` inside an OLE object (its own xfrm is a dummy: the frame's xfrm places the image).
    static func olePic(rId: String, hidden: Bool = false) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"9\" name=\"o\"\(hidden ? " hidden=\"1\"" : "")/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
            + "<p:blipFill><a:blip r:embed=\"\(rId)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
            + "<p:spPr><a:xfrm><a:off x=\"1588\" y=\"1588\"/><a:ext cx=\"1588\" cy=\"1588\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }
}

@Suite struct SmartArtTests {
    static let frame = CGRect(x: 100, y: 100, width: 300, height: 200)

    private func deck(rels: String, drawing: String? = X.diagramDrawing(text: "Hallo SmartArt", txXfrm: CGRect(x: 20, y: 70, width: 200, height: 30)),
                      dataRel: String? = nil, drawingPath: String = "ppt/diagrams/drawing1.xml") throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.frame(4, Self.frame, uri: X.diagramURI, X.relIds),
                          rels: X.rel("rId5", "diagramData", "../diagrams/data1.xml") + rels)]
        f.media["ppt/diagrams/data1.xml"] = Data(X.diagramData(drawingRel: dataRel).utf8)
        if let drawing { f.media[drawingPath] = Data(drawing.utf8) }
        return try f.open()
    }

    static let drawingRelType = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"

    @Test func drawingPartIsDrawnWithItsText() throws {
        let o = try deck(rels: X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml"))
        let px = o.deck.pixels(0)
        // The shape: frame (100, 100) + (20, 10), 100×50.
        #expect(px.hex(170, 135) == "FF0000")
        #expect(px.hex(125, 115) == "FF0000")
        #expect(px.hex(225, 135) == "FFFFFF")
        // The text sits in txXfrm (frame + (20, 70), 200×30), not in the shape.
        #expect(o.deck.slideText(0) == "Hallo SmartArt")
        let boxes = o.deck.wordBoxes(0)
        try #require(boxes.count == 2)
        let b = boxes[0].box
        #expect(abs(b.minX - 120.0 / 960) < 0.003)
        #expect(b.minY >= 170.0 / 540 - 0.002 && b.maxY <= 200.0 / 540)
        // Dark text pixels below the red shape.
        var dark = 0
        for y in 170..<190 { for x in 120..<200 where px.hex(x, y).hasPrefix("1") { dark += 1 } }
        #expect(dark > 10)
    }

    @Test func textWithoutTxXfrmUsesTheShape() throws {
        let o = try deck(rels: X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml"),
                         drawing: X.diagramDrawing(text: "Innen", txXfrm: nil))
        #expect(o.deck.slideText(0) == "Innen")
        let b = try #require(o.deck.wordBoxes(0).first).box
        #expect(b.minY >= 110.0 / 540 - 0.002 && b.maxY <= 160.0 / 540)
    }

    @Test(arguments: ["ext", "number"]) func drawingPartFoundWithoutDiagramDrawingRelationship(_ how: String) throws {
        // Some other relationship type points at the drawing; found through dataModelExt or the part number.
        let o = try deck(rels: X.rel("rId9", "unknownType", "../diagrams/drawing1.xml"),
                         dataRel: how == "ext" ? "rId9" : nil)
        #expect(o.deck.pixels(0).hex(170, 135) == "FF0000")
        #expect(o.deck.slideText(0) == "Hallo SmartArt")
    }

    @Test func missingDrawingPartLeavesTheFrameEmpty() throws {
        for rels in ["", X.rel("rId9", Self.drawingRelType, "../diagrams/missing.xml")] {
            let o = try deck(rels: rels, drawing: nil)
            let px = o.deck.pixels(0)
            for (x, y) in [(170, 135), (110, 110), (390, 290)] { #expect(px.hex(x, y) == "FFFFFF") }
            #expect(o.deck.slideText(0) == "")
            #expect(o.deck.wordBoxes(0).isEmpty)
        }
        // Broken drawing XML and a missing relIds element: nothing drawn, no crash.
        let broken = try deck(rels: X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml"), drawing: "<dsp:drawing")
        #expect(broken.deck.pixels(0).hex(170, 135) == "FFFFFF")
        var f = PptxFixture()
        f.slides = [.init(shapes: X.frame(4, Self.frame, uri: X.diagramURI, ""))]
        let bare = try f.open()
        #expect(bare.deck.pixels(0).hex(170, 135) == "FFFFFF")
        #expect(bare.deck.slideText(0) == "")
    }

    @Test func nestedGroupsAndShapeOrderInText() throws {
        let group = "<dsp:grpSp><dsp:nvGrpSpPr><dsp:cNvPr id=\"0\" name=\"\"/><dsp:cNvGrpSpPr/></dsp:nvGrpSpPr><dsp:grpSpPr/>"
            + "<dsp:sp modelId=\"{2}\"><dsp:nvSpPr><dsp:cNvPr id=\"0\" name=\"\"/><dsp:cNvSpPr/></dsp:nvSpPr>"
            + "<dsp:spPr>\(X.xfrm(CGRect(x: 150, y: 120, width: 100, height: 50)))<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>"
            + "\(X.solid("0000FF"))</dsp:spPr><dsp:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"de-DE\" sz=\"1000\"/><a:t>Zweite</a:t></a:r></a:p></dsp:txBody></dsp:sp></dsp:grpSp>"
        let o = try deck(rels: X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml"),
                         drawing: X.diagramDrawing(text: "Erste", txXfrm: nil, extra: group))
        #expect(o.deck.slideText(0) == "Erste Zweite")
        #expect(o.deck.pixels(0).hex(300, 262) == "0000FF")
    }

    @Test func dataModelExtDecidesEvenWithOneDrawingRelationship() throws {
        // Two SmartArts, only the first has a stored drawing: the second must not borrow it.
        var f = PptxFixture()
        let second = X.relIds.replacingOccurrences(of: "rId5", with: "rId15")
        f.slides = [.init(shapes: X.frame(4, CGRect(x: 0, y: 0, width: 300, height: 200), uri: X.diagramURI, X.relIds)
                          + X.frame(5, CGRect(x: 500, y: 300, width: 300, height: 200), uri: X.diagramURI, second),
                          rels: X.rel("rId5", "diagramData", "../diagrams/data1.xml")
                          + X.rel("rId15", "diagramData", "../diagrams/data2.xml")
                          + X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml"))]
        f.media["ppt/diagrams/data1.xml"] = Data(X.diagramData(drawingRel: "rId9").utf8)
        f.media["ppt/diagrams/data2.xml"] = Data(X.diagramData(drawingRel: "rId29").utf8)
        f.media["ppt/diagrams/drawing1.xml"] = Data(X.diagramDrawing(text: "Eins", txXfrm: nil).utf8)
        let o = try f.open()
        let px = o.deck.pixels(0)
        #expect(px.hex(70, 35) == "FF0000")
        #expect(px.hex(570, 335) == "FFFFFF")
        #expect(o.deck.slideText(0) == "Eins")
    }

    @Test func theFrameTransformPlacesTheDrawing() throws {
        // Two SmartArt frames on one slide with their own drawings (found through dataModelExt).
        var f = PptxFixture()
        let second = X.relIds.replacingOccurrences(of: "rId5", with: "rId15")
        f.slides = [.init(shapes: X.frame(4, CGRect(x: 0, y: 0, width: 300, height: 200), uri: X.diagramURI, X.relIds)
                          + X.frame(5, CGRect(x: 500, y: 300, width: 300, height: 200), uri: X.diagramURI, second),
                          rels: X.rel("rId5", "diagramData", "../diagrams/data1.xml")
                          + X.rel("rId15", "diagramData", "../diagrams/data2.xml")
                          + X.rel("rId9", Self.drawingRelType, "../diagrams/drawing1.xml")
                          + X.rel("rId19", Self.drawingRelType, "../diagrams/drawing2.xml"))]
        f.media["ppt/diagrams/data1.xml"] = Data(X.diagramData(drawingRel: "rId9").utf8)
        f.media["ppt/diagrams/data2.xml"] = Data(X.diagramData(drawingRel: "rId19").utf8)
        f.media["ppt/diagrams/drawing1.xml"] = Data(X.diagramDrawing(text: "Eins", txXfrm: nil).utf8)
        f.media["ppt/diagrams/drawing2.xml"] = Data(X.diagramDrawing(text: "Zwei", txXfrm: nil).utf8)
        let o = try f.open()
        let px = o.deck.pixels(0)
        #expect(px.hex(70, 35) == "FF0000")
        #expect(px.hex(570, 335) == "FF0000")
        #expect(o.deck.slideText(0) == "Eins Zwei")
    }
}

@Suite struct OLEObjectTests {
    static let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

    private func deck(_ content: String, rels: String, media: [String: Data] = ["ppt/media/image1.png": pngData(255, 0, 0)],
                      hidden: Bool = false) throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.frame(4, Self.frame, uri: X.oleURI, content, hidden: hidden),
                          rels: X.rel("rId6", "oleObject", "../embeddings/oleObject1.bin") + rels)]
        f.media = media
        f.media["ppt/embeddings/oleObject1.bin"] = Data([0, 1, 2, 3])
        return try f.open()
    }

    private func expectImageAtFrame(_ d: SlideDeck) {
        let px = d.pixels(0)
        #expect(px.hex(200, 150) == "FF0000")
        #expect(px.hex(105, 105) == "FF0000")
        #expect(px.hex(295, 195) == "FF0000")
        #expect(px.hex(305, 150) == "FFFFFF")
        #expect(px.hex(200, 205) == "FFFFFF")
    }

    @Test func imageFromOleObjPic() throws {
        let o = try deck("<p:oleObj name=\"x\" r:id=\"rId6\" progId=\"Excel.Sheet.12\"><p:embed/>\(X.olePic(rId: "rId7"))</p:oleObj>",
                         rels: X.rel("rId7", "image", "../media/image1.png"))
        expectImageAtFrame(o.deck)
        #expect(o.deck.slideText(0) == "")
    }

    @Test func imageFromFallbackWhenTheChoiceIsVML() throws {
        let ac = "<mc:AlternateContent xmlns:mc=\"\(NS.mc)\"><mc:Choice xmlns:v=\"\(NS.v)\" Requires=\"v\">"
            + "<p:oleObj spid=\"_x0000_s1029\" name=\"x\" r:id=\"rId6\"><p:embed/></p:oleObj></mc:Choice>"
            + "<mc:Fallback><p:oleObj name=\"x\" r:id=\"rId6\"><p:embed/>\(X.olePic(rId: "rId7"))</p:oleObj></mc:Fallback></mc:AlternateContent>"
        let o = try deck(ac, rels: X.rel("rId7", "image", "../media/image1.png"))
        expectImageAtFrame(o.deck)
    }

    @Test func imageFromLegacyVML() throws {
        // Old files: the Choice (or a bare oleObj) names a VML shape whose v:imagedata holds the image.
        let vml = "<xml xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\">"
            + "<v:shape id=\"_x0000_s1028\" type=\"#_x0000_t75\"><v:imagedata o:relid=\"rId2\"/></v:shape>"
            + "<v:shape id=\"_x0000_s1029\" type=\"#_x0000_t75\"><v:imagedata o:relid=\"rId1\" o:title=\"\"/></v:shape></xml>"
        let vmlRels = "<Relationships xmlns=\"\(NS.relPkg)\">" + X.rel("rId1", "image", "../media/image1.png")
            + X.rel("rId2", "image", "../media/image2.png") + "</Relationships>"
        let media = ["ppt/media/image1.png": pngData(255, 0, 0), "ppt/media/image2.png": pngData(0, 0, 255),
                     "ppt/drawings/vmlDrawing1.vml": Data(vml.utf8), "ppt/drawings/_rels/vmlDrawing1.vml.rels": Data(vmlRels.utf8)]
        let rels = X.rel("rId3", "vmlDrawing", "../drawings/vmlDrawing1.vml")
        let bare = try deck("<p:oleObj spid=\"_x0000_s1029\" name=\"x\" r:id=\"rId6\"><p:embed/></p:oleObj>", rels: rels, media: media)
        expectImageAtFrame(bare.deck)
        let choiceOnly = "<mc:AlternateContent xmlns:mc=\"\(NS.mc)\"><mc:Choice xmlns:v=\"\(NS.v)\" Requires=\"v\">"
            + "<p:oleObj spid=\"_x0000_s1029\" name=\"x\" r:id=\"rId6\"><p:embed/></p:oleObj></mc:Choice></mc:AlternateContent>"
        let o = try deck(choiceOnly, rels: rels, media: media)
        expectImageAtFrame(o.deck)
    }

    @Test func noImageLeavesTheFrameEmpty() throws {
        let cases = [
            "<p:oleObj name=\"x\" r:id=\"rId6\"><p:embed/></p:oleObj>",
            "<p:oleObj spid=\"_x0000_s1\" r:id=\"rId6\"><p:embed/></p:oleObj>", // no VML part
            "<p:oleObj r:id=\"rId6\"><p:embed/>\(X.olePic(rId: "rId99"))</p:oleObj>", // unknown rId
            "<p:oleObj r:id=\"rId6\"><p:embed/>\(X.olePic(rId: "rId8"))</p:oleObj>", // missing image part
            "",
        ]
        for c in cases {
            let o = try deck(c, rels: X.rel("rId8", "image", "../media/missing.png"))
            let px = o.deck.pixels(0)
            #expect(px.hex(200, 150) == "FFFFFF")
        }
        // A hidden frame draws nothing either (all think-cell objects in the corpus are hidden).
        let hidden = try deck("<p:oleObj r:id=\"rId6\"><p:embed/>\(X.olePic(rId: "rId7"))</p:oleObj>",
                              rels: X.rel("rId7", "image", "../media/image1.png"), hidden: true)
        #expect(hidden.deck.pixels(0).hex(200, 150) == "FFFFFF")
    }

    @Test func unknownGraphicDataIsEmpty() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.frame(4, Self.frame, uri: "urn:unknown", "<x:y xmlns:x=\"urn:x\"/>")
                          + X.frame(5, Self.frame, uri: "", ""))]
        let o = try f.open()
        #expect(o.deck.pixels(0).hex(200, 150) == "FFFFFF")
        #expect(o.deck.slideText(0) == "")
    }
}

@Suite struct MediaTests {
    static func video(_ blip: Bool) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"8\" name=\"clip.mp4\"><a:hlinkClick r:id=\"\" action=\"ppaction://media\"/></p:cNvPr>"
            + "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr><a:videoFile r:link=\"rId4\"/><p:extLst>"
            + "<p:ext uri=\"{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}\"><p14:media xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\" r:embed=\"rId5\"/></p:ext>"
            + "</p:extLst></p:nvPr></p:nvPicPr><p:blipFill>" + (blip ? "<a:blip r:embed=\"rId7\"/>" : "")
            + "<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(X.xfrm(CGRect(x: 100, y: 100, width: 200, height: 100)))"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    private func deck(_ shapes: String) throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: shapes, rels: X.rel("rId4", "video", "../media/media1.mp4")
                          + X.rel("rId5", "http://schemas.microsoft.com/office/2007/relationships/media", "../media/media1.mp4")
                          + X.rel("rId7", "image", "../media/image1.png"))]
        f.media = ["ppt/media/image1.png": pngData(0, 255, 0), "ppt/media/media1.mp4": Data([0, 0, 0, 24])]
        return try f.open()
    }

    @Test func videoPosterFrameIsDrawn() throws {
        let o = try deck(Self.video(true))
        let px = o.deck.pixels(0)
        #expect(px.hex(200, 150) == "00FF00")
        #expect(px.hex(305, 150) == "FFFFFF")
    }

    @Test func mediaWithoutBlipDrawsNothing() throws {
        let o = try deck(Self.video(false))
        #expect(o.deck.pixels(0).hex(200, 150) == "FFFFFF")
    }
}

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>: renders every visible slide with SmartArt, a chart, an
/// OLE object or a video at 1600 px to /tmp/slidekit-t12b/ (local comparison output only) and prints its text.
@Suite struct GraphicFrameCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]
    static let markers = ["drawingml/2006/diagram": "smartart", "drawingml/2006/chart": "chart",
                          "presentationml/2006/ole": "ole", "videoFile": "video"]

    @Test(.enabled(if: corpus != nil)) func renderGraphicFrameSlides() throws {
        let dir = URL(fileURLWithPath: try #require(Self.corpus))
        let out = URL(fileURLWithPath: "/tmp/slidekit-t12b", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let deck = try SlideDeck(url: url)
            let name = url.deletingPathExtension().lastPathComponent.prefix(12)
            for i in 0..<deck.slideCount {
                let ref = try #require(deck.slide(i))
                let xml = String(decoding: try deck.package.data(ref.partPath), as: UTF8.self)
                let kinds = Self.markers.filter { xml.contains($0.key) }.map(\.value).sorted()
                guard !kinds.isEmpty else { continue }
                print("[corpus-12b] \(name) #\(i + 1) (\(ref.partPath)) \(kinds): \(deck.slideText(i).prefix(300))")
                let image = try #require(deck.thumbnail(i, maxPixel: 1600))
                let dest = try #require(CGImageDestinationCreateWithURL(
                    out.appendingPathComponent("\(name)-\(i + 1)-\(kinds.joined(separator: "+")).png") as CFURL,
                    "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }
}
