import CoreGraphics
import Foundation
import ImageIO
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

/// Slides are 960×540 pt (16:9) unless stated; `pixels(i)` renders 1 px per point.
@Suite struct SlideRenderingTests {
    // MARK: backgrounds

    @Test func masterBackgroundColorAppears() throws {
        var f = PptxFixture()
        f.masterBg = X.bgColor("FF0000")
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(5, 5) == "FF0000")
        #expect(px.hex(955, 535) == "FF0000")
    }

    @Test func layoutBackgroundOverridesMaster() throws {
        var f = PptxFixture()
        f.masterBg = X.bgColor("FF0000")
        f.layoutBg = X.bgColor("0000FF")
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "0000FF")
    }

    @Test func slideBackgroundOverridesLayout() throws {
        var f = PptxFixture()
        f.layoutBg = X.bgColor("0000FF")
        f.slides = [.init(bg: X.bgColor("00FF00"))]
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "00FF00")
    }

    @Test func slidePictureBackgroundStretches() throws {
        var f = PptxFixture()
        f.masterBg = X.bgColor("FF0000")
        f.media["ppt/media/image1.png"] = pngData(0, 255, 0)
        f.slides = [.init(bg: "<p:bg><p:bgPr><a:blipFill><a:blip r:embed=\"rId7\"/><a:stretch><a:fillRect/></a:stretch></a:blipFill><a:effectLst/></p:bgPr></p:bg>",
                          rels: PptxFixture.imageRel("rId7", "../media/image1.png"))]
        let px = try f.open().deck.pixels(0)
        for (x, y) in [(2, 2), (480, 270), (957, 537)] { #expect(px.hex(x, y) == "00FF00") }
    }

    @Test func bgRefUsesThemeBackgroundStyleWithItsColor() throws {
        var f = PptxFixture()
        f.masterBg = "<p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"accent4\"/></p:bgRef></p:bg>"
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "FFFF00")
        f.masterBg = "<p:bg><p:bgRef idx=\"1002\"><a:schemeClr val=\"accent4\"/></p:bgRef></p:bg>"
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "808080")
        f.masterBg = "<p:bg><p:bgRef idx=\"1\"><a:schemeClr val=\"accent1\"/></p:bgRef></p:bg>"
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "0000FF")
    }

    @Test func noBackgroundAnywhereIsWhite() throws {
        var f = PptxFixture()
        f.masterBg = nil
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "FFFFFF")
    }

    @Test func colorMapChain() throws {
        var f = PptxFixture()
        f.masterBg = "<p:bg><p:bgPr><a:solidFill><a:schemeClr val=\"bg1\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "EEEEEE")
        // Layout override applies when the slide inherits.
        f.layoutClrMapOvr = "<p:clrMapOvr><a:overrideClrMapping bg1=\"dk2\" tx1=\"lt1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/></p:clrMapOvr>"
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "222222")
        // The slide's own override wins.
        f.slides = [.init(clrMapOvr: "<p:clrMapOvr><a:overrideClrMapping bg1=\"dk1\" tx1=\"lt1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/></p:clrMapOvr>")]
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "111111")
    }

    // MARK: placeholders

    @Test func placeholderTakesPositionFromLayout() throws {
        var f = PptxFixture()
        f.layoutShapes = X.sp(2, CGRect(x: 100, y: 100, width: 200, height: 50), ph: "type=\"title\"")
        f.slides = [.init(shapes: X.sp(2, nil, fill: "00FF00", ph: "type=\"title\""))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(200, 125) == "00FF00")
        #expect(px.hex(90, 125) == "FFFFFF")
        #expect(px.hex(310, 125) == "FFFFFF")
    }

    @Test func placeholderInheritsThroughLayoutFromMaster() throws {
        var f = PptxFixture()
        // Master body has the frame, layout body (type omitted = obj) the fill, slide neither.
        f.masterShapes = X.sp(2, CGRect(x: 400, y: 300, width: 100, height: 100), ph: "type=\"body\" idx=\"1\"")
        f.layoutShapes = X.sp(2, nil, fill: "0000FF", ph: "idx=\"1\"")
        // Text: an empty placeholder would draw nothing (Task 10).
        f.slides = [.init(shapes: X.sp(2, nil, ph: "idx=\"1\"", txBody: X.body(X.para(" "))))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(450, 350) == "0000FF")
        #expect(px.hex(390, 350) == "FFFFFF")
    }

    @Test func masterAndLayoutPlaceholdersAreNotDrawn() throws {
        var f = PptxFixture()
        f.masterShapes = X.sp(2, CGRect(x: 0, y: 0, width: 100, height: 100), fill: "FF0000", ph: "type=\"title\"")
            + X.sp(3, CGRect(x: 0, y: 400, width: 100, height: 100), fill: "FF0000", ph: "type=\"dt\" idx=\"10\"")
        f.layoutShapes = X.sp(2, CGRect(x: 500, y: 0, width: 100, height: 100), fill: "0000FF", ph: "idx=\"1\"")
            + X.sp(3, CGRect(x: 500, y: 400, width: 100, height: 100), fill: "0000FF", ph: "type=\"sldNum\" idx=\"12\"")
        let px = try f.open().deck.pixels(0)
        for (x, y) in [(50, 50), (50, 450), (550, 50), (550, 450)] { #expect(px.hex(x, y) == "FFFFFF") }
    }

    @Test func footerPlaceholderIsDrawnWhenTheSlideHasIt() throws {
        var f = PptxFixture()
        f.layoutShapes = X.sp(3, CGRect(x: 500, y: 400, width: 100, height: 100), fill: "0000FF", ph: "type=\"sldNum\" idx=\"12\"")
        f.slides = [.init(shapes: X.sp(3, nil, ph: "type=\"sldNum\" idx=\"12\"",
                                       txBody: X.body("<a:p><a:fld id=\"{1}\" type=\"slidenum\"><a:t>1</a:t></a:fld></a:p>")))]
        #expect(try f.open().deck.pixels(0).hex(550, 450) == "0000FF")
    }

    // MARK: master / layout shapes

    @Test func masterAndLayoutShapesAreDrawnBeneathSlideShapes() throws {
        var f = PptxFixture()
        f.masterShapes = X.sp(5, CGRect(x: 0, y: 0, width: 100, height: 100), fill: "FF0000")
        f.layoutShapes = X.sp(5, CGRect(x: 50, y: 0, width: 100, height: 100), fill: "0000FF")
        f.slides = [.init(shapes: X.sp(5, CGRect(x: 100, y: 0, width: 100, height: 100), fill: "00FF00"))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(25, 50) == "FF0000")
        #expect(px.hex(75, 50) == "0000FF")
        #expect(px.hex(125, 50) == "00FF00")
    }

    @Test func layoutShowMasterSpZeroHidesMasterLogo() throws {
        var f = PptxFixture()
        f.masterShapes = X.sp(5, CGRect(x: 860, y: 440, width: 80, height: 80), fill: "FF0000")
        #expect(try f.open().deck.pixels(0).hex(900, 480) == "FF0000")
        f.layoutAttrs = "showMasterSp=\"0\""
        #expect(try f.open().deck.pixels(0).hex(900, 480) == "FFFFFF")
    }

    @Test func slideShowMasterSpZeroHidesLayoutAndMasterShapes() throws {
        var f = PptxFixture()
        f.masterShapes = X.sp(5, CGRect(x: 860, y: 440, width: 80, height: 80), fill: "FF0000")
        f.layoutShapes = X.sp(5, CGRect(x: 0, y: 0, width: 80, height: 80), fill: "0000FF")
        f.slides = [.init(rootAttrs: "showMasterSp=\"0\"")]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(900, 480) == "FFFFFF")
        #expect(px.hex(40, 40) == "FFFFFF")
    }

    // MARK: missing parts (Review Focus 2)

    @Test func missingLayoutUsesMasterDirectly() throws {
        var f = PptxFixture()
        f.includeLayout = false
        f.masterBg = X.bgColor("FF0000")
        f.masterShapes = X.sp(5, CGRect(x: 0, y: 0, width: 80, height: 80), fill: "0000FF")
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(480, 270) == "FF0000")
        #expect(px.hex(40, 40) == "0000FF")

        f.includeLayout = true
        f.slides = [.init(hasLayoutRel: false)]
        #expect(try f.open().deck.pixels(0).hex(40, 40) == "0000FF")
    }

    @Test func missingMasterAndThemeStillDrawTheSlide() throws {
        var f = PptxFixture()
        f.includeMaster = false
        f.includeTheme = false
        f.slides = [.init(shapes: X.sp(5, CGRect(x: 0, y: 0, width: 80, height: 80), extra: "")
            .replacingOccurrences(of: "</p:spPr>", with: "<a:solidFill><a:schemeClr val=\"accent1\"/></a:solidFill></p:spPr>"))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(480, 270) == "FFFFFF")
        #expect(px.hex(40, 40) == "4472C4") // Theme.fallback accent1
    }

    @Test func missingRelationshipsAndImagesSkipOnlyTheElement() throws {
        var f = PptxFixture()
        f.slides = [.init(
            shapes: X.pic(3, CGRect(x: 0, y: 0, width: 100, height: 100), rId: "rId99")
                + X.pic(4, CGRect(x: 100, y: 0, width: 100, height: 100), rId: "rId8")
                + X.sp(5, CGRect(x: 200, y: 0, width: 100, height: 100), fill: "00FF00"),
            bg: "<p:bg><p:bgPr><a:blipFill><a:blip r:embed=\"rId98\"/></a:blipFill></p:bgPr></p:bg>",
            rels: PptxFixture.imageRel("rId8", "../media/missing.png"))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(50, 50) == "FFFFFF")
        #expect(px.hex(150, 50) == "FFFFFF")
        #expect(px.hex(250, 50) == "00FF00")
    }

    @Test func brokenSlideXMLDrawsBackgroundOnly() throws {
        var f = PptxFixture()
        f.masterBg = X.bgColor("FF0000")
        f.slides = [.init(shapes: "<p:sp><unclosed>")]
        #expect(try f.open().deck.pixels(0).hex(480, 270) == "FF0000")
    }

    // MARK: shapes, pictures, groups

    @Test func pictureIsDrawn() throws {
        var f = PptxFixture()
        f.media["ppt/media/image1.png"] = pngData(0, 0, 255)
        f.slides = [.init(shapes: X.pic(3, CGRect(x: 100, y: 100, width: 50, height: 50), rId: "rId7"),
                          rels: PptxFixture.imageRel("rId7", "../media/image1.png"))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(125, 125) == "0000FF")
        #expect(px.hex(160, 125) == "FFFFFF")
    }

    @Test func groupMapsChildSpace() throws {
        // Child space 0…100 maps onto 200…400 (scale 2).
        var f = PptxFixture()
        let grp = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"9\" name=\"g\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"\(X.emu(200))\" y=\"\(X.emu(200))\"/><a:ext cx=\"\(X.emu(200))\" cy=\"\(X.emu(200))\"/>"
            + "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(X.emu(100))\" cy=\"\(X.emu(100))\"/></a:xfrm></p:grpSpPr>"
            + X.sp(10, CGRect(x: 50, y: 50, width: 50, height: 50), fill: "FF00FF") + "</p:grpSp>"
        f.slides = [.init(shapes: grp)]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(350, 350) == "FF00FF")
        #expect(px.hex(290, 290) == "FFFFFF")
    }

    @Test func groupScalingDoesNotScaleLineWidths() throws {
        // Old decks keep group children in tiny master units: child space 8×20 maps onto 200×100 (25× by 5×).
        // A 4 pt line inside stays 4 pt wide (PowerPoint never scales line widths with a group).
        var f = PptxFixture()
        let line = "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"7\" name=\"c\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>"
            + "<p:spPr>\(X.xfrm(CGRect(x: 0, y: 10, width: 8, height: 0)))<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
            + "<a:ln w=\"\(X.emu(4))\">\(X.solid("FF0000"))</a:ln></p:spPr></p:cxnSp>"
        let grp = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"9\" name=\"g\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"\(X.emu(200))\" y=\"\(X.emu(200))\"/><a:ext cx=\"\(X.emu(200))\" cy=\"\(X.emu(100))\"/>"
            + "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(X.emu(8))\" cy=\"\(X.emu(20))\"/></a:xfrm></p:grpSpPr>"
            + line + "</p:grpSp>"
        f.slides = [.init(shapes: grp)]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(300, 250) == "FF0000")                                   // line at y = 200 + 10·5
        #expect(px.hex(300, 245) == "FFFFFF" && px.hex(300, 255) == "FFFFFF")  // 5× would be 20 pt (240…260)
    }

    @Test func connectorIsDrawnAsShape() throws {
        var f = PptxFixture()
        let cxn = "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"7\" name=\"c\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>"
            + "<p:spPr>\(X.xfrm(CGRect(x: 100, y: 100, width: 300, height: 0)))<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
            + "<a:ln w=\"\(X.emu(10))\">\(X.solid("FF0000"))</a:ln></p:spPr></p:cxnSp>"
        f.slides = [.init(shapes: cxn)]
        #expect(try f.open().deck.pixels(0).hex(250, 100) == "FF0000")
    }

    @Test func hiddenShapeIsNotDrawn() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.sp(5, CGRect(x: 0, y: 0, width: 80, height: 80), fill: "FF0000", hidden: true))]
        #expect(try f.open().deck.pixels(0).hex(40, 40) == "FFFFFF")
    }

    // MARK: draw / thumbnail contract

    @Test func drawFitsAndCentresInAYUpRect() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.sp(5, CGRect(x: 0, y: 0, width: 96, height: 54), fill: "FF0000"))]
        let opened = try f.open()
        // 200×200 context, rect is the whole context: the 16:9 slide is 200×112.5, centred vertically.
        let px = Pixels(width: 200, height: 200) { opened.deck.draw(0, in: $0, rect: CGRect(x: 0, y: 0, width: 200, height: 200)) }
        #expect(px.hex(100, 20) == "transparent")   // above the slide
        #expect(px.hex(100, 180) == "transparent")  // below
        #expect(px.hex(5, 48) == "FF0000")          // slide top-left (y-down 43.75…) is the red shape
        #expect(px.hex(150, 140) == "FFFFFF")
        // An offset rect in user space (y-up): only that area is touched.
        let px2 = Pixels(width: 200, height: 200) { opened.deck.draw(0, in: $0, rect: CGRect(x: 100, y: 0, width: 96, height: 54)) }
        #expect(px2.hex(102, 148) == "FF0000")       // top-left of the rect, y-up → row 200-54
        #expect(px2.hex(50, 190) == "transparent")
    }

    @Test func outOfRangeDrawsNothing() throws {
        let opened = try PptxFixture().open()
        for i in [-1, 1, Int.max] {
            let px = Pixels(width: 10, height: 10) { opened.deck.draw(i, in: $0, rect: CGRect(x: 0, y: 0, width: 10, height: 10)) }
            #expect(px.hex(5, 5) == "transparent")
            #expect(opened.deck.thumbnail(i, maxPixel: 64) == nil)
        }
    }

    @Test func thumbnailSize() throws {
        var f = PptxFixture()
        f.masterBg = X.bgColor("FF0000")
        let deck = try f.open().deck
        let t = try #require(deck.thumbnail(0, maxPixel: 256))
        #expect(t.width == 256 && t.height == 144)
        #expect(t.colorSpace?.name == CGColorSpace.sRGB)
        #expect([.premultipliedLast, .premultipliedFirst].contains(t.alphaInfo))
        #expect(Pixels(image: t).hex(128, 72) == "FF0000")
        #expect(Pixels(image: t).hex(0, 0) == "FF0000")
        #expect(deck.thumbnail(0, maxPixel: 0) == nil)
        #expect(deck.thumbnail(0, maxPixel: -5) == nil)

        f.cx = 6_858_000; f.cy = 9_144_000 // portrait 540×720
        let p = try #require(try f.open().deck.thumbnail(0, maxPixel: 100))
        #expect(p.width == 75 && p.height == 100)
    }

    @Test func concurrentRenderingIsDeterministic() async throws {
        var f = PptxFixture()
        f.media["ppt/media/image1.png"] = pngData(0, 0, 255)
        f.masterShapes = X.sp(5, CGRect(x: 860, y: 440, width: 80, height: 80), fill: "FF0000")
        f.slides = (0..<6).map { i in
            .init(shapes: X.sp(5, CGRect(x: Double(i) * 50, y: 0, width: 100, height: 100), fill: "00FF00")
                    + X.pic(6, CGRect(x: 300, y: 300, width: 50, height: 50), rId: "rId7"),
                  bg: i % 2 == 0 ? X.bgColor("FFFF00") : nil,
                  rels: PptxFixture.imageRel("rId7", "../media/image1.png"))
        }
        let opened = try f.open()
        let deck = opened.deck
        let results = await withTaskGroup(of: [Pixels].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<deck.slideCount).map { i in
                        Pixels(width: 240, height: 135) { deck.draw(i, in: $0, rect: CGRect(x: 0, y: 0, width: 240, height: 135)) }
                    }
                }
            }
            var all: [[Pixels]] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == results[0] })
        #expect(results[0][0].hex(5, 5) == "00FF00")
        #expect(results[0][1].hex(5, 5) == "FFFFFF")
        #expect(results[0][0].hex(100, 100) == "FFFF00")
    }
}

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>: renders every visible slide at 800 px, prints the
/// time per deck and writes a contact sheet per deck to /tmp/slidekit-t10/ (local comparison output only).
@Suite struct SlideRenderingCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]

    @Test(.enabled(if: corpus != nil)) func renderEveryVisibleSlide() throws {
        let dir = URL(fileURLWithPath: try #require(Self.corpus))
        let out = URL(fileURLWithPath: "/tmp/slidekit-t10", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let deck = try SlideDeck(url: url)
            let clock = ContinuousClock()
            var thumbs: [CGImage] = []
            let elapsed = clock.measure {
                for i in 0..<deck.slideCount {
                    if let t = deck.thumbnail(i, maxPixel: 800) { thumbs.append(t) }
                }
            }
            #expect(thumbs.count == deck.slideCount, "\(url.lastPathComponent)")
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print(String(format: "[corpus-render] %@: %d slides in %.0f ms (%.0f ms/slide)", url.lastPathComponent,
                         deck.slideCount, ms, ms / Double(max(deck.slideCount, 1))))
            try writeSheet(thumbs, to: out.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png"))
        }
    }

    private func writeSheet(_ thumbs: [CGImage], to url: URL) throws {
        guard let first = thumbs.first else { return }
        let cols = 5, cellW = 320, cellH = Int((Double(cellW) * Double(first.height) / Double(first.width)).rounded())
        let rows = (thumbs.count + cols - 1) / cols, gap = 8
        let w = cols * (cellW + gap) + gap, h = rows * (cellH + gap) + gap
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (n, t) in thumbs.enumerated() {
            let x = gap + (n % cols) * (cellW + gap), yTop = gap + (n / cols) * (cellH + gap)
            ctx.draw(t, in: CGRect(x: x, y: h - yTop - cellH, width: cellW, height: cellH))
        }
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
