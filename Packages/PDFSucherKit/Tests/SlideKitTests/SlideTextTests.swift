// SlideTextTests.swift — Task 11 (SlideKit tests)
// slideText (normalized, z-order, tables, fields) and wordBoxes (ranges in the normalized text, boxes 0…1).
import CoreGraphics
import Foundation
import IndexKit
import ImageIO
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

extension X {
    /// A text box without insets at `frame`, one paragraph per entry of `paras`, optional rotation in degrees.
    static func words(_ id: Int, _ frame: CGRect, _ paras: [String], rot: Double = 0) -> String {
        let r = rot == 0 ? "" : " rot=\"\(Int(rot * 60000))\""
        let xf = "<a:xfrm\(r)><a:off x=\"\(emu(frame.minX))\" y=\"\(emu(frame.minY))\"/><a:ext cx=\"\(emu(frame.width))\" cy=\"\(emu(frame.height))\"/></a:xfrm>"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"t\(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr>\(xf)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
            + body(paras.map { para($0) }.joined(), bodyPr: "<a:bodyPr \(noInsets)/>") + "</p:sp>"
    }

    /// A table graphic frame; `rows` of cell texts ("" = empty cell).
    static func table(_ id: Int, _ frame: CGRect, _ rows: [[String]]) -> String {
        let cols = rows.first?.count ?? 0
        let grid = (0..<cols).map { _ in "<a:gridCol w=\"\(emu(frame.width / Double(max(cols, 1))))\"/>" }.joined()
        let trs = rows.map { row in
            "<a:tr h=\"\(emu(30))\">" + row.map { t in
                "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>" + (t.isEmpty ? "<a:p/>" : para(t)) + "</a:txBody><a:tcPr/></a:tc>"
            }.joined() + "</a:tr>"
        }.joined()
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"tbl\(id)\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"\(emu(frame.minX))\" y=\"\(emu(frame.minY))\"/><a:ext cx=\"\(emu(frame.width))\" cy=\"\(emu(frame.height))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblGrid>\(grid)</a:tblGrid>"
            + trs + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    static func group(_ id: Int, _ children: String) -> String {
        "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"g\(id)\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>"
            + "<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(emu(960))\" cy=\"\(emu(540))\"/>"
            + "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(emu(960))\" cy=\"\(emu(540))\"/></a:xfrm></p:grpSpPr>\(children)</p:grpSp>"
    }
}

@Suite struct SlideTextTests {
    private func deck(_ shapes: String) throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: shapes)]
        return try f.open()
    }

    /// The normalized-text substring of every box, in order.
    private func boxed(_ d: SlideDeck, _ i: Int = 0) -> [String] {
        let t = d.slideText(i) as NSString
        return d.wordBoxes(i).map { t.substring(with: $0.range) }
    }

    private func inUnitSquare(_ b: CGRect) -> Bool {
        b.minX >= 0 && b.minY >= 0 && b.maxX <= 1 && b.maxY <= 1 && b.width > 0 && b.height > 0
    }

    @Test func umlautsMapToTheirWords() throws {
        // The second word is decomposed (u + U+0308): the normalized text is NFC and one unit shorter.
        let o = try deck(X.words(2, CGRect(x: 100, y: 100, width: 600, height: 60), ["Kündigungsfrist Mu\u{0308}ller"]))
        let text = o.deck.slideText(0)
        #expect(text == "Kündigungsfrist Müller")
        let boxes = o.deck.wordBoxes(0)
        try #require(boxes.count == 2)
        #expect(boxed(o.deck) == ["Kündigungsfrist", "Müller"])
        #expect(boxes.map(\.range) == [NSRange(location: 0, length: 15), NSRange(location: 16, length: 6)])
        #expect(boxes.allSatisfy { inUnitSquare($0.box) })
        // 960×540 slide: the first word starts at x = 100 pt, y ≈ 100 pt.
        #expect(abs(boxes[0].box.minX - 100.0 / 960) < 0.005)
        #expect(boxes[0].box.minY >= 100.0 / 540 - 0.001 && boxes[0].box.maxY < 130.0 / 540)
        #expect(boxes[1].box.minX > boxes[0].box.maxX)
    }

    @Test func shapesInZOrderGroupsRecursiveMasterAndLayoutExcluded() throws {
        var f = PptxFixture()
        f.masterShapes = X.words(9, CGRect(x: 0, y: 500, width: 300, height: 30), ["Masterfuß"])
        f.layoutShapes = X.words(9, CGRect(x: 600, y: 500, width: 300, height: 30), ["Layoutfuß"])
        let empty = X.sp(7, CGRect(x: 0, y: 0, width: 100, height: 40), ph: "idx=\"1\"", txBody: X.body("<a:p/>"))
        f.slides = [.init(shapes: X.words(2, CGRect(x: 50, y: 50, width: 300, height: 40), ["Eins"])
            + empty
            + X.group(3, X.words(4, CGRect(x: 50, y: 150, width: 300, height: 40), ["Zwei"])
                + X.group(5, X.words(6, CGRect(x: 50, y: 250, width: 300, height: 40), ["Drei", "Dreieinhalb"])))
            + X.words(8, CGRect(x: 500, y: 50, width: 300, height: 40), ["Vier"])
            + X.words(10, CGRect(x: 500, y: 150, width: 300, height: 40), ["Fünf"]).replacingOccurrences(
                of: "name=\"t10\"", with: "name=\"t10\" hidden=\"1\""))]
        let o = try f.open()
        #expect(o.deck.slideText(0) == "Eins Zwei Drei Dreieinhalb Vier")
        #expect(boxed(o.deck) == ["Eins", "Zwei", "Drei", "Dreieinhalb", "Vier"])
    }

    @Test func tableTextIsIncludedRowByRow() throws {
        let o = try deck(X.words(2, CGRect(x: 50, y: 20, width: 300, height: 40), ["Vor"])
            + X.table(3, CGRect(x: 50, y: 100, width: 400, height: 60), [["A1", "B1"], ["", "B2"]])
            + X.words(4, CGRect(x: 50, y: 300, width: 300, height: 40), ["Nach"]))
        #expect(o.deck.slideText(0) == "Vor A1 B1 B2 Nach")
        // Table cells are laid out (Task 12a), so their words have boxes too.
        #expect(boxed(o.deck) == ["Vor", "A1", "B1", "B2", "Nach"])
        let boxes = o.deck.wordBoxes(0)
        try #require(boxes.count == 5)
        #expect(boxes[4].range == NSRange(location: 13, length: 4))
    }

    @Test func hiddenSlidesAreSkipped() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.words(2, CGRect(x: 50, y: 50, width: 300, height: 40), ["Erste"])),
                    .init(shapes: X.words(2, CGRect(x: 50, y: 50, width: 300, height: 40), ["Versteckt"]), rootAttrs: "show=\"0\""),
                    .init(shapes: X.words(2, CGRect(x: 50, y: 50, width: 300, height: 40), ["Dritte"]))]
        let o = try f.open()
        #expect(o.deck.slideCount == 2)
        #expect(o.deck.slideText(0) == "Erste")
        #expect(o.deck.slideText(1) == "Dritte")
        #expect(boxed(o.deck, 1) == ["Dritte"])
    }

    @Test func hyphenationAcrossParagraphsStaysConsistent() throws {
        let o = try deck(X.words(2, CGRect(x: 50, y: 50, width: 600, height: 200), ["Der Ver-", "trag gilt", "Nord-", "Süd"]))
        let text = o.deck.slideText(0)
        #expect(text == "Der Vertrag gilt Nord-Süd")
        #expect(boxed(o.deck) == ["Der", "Ver", "trag", "gilt", "Nord", "Süd"])
        // Both parts of the joined word lie inside "Vertrag".
        let vertrag = (text as NSString).range(of: "Vertrag")
        let boxes = o.deck.wordBoxes(0)
        try #require(boxes.count == 6)
        let parts = boxes[1...2].map(\.range)
        #expect(parts.allSatisfy { NSIntersectionRange($0, vertrag).length == $0.length })
        #expect(parts[0].location == vertrag.location && NSMaxRange(parts[1]) == NSMaxRange(vertrag))
    }

    @Test func boxesAreClampedToTheSlide() throws {
        let o = try deck(X.words(2, CGRect(x: -40, y: 100, width: 600, height: 40), ["Abgeschnitten hier"])
            + X.words(3, CGRect(x: 2000, y: 100, width: 300, height: 40), ["Fern"])
            + X.words(4, CGRect(x: 100, y: 525, width: 300, height: 40), ["Unten"]))
        #expect(o.deck.slideText(0) == "Abgeschnitten hier Fern Unten")
        let boxes = o.deck.wordBoxes(0)
        #expect(boxed(o.deck) == ["Abgeschnitten", "hier", "Unten"])
        try #require(boxes.count == 3)
        #expect(boxes.allSatisfy { inUnitSquare($0.box) })
        #expect(boxes[0].box.minX == 0)
        #expect(boxes[2].box.maxY == 1)
    }

    @Test func rotatedShapeGivesAxisAlignedBox() throws {
        let o = try deck(X.words(2, CGRect(x: 300, y: 200, width: 300, height: 40), ["Senkrecht"], rot: 90))
        let b = try #require(o.deck.wordBoxes(0).first)
        let pt = CGRect(x: b.box.minX * 960, y: b.box.minY * 540, width: b.box.width * 960, height: b.box.height * 540)
        #expect(pt.height > 2 * pt.width)
        // Turned about the centre (450, 220): the text runs down along x ≈ 450 + 20 − line height … 470.
        #expect(pt.minX > 420 && pt.maxX <= 471)
        #expect(pt.minY >= 69 && pt.maxY < 371)
    }

    @Test func slideNumberFieldAppears() throws {
        var f = PptxFixture()
        let fld = "<a:p><a:r><a:t>Folie </a:t></a:r><a:fld id=\"{1}\" type=\"slidenum\"><a:t>&lt;#&gt;</a:t></a:fld></a:p>"
        f.slides = [.init(), .init(rootAttrs: "show=\"0\""),
                    .init(shapes: X.textBox(2, CGRect(x: 50, y: 50, width: 300, height: 40), body: X.body(fld)))]
        let o = try f.open()
        #expect(o.deck.slideText(1) == "Folie 3")
        #expect(boxed(o.deck, 1) == ["Folie", "3"])
    }

    @Test func outOfRangeIsEmpty() throws {
        let o = try deck(X.words(2, CGRect(x: 50, y: 50, width: 300, height: 40), ["Hallo"]))
        for i in [-1, 1, Int.max, Int.min] {
            #expect(o.deck.slideText(i) == "")
            #expect(o.deck.wordBoxes(i).isEmpty)
        }
    }

    @Test func concurrentCallsAgree() async throws {
        var f = PptxFixture()
        f.slides = (0..<5).map { i in
            .init(shapes: X.words(2, CGRect(x: 50, y: 50, width: 500, height: 80), ["Folie \(i) Kündigungsfrist", "Ver-", "trag"])
                + X.table(3, CGRect(x: 50, y: 300, width: 400, height: 60), [["Zelle \(i)"]]))
        }
        let o = try f.open()
        let d = o.deck
        let results = await withTaskGroup(of: [String: [OCRWord]].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var r: [String: [OCRWord]] = [:]
                    for i in 0..<d.slideCount { r[d.slideText(i)] = d.wordBoxes(i) }
                    return r
                }
            }
            var all: [[String: [OCRWord]]] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == results[0] })
        #expect(results[0].count == 5)
        // Folie, 2, Kündigungsfrist, Ver, trag + the table cell's Zelle, 2 (Task 12a).
        #expect(results[0]["Folie 2 Kündigungsfrist Vertrag Zelle 2"]?.count == 7)
    }
}

/// Boundary cases of the original → normalized mapping and of the raw-text offsets.
@Suite struct SlideTextMappingTests {
    private func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

    @Test func inverseMapBoundaries() {
        // Original UTF-16: 0-1 "  ", 2 a, 3-4 "  ", 5 b, 6 SHY, 7 c, 8 " ", 9 ﬁ, 10 " ", 11-12 😀, 13 " ", 14 x, 15 tab.
        let raw = "  a  b\u{00AD}c \u{FB01} 😀 x\t"
        #expect((raw as NSString).length == 16)
        let (text, map) = SlideTextBuilder.normalize(raw)
        #expect(text == "a bc fi 😀 x")
        let t = text as NSString
        func word(_ loc: Int, _ len: Int) -> String? { map.normalizedRange(for: r(loc, len)).map { t.substring(with: $0) } }
        #expect(map.normalizedRange(for: r(2, 1)) == r(0, 1))   // a after leading spaces
        #expect(map.normalizedRange(for: r(5, 3)) == r(2, 2))   // b SHY c → "bc"
        #expect(map.normalizedRange(for: r(5, 1)) == r(2, 1))
        #expect(map.normalizedRange(for: r(7, 1)) == r(3, 1))
        #expect(map.normalizedRange(for: r(9, 1)) == r(5, 2))   // ligature → "fi"
        #expect(map.normalizedRange(for: r(11, 2)) == r(8, 2))  // surrogate pair
        #expect(map.normalizedRange(for: r(14, 1)) == r(11, 1)) // x before trailing tab
        #expect(word(5, 3) == "bc" && word(9, 1) == "fi" && word(11, 2) == "😀")
        #expect(map.normalizedRange(for: r(6, 1)) == nil)       // soft hyphen alone: dropped
        #expect(map.normalizedRange(for: r(0, 2)) == nil)       // leading spaces: dropped
        #expect(map.normalizedRange(for: r(15, 1)) == nil)      // trailing tab: dropped
        #expect(map.normalizedRange(for: r(3, 2)) == nil)       // two spaces → one collapsed space
        #expect(map.normalizedRange(for: r(2, 0)) == nil)       // empty
        #expect(map.normalizedRange(for: r(16, 3)) == nil)      // past the end
        // A word spanning a collapsed space keeps it inside its range.
        #expect(map.normalizedRange(for: r(2, 6)) == r(0, 4))
    }

    @Test func wordsOfSpaceOrFormatCharactersAreDropped() {
        // U+E000 (private use) counts as whitespace, U+200B (ZWSP) is removed.
        let (text, map) = SlideTextBuilder.normalize("a\u{E000}b \u{200B} c")
        #expect(text == "a b c")
        #expect(map.normalizedRange(for: r(1, 1)) == nil)
        #expect(map.normalizedRange(for: r(4, 1)) == nil)
        #expect(map.normalizedRange(for: r(2, 1)) == r(2, 1))
        #expect(map.normalizedRange(for: r(6, 1)) == r(4, 1))
    }

    @Test func rawTextOffsetsAndInlineObjects() {
        var raw = SlideTextBuilder.RawText()
        #expect(raw.appendShape(["", ""]) == nil)
        #expect(raw.appendShape(["Eins", "a\u{FFFC}b"]) == [0, 5])
        #expect(raw.appendShape([""]) == nil)
        #expect(raw.appendShape(["", "Zwei"]) == [10, 11])
        #expect(raw.text == "Eins\na b\n\n\nZwei")
        let (text, map) = SlideTextBuilder.normalize(raw.text)
        #expect(text == "Eins a b Zwei")
        #expect(map.normalizedRange(for: r(11, 4)) == r(9, 4))
        #expect(map.normalizedRange(for: r(5, 1)) == r(5, 1))
        #expect(map.normalizedRange(for: r(7, 1)) == r(7, 1))
    }

    @Test func longWordWrapsIntoOneBoxPerLine() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.words(2, CGRect(x: 100, y: 100, width: 80, height: 200), ["Ab Donaudampfschifffahrtsgesellschaft"]))]
        let o = try f.open()
        let text = o.deck.slideText(0) as NSString
        #expect(text as String == "Ab Donaudampfschifffahrtsgesellschaft")
        let boxes = o.deck.wordBoxes(0)
        #expect(boxes.first.map { text.substring(with: $0.range) } == "Ab")
        let parts = Array(boxes.dropFirst())
        try #require(parts.count >= 2)
        // The parts tile the word in order, each on its own, lower line.
        #expect(parts.first?.range.location == 3)
        #expect(parts.last.map { NSMaxRange($0.range) } == text.length)
        for (p, q) in zip(parts, parts.dropFirst()) {
            #expect(NSMaxRange(p.range) == q.range.location)
            #expect(q.box.minY >= p.box.maxY - 0.001)
        }
        #expect(parts.map { text.substring(with: $0.range) }.joined() == "Donaudampfschifffahrtsgesellschaft")
        #expect(parts.allSatisfy { $0.box.minX >= 100.0 / 960 - 0.001 && $0.box.maxX <= 180.0 / 960 + 0.001 })
    }
}

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>: text and boxes for every visible slide, time per
/// deck, and one highlight overlay per deck in /tmp/slidekit-t11/ (local comparison output only).
@Suite struct SlideTextCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]

    @Test(.enabled(if: corpus != nil)) func textAndBoxesForEveryVisibleSlide() throws {
        let dir = URL(fileURLWithPath: try #require(Self.corpus))
        let out = URL(fileURLWithPath: "/tmp/slidekit-t11", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let deck = try SlideDeck(url: url)
            var texts: [String] = []
            var boxes: [[OCRWord]] = []
            let elapsed = ContinuousClock().measure {
                for i in 0..<deck.slideCount {
                    texts.append(deck.slideText(i))
                    boxes.append(deck.wordBoxes(i))
                }
            }
            let name = url.lastPathComponent
            let nonEmpty = texts.filter { !$0.isEmpty }.count
            #expect(nonEmpty * 10 >= deck.slideCount * 7, "\(name): \(nonEmpty)/\(deck.slideCount) slides with text")
            for (i, words) in boxes.enumerated() {
                let len = (texts[i] as NSString).length
                for w in words {
                    #expect(w.range.location >= 0 && NSMaxRange(w.range) <= len && w.range.length > 0, "\(name) #\(i)")
                    #expect(w.box.minX >= 0 && w.box.minY >= 0 && w.box.maxX <= 1 && w.box.maxY <= 1, "\(name) #\(i)")
                }
            }
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print(String(format: "[corpus-text] %@: %d slides, %d with text, %d words, %d chars in %.0f ms (%.1f ms/slide)",
                         name, deck.slideCount, nonEmpty, boxes.map(\.count).reduce(0, +),
                         texts.map(\.count).reduce(0, +), ms, ms / Double(max(deck.slideCount, 1))))
            // Overlay: the slide with the most words.
            if let best = boxes.indices.max(by: { boxes[$0].count < boxes[$1].count }) {
                let base = url.deletingPathExtension().lastPathComponent
                try writeOverlay(deck, best, to: out.appendingPathComponent("\(base)-\(best).png"))
                try texts[best].write(to: out.appendingPathComponent("\(base)-\(best).txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private func writeOverlay(_ deck: SlideDeck, _ i: Int, to url: URL) throws {
        let w = 1600, h = Int((1600 * deck.slideSize.height / deck.slideSize.width).rounded())
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        deck.draw(i, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.35))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.8))
        for word in deck.wordBoxes(i) {
            let b = word.box
            let r = CGRect(x: b.minX * Double(w), y: (1 - b.maxY) * Double(h), width: b.width * Double(w), height: b.height * Double(h))
            ctx.fill(r)
            ctx.stroke(r, width: 1)
        }
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
