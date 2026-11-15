// ReferenceFixTests.swift — slidekit-ref (SlideKit tests)
// Deviations from PowerPoint found against PowerPoint's own PDF exports of real decks (docs/slidekit-vergleich.md,
// PowerPoint section); each test pins the measured PowerPoint behaviour on a synthetic fixture.
import CoreGraphics
import Foundation
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

@Suite struct ReferenceFixTests {
    private func texts(_ o: OpenedDeck, _ i: Int = 0) throws -> SlideTextLayout {
        o.deck.store.textLayout(try #require(o.deck.slide(i)))
    }

    private func r(_ text: String, sz: Int) -> String { "<a:r><a:rPr sz=\"\(sz)\"/><a:t>\(text)</a:t></a:r>" }
    private func br(sz: Int) -> String { "<a:br><a:rPr sz=\"\(sz)\"/></a:br>" }

    /// PowerPoint: a line break's own size does not count for the line it ends (D1: a 20 pt line ended by a
    /// 36 pt break has a 20 pt pitch in the PDF). A line holding nothing but a break keeps the break's size.
    @Test func lineBreakSizeDoesNotGrowTheLineItEnds() throws {
        var f = PptxFixture()
        let p = "<a:p>" + r("A", sz: 2000) + br(sz: 3600) + br(sz: 3600) + r("B", sz: 2000) + "</a:p>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                            body: X.body(p, bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let lines = try texts(try f.open()).shapes[0].sets[0].lines
        try #require(lines.count == 3)
        #expect(abs(lines[0].height - 24) < 0.01)      // "A" + break: 20 pt × 1.2
        #expect(abs(lines[1].height - 43.2) < 0.01)    // break only: 36 pt × 1.2
        #expect(abs(lines[2].height - 24) < 0.01)      // "B"
    }

    /// PowerPoint: with lnSpc > 100 % the first line of a text body has its baseline at 0.75 × its line height
    /// below the top (0.9 × factor × size), not at height − descent; the rest of the body moves up with it and
    /// the block is that much shorter for anchoring (top-anchored boxes in D1/D2/D5/D7 at 110–150 %).
    @Test func firstLineAboveSingleSpacingSitsHigher() throws {
        var f = PptxFixture()
        let p = { (pct: Int) in
            "<a:p><a:pPr><a:lnSpc><a:spcPct val=\"\(pct)\"/></a:lnSpc></a:pPr><a:r><a:rPr sz=\"2000\"/><a:t>Hx</a:t></a:r></a:p>"
        }
        let frame = { (x: Double) in CGRect(x: x, y: 0, width: 200, height: 200) }
        f.slides = [.init(shapes: X.textBox(2, frame(0), body: X.body(p(150000) + p(150000), bodyPr: "<a:bodyPr \(X.noInsets)/>"))
            + X.textBox(3, frame(300), body: X.body(p(100000), bodyPr: "<a:bodyPr \(X.noInsets)/>"))
            + X.textBox(4, frame(600), body: X.body(p(150000), bodyPr: "<a:bodyPr anchor=\"ctr\" \(X.noInsets)/>")))]
        let t = try texts(try f.open())
        func baseline(_ s: ShapeTextLayout, _ k: Int) -> CGFloat {
            let piece = s.pieces[k], set = s.sets[piece.paragraph]
            return piece.origin.y - set.lines[0].top + set.lines[0].origin.y
        }
        #expect(abs(baseline(t.shapes[0], 0) - 27) < 0.01)            // 0.75 × 36
        #expect(abs(baseline(t.shapes[0], 1) - (27 + 36)) < 0.01)     // pitch unchanged
        let single = t.shapes[1].sets[0].lines[0]
        #expect(abs(baseline(t.shapes[1], 0) - (24 - single.descent)) < 0.01)  // 100 %: unchanged
        // Centred: the block is 27 + descent high instead of 36.
        let d = t.shapes[2].sets[0].lines[0].descent
        #expect(abs(baseline(t.shapes[2], 0) - ((200 - (27 + d)) / 2 + 27)) < 0.01)
    }

    /// PowerPoint draws superscript/subscript (`baseline` ≠ 0) at 2/3 of the run size and shifts by the
    /// percentage of the full size (D7: a 28 pt title's superscript is a 2/3-size glyph raised 8 pt ≈ 30 %).
    @Test func superscriptIsTwoThirdsSize() throws {
        var f = PptxFixture()
        let p = "<a:p>" + r("H", sz: 2800) + "<a:r><a:rPr sz=\"2800\" baseline=\"30000\"/><a:t>1</a:t></a:r>"
            + "<a:r><a:rPr sz=\"2800\" baseline=\"-25000\"/><a:t>2</a:t></a:r></a:p>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                            body: X.body(p, bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let runs = try texts(try f.open()).shapes[0].paragraphs[0].runs
        try #require(runs.count == 3)
        #expect(runs[0].style.size == 28 && runs[0].style.baselineShift == 0)
        #expect(abs(runs[1].style.size - 28 * 2 / 3) < 0.001)
        #expect(abs(runs[1].style.baselineShift - 45) < 0.001)     // 30 % of 28 pt = 45 % of 18.67 pt
        #expect(abs(runs[2].style.size - 28 * 2 / 3) < 0.001)
        #expect(abs(runs[2].style.baselineShift + 37.5) < 0.001)
    }

    /// Picture recolouring (`a:blip` children duotone, grayscl, clrChange, biLevel, lum): PowerPoint draws
    /// them (D2, D3, D6, D7 icons and photos), SlideKit ignored them.
    @Test func blipRecolorEffects() throws {
        var f = PptxFixture()
        f.slides = [.init(bg: X.bgColor("FF0000"))]
        func pic(_ id: Int, _ x: Double, _ rId: String, _ effects: String) -> String {
            "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"p\(id)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
                + "<p:blipFill><a:blip r:embed=\"\(rId)\">\(effects)</a:blip><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                + "<p:spPr>\(X.xfrm(CGRect(x: x, y: 100, width: 100, height: 100)))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        }
        f.media["ppt/media/gray.png"] = pngData(128, 128, 128)
        f.media["ppt/media/red.png"] = pngData(255, 0, 0)
        f.media["ppt/media/blue.png"] = pngData(0, 0, 255)
        f.media["ppt/media/dark.png"] = pngData(51, 51, 51)
        f.slides[0].shapes = pic(2, 0, "rId7", "<a:duotone><a:srgbClr val=\"000080\"/><a:srgbClr val=\"FFFF00\"/></a:duotone>")
            + pic(3, 150, "rId8", "<a:grayscl/>")
            + pic(4, 300, "rId9", "<a:clrChange><a:clrFrom><a:srgbClr val=\"0000FF\"/></a:clrFrom>"
                    + "<a:clrTo><a:srgbClr val=\"0000FF\"><a:alpha val=\"0\"/></a:srgbClr></a:clrTo></a:clrChange>")
            + pic(5, 450, "rId10", "<a:biLevel thresh=\"10000\"/>")
            + pic(6, 600, "rId7", "")
        f.slides[0].rels = PptxFixture.imageRel("rId7", "../media/gray.png") + PptxFixture.imageRel("rId8", "../media/red.png")
            + PptxFixture.imageRel("rId9", "../media/blue.png") + PptxFixture.imageRel("rId10", "../media/dark.png")
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(50, 150) == "808040")     // luminance 0.5: halfway from 000080 to FFFF00
        #expect(px.hex(200, 150) == "4C4C4C")    // BT.601 luma of red
        #expect(px.hex(350, 150) == "FF0000")    // blue made transparent: the slide background shows
        #expect(px.hex(500, 150) == "FFFFFF")    // luma 0.2 ≥ 10 % threshold → white
        #expect(px.hex(650, 150) == "808080")    // same image without effects is untouched
    }

    /// PowerPoint's line pitch is 1.2 × size × factor even for fonts whose ascent + descent is larger (D1: Avenir
    /// 16 pt at 100 % has a 19.9 pt pitch in the PDF, not ascent + descent = 21.9 pt).
    @Test func fontMetricsDoNotGrowTheLine() throws {
        var f = PptxFixture()
        let p = "<a:p><a:r><a:rPr sz=\"1600\"><a:latin typeface=\"Avenir\"/></a:rPr><a:t>A</a:t></a:r>"
            + "<a:br><a:rPr sz=\"1600\"><a:latin typeface=\"Avenir\"/></a:rPr></a:br>"
            + "<a:r><a:rPr sz=\"1600\"><a:latin typeface=\"Avenir\"/></a:rPr><a:t>B</a:t></a:r></a:p>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                            body: X.body(p, bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let lines = try texts(try f.open()).shapes[0].sets[0].lines
        try #require(lines.count == 2)
        #expect(lines[0].ascent + lines[0].descent > 19.2 + 0.5)  // the font really is taller
        #expect(abs(lines[0].height - 19.2) < 0.01)
        #expect(abs(lines[1].height - 19.2) < 0.01)
    }

    /// Exact line spacing above the single height: the body's first baseline also sits at 0.75 × the line height
    /// (D1: 36 pt spacing with 20 pt text, baseline 26.9 pt below the top).
    @Test func firstLineWithExactSpacingSitsHigher() throws {
        var f = PptxFixture()
        let p = "<a:p><a:pPr><a:lnSpc><a:spcPts val=\"3600\"/></a:lnSpc></a:pPr>" + r("Hx", sz: 2000) + "</a:p>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                            body: X.body(p + p, bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let s = try texts(try f.open()).shapes[0]
        let base = { (k: Int) in s.pieces[k].origin.y - s.sets[s.pieces[k].paragraph].lines[0].top
            + s.sets[s.pieces[k].paragraph].lines[0].origin.y }
        #expect(abs(base(0) - 27) < 0.01)
        #expect(abs(base(1) - 63) < 0.01)
    }

    /// PowerPoint draws a picture's outline outside the picture (D1, D2: a 6 pt frame spans the 6 pt outside the
    /// picture's edge in the PDF, the image is not covered); shapes keep centred lines.
    @Test func pictureOutlineIsDrawnOutside() throws {
        var f = PptxFixture()
        f.media["ppt/media/blue.png"] = pngData(0, 0, 255)
        let ln = "<a:ln w=\"127000\"><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:ln>"
        f.slides = [.init(shapes: "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"p\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"
            + "<p:blipFill><a:blip r:embed=\"rId7\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
            + "<p:spPr>\(X.xfrm(CGRect(x: 100, y: 100, width: 100, height: 100)))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(ln)</p:spPr></p:pic>"
            + X.sp(3, CGRect(x: 400, y: 100, width: 100, height: 100), fill: "0000FF", extra: ln),
            rels: PptxFixture.imageRel("rId7", "../media/blue.png"))]
        let px = try f.open().deck.pixels(0)
        #expect(px.hex(93, 150) == "FF0000")    // outside the picture: the whole 10 pt line
        #expect(px.hex(103, 150) == "0000FF")   // the picture itself is not covered
        #expect(px.hex(150, 150) == "0000FF")
        #expect(px.hex(403, 150) == "FF0000")   // a shape's line stays centred on its edge
        #expect(px.hex(393, 150) != "FF0000")
    }

    /// The first-line rule is monotonic: baseline = max(0.75 × height, single − descent). Between 100 % and 110 %
    /// the first line never sits higher than at 100 %, and exact spacing has no jump at the single height.
    @Test func firstLineRuleIsMonotonic() throws {
        func firstBaseline(_ pPr: String) throws -> (CGFloat, CGFloat) {
            var f = PptxFixture()
            let p = "<a:p><a:pPr>\(pPr)</a:pPr>" + r("Hx", sz: 2000) + "</a:p>"
            f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                                body: X.body(p, bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
            let s = try texts(try f.open()).shapes[0]
            let l = s.sets[0].lines[0]
            return (s.pieces[0].origin.y - l.top + l.origin.y, l.descent)
        }
        let pct = { (v: Int) in "<a:lnSpc><a:spcPct val=\"\(v)\"/></a:lnSpc>" }
        let pts = { (v: Int) in "<a:lnSpc><a:spcPts val=\"\(v)\"/></a:lnSpc>" }
        let (at100, d) = try firstBaseline(pct(100000))
        #expect(abs(at100 - (24 - d)) < 0.01)
        var last = at100
        for v in [101000, 103000, 105000, 108000, 110000, 120000, 150000] {
            let (b, _) = try firstBaseline(pct(v))
            #expect(b >= last - 0.001, "\(v): \(b) < \(last)")
            last = b
        }
        #expect(abs(try firstBaseline(pct(105000)).0 - (24 - d)) < 0.01)    // 0.75 × 25.2 < 24 − d
        #expect(abs(try firstBaseline(pct(150000)).0 - 27) < 0.01)          // 0.75 × 36
        // Exact spacing around the single height (24 pt for 20 pt text): no jump.
        let e24 = try firstBaseline(pts(2400)).0, e25 = try firstBaseline(pts(2500)).0
        #expect(abs(e24 - (24 - d)) < 0.01)
        #expect(e25 >= e24 - 0.001)
        #expect(abs(try firstBaseline(pts(3600)).0 - 27) < 0.01)
    }
}
