// TableTests.swift — Task 12a (SlideKit tests)
// Tables (a:tbl in p:graphicFrame): grid geometry, row growth, merges, borders, fills, table styles (deck,
// built-in fallback), cell anchor, table text and word boxes, hostile values; degenerate slide sizes.
import CoreGraphics
import Foundation
import ImageIO
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

extension X {
    /// One `a:tc` with one paragraph per line of `text` (10 pt runs); "" = an empty paragraph.
    static func tc(_ text: String = "", attrs: String = "", tcPrAttrs: String = "", tcPr: String = "",
                   rPr: String = "<a:rPr lang=\"de-DE\" sz=\"1000\"/>") -> String {
        let paras = text.isEmpty
            ? "<a:p><a:endParaRPr lang=\"de-DE\" sz=\"1000\"/></a:p>"
            : text.split(separator: "\n").map { "<a:p><a:r>\(rPr)<a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return "<a:tc\(attrs.isEmpty ? "" : " " + attrs)><a:txBody><a:bodyPr/><a:lstStyle/>\(paras)</a:txBody>"
            + "<a:tcPr\(tcPrAttrs.isEmpty ? "" : " " + tcPrAttrs)>\(tcPr)</a:tcPr></a:tc>"
    }

    /// A table frame at `origin`; `cols` widths and row heights in points, each row's cells as `a:tc` XML.
    static func grid(_ id: Int, at origin: CGPoint, cols: [Double], rows: [(Double, [String])],
                     tblPr: String = "<a:tblPr/>", xfrmAttrs: String = "") -> String {
        let width = cols.reduce(0, +), height = rows.map(\.0).reduce(0, +)
        let gridCols = cols.map { "<a:gridCol w=\"\(emu($0))\"/>" }.joined()
        let trs = rows.map { "<a:tr h=\"\(emu($0.0))\">\($0.1.joined())</a:tr>" }.joined()
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"tbl\(id)\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm\(xfrmAttrs)><a:off x=\"\(emu(origin.x))\" y=\"\(emu(origin.y))\"/><a:ext cx=\"\(emu(width))\" cy=\"\(emu(height))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl>\(tblPr)"
            + "<a:tblGrid>\(gridCols)</a:tblGrid>\(trs)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    static func tblPr(_ styleId: String?, _ flags: String = "") -> String {
        "<a:tblPr \(flags)>" + (styleId.map { "<a:tableStyleId>\($0)</a:tableStyleId>" } ?? "") + "</a:tblPr>"
    }

    static func lnFill(_ tag: String, _ hex: String, w: Int = 12700) -> String {
        "<a:\(tag) w=\"\(w)\">\(solid(hex))</a:\(tag)>"
    }

    /// A `a:tblStyleLst` with the given `a:tblStyle` elements.
    static func tableStyles(def: String, _ styles: String) -> String {
        "<a:tblStyleLst xmlns:a=\"\(NS.a)\" def=\"\(def)\">\(styles)</a:tblStyleLst>"
    }

    static func stylePart(_ name: String, fill: String, txStyle: String = "") -> String {
        "<a:\(name)>\(txStyle)<a:tcStyle><a:tcBdr/><a:fill>\(solid(fill))</a:fill></a:tcStyle></a:\(name)>"
    }

    static let headerTxStyle = "<a:tcTxStyle b=\"on\"><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef>"
        + "<a:schemeClr val=\"lt1\"/></a:tcTxStyle>"

    /// wholeTbl green, band1H blue, firstRow red with bold lt1 text.
    static let testStyle = "<a:tblStyle styleId=\"{T1}\" styleName=\"Test\">" + stylePart("wholeTbl", fill: "00FF00")
        + stylePart("band1H", fill: "0000FF") + stylePart("firstRow", fill: "FF0000", txStyle: headerTxStyle) + "</a:tblStyle>"

    static let mediumStyle2Accent1 = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"
}

@Suite struct TableTests {
    private func deck(_ shapes: String, tableStyles: String? = nil) throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: shapes)]
        f.tableStyles = tableStyles
        return try f.open()
    }

    private func table(_ d: SlideDeck, _ i: Int = 0) throws -> TableLayout {
        let layout = d.store.textLayout(try #require(d.slide(i)))
        return try #require(layout.tables.values.sorted { $0.id < $1.id }.first)
    }

    private func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    private func rgb(_ px: Pixels, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * px.width + x) * 4
        return (Int(px.bytes[i]), Int(px.bytes[i + 1]), Int(px.bytes[i + 2]))
    }

    /// Four rows of 30 pt in one 200 pt column at (100, 100); a text in each.
    private func fourRows() -> [(Double, [String])] {
        [(30, [X.tc("Kopf")]), (30, [X.tc("Eins")]), (30, [X.tc("Zwei")]), (30, [X.tc("Drei")])]
    }

    // MARK: geometry

    @Test func columnWidthsAndRowHeightsFromGridAndTr() throws {
        // Rotation and flip of the frame are ignored (PowerPoint does not rotate tables).
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 200],
                                rows: [(40, [X.tc("A"), X.tc("B")]), (50, [X.tc("C"), X.tc("D")])],
                                xfrmAttrs: " rot=\"5400000\" flipH=\"1\""))
        let t = try table(o.deck)
        let rects = t.cells.map(\.rect)
        try #require(rects.count == 4)
        #expect(near(rects[0], CGRect(x: 100, y: 100, width: 100, height: 40)))
        #expect(near(rects[1], CGRect(x: 200, y: 100, width: 200, height: 40)))
        #expect(near(rects[2], CGRect(x: 100, y: 140, width: 100, height: 50)))
        #expect(near(rects[3], CGRect(x: 200, y: 140, width: 200, height: 50)))
        #expect(near(t.bounds, CGRect(x: 100, y: 100, width: 300, height: 90)))
    }

    @Test func rowGrowsToFitItsText() throws {
        let long = X.tc("Donaudampfschiff Kapitaen Muetze Hut Stock Mantel", rPr: "<a:rPr lang=\"de-DE\" sz=\"1800\"/>")
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100],
                                rows: [(20, [long]), (20, [X.tc("", tcPr: X.solid("00FF00"))])]))
        let t = try table(o.deck)
        try #require(t.cells.count == 2)
        let text = t.cells[0].text.sets.map(\.height).reduce(0, +)
        #expect(t.cells[0].text.sets.first.map { $0.lines.count > 2 } == true)
        // Text height plus the default top and bottom margins (45720 EMU = 3.6 pt each).
        #expect(abs(t.cells[0].rect.height - (text + 7.2)) < 0.01)
        #expect(t.cells[0].rect.height > 60)
        #expect(abs(t.cells[1].rect.minY - t.cells[0].rect.maxY) < 0.01)
        #expect(abs(t.cells[1].rect.height - 20) < 0.01)
        let px = o.deck.pixels(0)
        #expect(px.hex(150, Int(t.cells[1].rect.midY)) == "00FF00")
        #expect(px.hex(195, Int(t.cells[0].rect.maxY) - 2) == "FFFFFF")
    }

    @Test func gridSpanAndVMergeDrawOnce() throws {
        let half = "<a:solidFill><a:srgbClr val=\"0000FF\"><a:alpha val=\"50000\"/></a:srgbClr></a:solidFill>"
        let red = X.solid("FF0000")
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100, 100], rows: [
            (40, [X.tc("A", attrs: "gridSpan=\"2\"", tcPr: half), X.tc("X", attrs: "hMerge=\"1\"", tcPr: red), X.tc("C")]),
            (40, [X.tc("D", attrs: "rowSpan=\"2\"", tcPr: half), X.tc("E"), X.tc("F")]),
            (40, [X.tc("Y", attrs: "vMerge=\"1\"", tcPr: red), X.tc("G"), X.tc("H")]),
        ]))
        let t = try table(o.deck)
        try #require(t.cells.count == 7)
        #expect(near(t.cells[0].rect, CGRect(x: 100, y: 100, width: 200, height: 40)))
        #expect(near(t.cells[2].rect, CGRect(x: 100, y: 140, width: 100, height: 80)))
        let px = o.deck.pixels(0)
        for (x, y) in [(250, 135), (150, 135), (150, 210), (110, 215)] {
            let c = rgb(px, x, y)
            #expect(c.b == 255 && (0x7C...0x83).contains(c.r) && c.r == c.g, "(\(x), \(y)) = \(px.hex(x, y))")
        }
        #expect(o.deck.slideText(0) == "A C D E F G H")
    }

    @Test func twoByTwoAnchorWithGridSpanAndRowSpan() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100, 100], rows: [
            (40, [X.tc("A", attrs: "gridSpan=\"2\" rowSpan=\"2\""), X.tc("X", attrs: "hMerge=\"1\""), X.tc("B")]),
            (40, [X.tc("Y", attrs: "vMerge=\"1\""), X.tc("Z", attrs: "hMerge=\"1\" vMerge=\"1\""), X.tc("C")]),
            (40, [X.tc("D"), X.tc("E"), X.tc("F")]),
        ]))
        let t = try table(o.deck)
        try #require(t.cells.count == 6)
        #expect(t.cells[0].span == CellSpan(row: 0, col: 0, rowEnd: 2, colEnd: 2))
        #expect(near(t.cells[0].rect, CGRect(x: 100, y: 100, width: 200, height: 80)))
        #expect(o.deck.slideText(0) == "A B C D E F")
    }

    @Test func overlappingSpansNeverDrawOverAnotherAnchor() throws {
        let half = "<a:solidFill><a:srgbClr val=\"0000FF\"><a:alpha val=\"50000\"/></a:srgbClr></a:solidFill>"
        // P spans columns 0–1; the old-style vMerge under it extends P over its whole width into row 1, so S
        // (row 1, column 1) lies inside P and is dropped instead of drawing over it. Q (column 1 of row 0) is a
        // covered slot; its rowSpan is ignored. T wants all three columns of row 2 and gets them.
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100, 100], rows: [
            (40, [X.tc("P", attrs: "gridSpan=\"2\"", tcPr: half), X.tc("Q", attrs: "rowSpan=\"3\""), X.tc("R")]),
            (40, [X.tc("", attrs: "vMerge=\"1\""), X.tc("S", tcPr: X.solid("FF0000")), X.tc("", attrs: "vMerge=\"1\"")]),
            (40, [X.tc("T", attrs: "gridSpan=\"3\""), X.tc("U"), X.tc("V")]),
        ]))
        let t = try table(o.deck)
        #expect(t.cells.map(\.span) == [CellSpan(row: 0, col: 0, rowEnd: 2, colEnd: 2), CellSpan(row: 0, col: 2, rowEnd: 2, colEnd: 3),
                                        CellSpan(row: 2, col: 0, rowEnd: 3, colEnd: 3)])
        var seen = Set<[Int]>()
        for c in t.cells {
            for r in c.span.row..<c.span.rowEnd {
                for k in c.span.col..<c.span.colEnd { #expect(seen.insert([r, k]).inserted, "slot \(r),\(k)") }
            }
        }
        let px = o.deck.pixels(0)
        let mid = rgb(px, 250, 175) // row 1, column 1: P's half blue, drawn once, no red
        #expect(mid.b == 255 && mid.r == mid.g && (0x7C...0x83).contains(mid.r), "\(px.hex(250, 175))")
        #expect(o.deck.slideText(0) == "P R T")
    }

    // MARK: borders and fills

    @Test func cellBorderIsDrawnOnItsEdge() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100], rows: [
            (40, [X.tc("A", tcPr: X.lnFill("lnB", "FF0000", w: 38100)), X.tc("B")]),
            (40, [X.tc("C"), X.tc("D", tcPr: X.lnFill("lnTlToBr", "0000FF", w: 25400))]),
        ]))
        let px = o.deck.pixels(0)
        #expect(px.hex(150, 140) == "FF0000")
        #expect(px.hex(150, 139) == "FF0000")
        #expect(px.hex(150, 136) == "FFFFFF")
        #expect(px.hex(250, 140) == "FFFFFF") // no table style, no own border
        #expect(px.hex(250, 160) == "0000FF") // the diagonal through the cell centre
        #expect(px.hex(280, 145) == "FFFFFF")
    }

    @Test func cellFillCoversTheCell() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100],
                                rows: [(40, [X.tc("A"), X.tc("B", tcPr: X.solid("00FF00"))])]))
        let px = o.deck.pixels(0)
        #expect(px.hex(290, 135) == "00FF00")
        #expect(px.hex(201, 101) == "00FF00")
        #expect(px.hex(190, 135) == "FFFFFF")
        #expect(px.hex(301, 120) == "FFFFFF")
    }

    // MARK: table styles

    @Test func tableStyleFirstRowFillAndBoldHeaderText() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                tblPr: X.tblPr("{T1}", "firstRow=\"1\"")),
                         tableStyles: X.tableStyles(def: "{T1}", X.testStyle))
        let px = o.deck.pixels(0)
        #expect(px.hex(290, 125) == "FF0000")
        #expect(px.hex(290, 155) == "00FF00") // bandRow off: no band
        let t = try table(o.deck)
        let head = try #require(t.cells[0].text.paragraphs.first?.runs.first?.style)
        let body = try #require(t.cells[1].text.paragraphs.first?.runs.first?.style)
        #expect(head.bold)
        #expect(head.color == RGBA(hex: "EEEEEE"))
        #expect(!body.bold)
        #expect(body.color == RGBA(hex: "111111"))
    }

    @Test func band1HOnlyWithBandRow() throws {
        let styles = X.tableStyles(def: "{T1}", X.testStyle)
        let on = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                 tblPr: X.tblPr("{T1}", "firstRow=\"1\" bandRow=\"1\"")), tableStyles: styles)
        let px = on.deck.pixels(0)
        #expect(px.hex(290, 125) == "FF0000")
        #expect(px.hex(290, 155) == "0000FF")
        #expect(px.hex(290, 185) == "00FF00")
        #expect(px.hex(290, 215) == "0000FF")
        let off = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                  tblPr: X.tblPr("{T1}", "firstRow=\"1\" bandRow=\"0\"")), tableStyles: styles)
        let px2 = off.deck.pixels(0)
        #expect(px2.hex(290, 155) == "00FF00")
        #expect(px2.hex(290, 215) == "00FF00")
    }

    @Test func runBoldOffOverridesTableStyleBold() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [100, 100],
                                rows: [(30, [X.tc("Fett"), X.tc("Mager", rPr: "<a:rPr lang=\"de-DE\" sz=\"1000\" b=\"0\"/>")])],
                                tblPr: X.tblPr("{T1}", "firstRow=\"1\"")),
                         tableStyles: X.tableStyles(def: "{T1}", X.testStyle))
        let t = try table(o.deck)
        #expect(t.cells[0].text.paragraphs.first?.runs.first?.style.bold == true)
        #expect(t.cells[1].text.paragraphs.first?.runs.first?.style.bold == false)
        #expect(t.cells[1].text.paragraphs.first?.runs.first?.style.color == RGBA(hex: "EEEEEE"))
    }

    @Test func builtInLightStyle2Accent1() throws {
        // D3 uses it without defining it; the deck's def would otherwise give Medium Style 2 bands.
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                tblPr: X.tblPr("{69012ECD-51FC-41F1-AA8D-1B2483CD663E}", "firstRow=\"1\" bandRow=\"1\"")),
                         tableStyles: X.tableStyles(def: X.mediumStyle2Accent1, ""))
        let px = o.deck.pixels(0)
        #expect(px.hex(290, 125) == "0000FF") // header: fillRef idx 1 with accent1
        #expect(px.hex(290, 155) == "FFFFFF") // body rows have no fill
        #expect(px.hex(290, 185) == "FFFFFF")
        // Outer left border: lnRef idx 1 (1 pt, centred on x = 100, so two half-covered pixel columns) in accent1.
        #expect([99, 100].allSatisfy { let c = rgb(px, $0, 185); return c.b == 255 && c.r < 0xA0 })
        // band1H rows get accent1 top/bottom lines (edge y = 160); band2H rows none, insideH has noFill.
        #expect([159, 160].allSatisfy { let c = rgb(px, 150, $0); return c.b == 255 && c.r < 0xA0 })
        let head = try #require(try table(o.deck).cells[0].text.paragraphs.first?.runs.first?.style)
        #expect(head.bold && head.color == RGBA(hex: "EEEEEE")) // bg1 → lt1
    }

    @Test func builtInLightStyle2WithoutAccent() throws {
        // D7 uses {7E9639D4-…} ("Light Style 2") without defining it; PowerPoint draws a tx1 header and tx1 lines.
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                tblPr: X.tblPr("{7E9639D4-E3E2-4D34-9284-5A2195B3D0D7}", "firstRow=\"1\" bandRow=\"1\"")),
                         tableStyles: X.tableStyles(def: X.mediumStyle2Accent1, ""))
        let px = o.deck.pixels(0)
        #expect(px.hex(290, 125) == "111111") // header: fillRef idx 1 with tx1 (dk1)
        #expect(px.hex(290, 155) == "FFFFFF")
        let c = rgb(px, 100, 185)
        #expect(c.r < 0x90 && c.r == c.g && c.g == c.b) // outer border in tx1
    }

    @Test func builtInThemedStyle2Accent2() throws {
        // D2 uses {18603FDC-…} without defining it; PowerPoint draws the body text in lt1.
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                tblPr: X.tblPr("{18603FDC-E32A-4AB5-989C-0864C3EAD2B8}", "firstRow=\"1\" bandRow=\"1\"")),
                         tableStyles: X.tableStyles(def: X.mediumStyle2Accent1, ""))
        let body = try #require(try table(o.deck).cells[2].text.paragraphs.first?.runs.first?.style)
        #expect(body.color == RGBA(hex: "EEEEEE"))
    }

    @Test func builtInMediumStyle2Accent1WhenTheDeckLacksIt() throws {
        // tableStyles.xml names it as default but does not define it (as in D5).
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                tblPr: X.tblPr(X.mediumStyle2Accent1, "firstRow=\"1\" bandRow=\"1\"")),
                         tableStyles: X.tableStyles(def: X.mediumStyle2Accent1, ""))
        let px = o.deck.pixels(0)
        #expect(px.hex(290, 125) == "0000FF") // accent1 header
        let band1 = rgb(px, 290, 155), band2 = rgb(px, 290, 185)
        #expect(band1.b == 255 && band1.r == band1.g && band1.r > 0x80 && band1.r < band2.r)
        #expect(band2.b == 255 && band2.r == band2.g && band2.r < 255)
        // The header's 3 pt lt1 bottom border on the edge at y = 130 (lt1 = EEEEEE in the fixture theme).
        #expect(px.hex(290, 129) == "EEEEEE")
        #expect(px.hex(290, 130) == "EEEEEE")
        let head = try #require(try table(o.deck).cells[0].text.paragraphs.first?.runs.first?.style)
        #expect(head.bold && head.color == RGBA(hex: "EEEEEE"))

        // An unknown ID with neither the ID nor def in the deck → the same built-in style.
        let unknown = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                      tblPr: X.tblPr("{DEADBEEF-0000-0000-0000-000000000000}", "firstRow=\"1\"")))
        #expect(unknown.deck.pixels(0).hex(290, 125) == "0000FF")
        // An unknown ID does not take the deck's def style (PowerPoint, D7): the built-in default again.
        let viaDef = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(),
                                     tblPr: X.tblPr("{DEADBEEF-0000-0000-0000-000000000000}", "firstRow=\"1\"")),
                              tableStyles: X.tableStyles(def: "{T1}", X.testStyle))
        #expect(viaDef.deck.pixels(0).hex(290, 125) == "0000FF")
        // No tableStyleId at all: no table style.
        let none = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200], rows: fourRows(), tblPr: "<a:tblPr firstRow=\"1\"/>"),
                            tableStyles: X.tableStyles(def: "{T1}", X.testStyle))
        #expect(none.deck.pixels(0).hex(290, 125) == "FFFFFF")
    }

    // MARK: anchor and text

    @Test func cellAnchorCenter() throws {
        let o = try deck(X.grid(3, at: CGPoint(x: 100, y: 100), cols: [200],
                                rows: [(100, [X.tc("Mitte", tcPrAttrs: "anchor=\"ctr\"")]), (100, [X.tc("Oben")])]))
        let boxes = o.deck.wordBoxes(0)
        try #require(boxes.count == 2)
        #expect(abs(boxes[0].box.midY * 540 - 150) < 2)
        #expect(abs(boxes[1].box.minY * 540 - (200 + 3.6)) < 3)
        #expect(abs(boxes[0].box.minX * 960 - (100 + 7.2)) < 1)
    }

    @Test func tableTextInOrderWithBoxesInsideTheirCells() throws {
        let o = try deck(X.words(2, CGRect(x: 50, y: 20, width: 300, height: 40), ["Vor"])
            + X.grid(3, at: CGPoint(x: 100, y: 100), cols: [150, 150],
                     rows: [(40, [X.tc("Alpha Beta"), X.tc("Gamma")]), (40, [X.tc(""), X.tc("Delta\nEpsilon")])])
            + X.words(4, CGRect(x: 50, y: 400, width: 300, height: 40), ["Nach"]))
        #expect(o.deck.slideText(0) == "Vor Alpha Beta Gamma Delta Epsilon Nach")
        let text = o.deck.slideText(0) as NSString
        let boxes = o.deck.wordBoxes(0)
        #expect(boxes.map { text.substring(with: $0.range) } == ["Vor", "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Nach"])
        let cells = try table(o.deck).cells
        let cellOf: [String: Int] = ["Alpha": 0, "Beta": 0, "Gamma": 1, "Delta": 3, "Epsilon": 3]
        for b in boxes {
            guard let c = cellOf[text.substring(with: b.range)] else { continue }
            let r = CGRect(x: b.box.minX * 960, y: b.box.minY * 540, width: b.box.width * 960, height: b.box.height * 540)
            #expect(cells[c].rect.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(text.substring(with: b.range)) \(r)")
        }
    }

    // MARK: hostile input

    @Test func hostileValuesDoNotTrap() throws {
        let hostile = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"5\" name=\"h\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"1e300\" y=\"-1e300\"/><a:ext cx=\"nan\" cy=\"inf\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl>"
            + "<a:tblPr firstRow=\"1\" bandRow=\"1\" bandCol=\"1\"><a:tableStyleId>garbage</a:tableStyleId></a:tblPr>"
            + "<a:tblGrid><a:gridCol w=\"-5000000\"/><a:gridCol w=\"nan\"/><a:gridCol w=\"1e300\"/><a:gridCol/></a:tblGrid>"
            + "<a:tr h=\"-1\">" + X.tc("Eins", attrs: "gridSpan=\"1000000\" rowSpan=\"99999999999999999999\"",
                                     tcPrAttrs: "marL=\"-1e20\" marT=\"1e300\" anchor=\"zz\"") + X.tc("Zwei", attrs: "rowSpan=\"-3\"") + "</a:tr>"
            + "<a:tr h=\"inf\">" + X.tc("Drei", attrs: "hMerge=\"1\" vMerge=\"1\"") + X.tc("Vier", attrs: "gridSpan=\"-7\"") + "</a:tr>"
            + "<a:tr h=\"1e300\">" + String(repeating: X.tc("x", attrs: "gridSpan=\"nan\""), count: 6) + "</a:tr>"
            + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let zeroRows = X.grid(6, at: CGPoint(x: 10, y: 10), cols: [100], rows: [])
        let noGrid = X.grid(7, at: CGPoint(x: 10, y: 300), cols: [], rows: [(20, [X.tc("Ohne"), X.tc("Raster")])])
        let o = try deck(X.words(2, CGRect(x: 50, y: 20, width: 300, height: 40), ["Vor"]) + hostile + zeroRows + noGrid,
                         tableStyles: "<a:tblStyleLst xmlns:a=\"\(NS.a)\" def=\"{X}\"><a:tblStyle styleId=\"garbage\"><a:wholeTbl>"
                             + "<a:tcStyle><a:fillRef idx=\"99999999999999999999\"/><a:tcBdr><a:left><a:lnRef idx=\"-4\"/></a:left></a:tcBdr>"
                             + "</a:tcStyle></a:wholeTbl></a:tblStyle></a:tblStyleLst>")
        _ = o.deck.pixels(0)
        _ = o.deck.thumbnail(0, maxPixel: 64)
        let text = o.deck.slideText(0)
        #expect(text.hasPrefix("Vor"))
        #expect(o.deck.wordBoxes(0).allSatisfy { $0.box.minX >= 0 && $0.box.maxX <= 1 && $0.box.minY >= 0 && $0.box.maxY <= 1 })
    }

    // MARK: degenerate slide sizes (thumbnail)

    @Test func thumbnailSizeNearTheLargestCGFloat() {
        // long · a would overflow to infinity; the ratio is taken first.
        let big = CGSize(width: 1.7e308, height: 1.7e308)
        #expect(SlideDeck.thumbnailSize(big, maxPixel: 16384).map { [$0.0, $0.1] } == [16384, 16384])
        #expect(SlideDeck.thumbnailSize(CGSize(width: 1.7e308, height: 0.85e308), maxPixel: 16384).map { [$0.0, $0.1] } == [16384, 8192])
        #expect(SlideDeck.thumbnailSize(CGSize(width: 1, height: 1.7e308), maxPixel: 100).map { [$0.0, $0.1] } == [1, 100])
        #expect(SlideDeck.thumbnailSize(CGSize(width: CGFloat.infinity, height: 1), maxPixel: 100) == nil)
        #expect(SlideDeck.thumbnailSize(CGSize(width: 0, height: 1), maxPixel: 100) == nil)
    }

    @Test func thumbnailWithDegenerateSlideSize() throws {
        func open(_ sz: String) throws -> OpenedDeck {
            var f = PptxFixture()
            f.sldSzAttrs = sz
            f.slides = [.init(shapes: X.sp(2, CGRect(x: 10, y: 10, width: 50, height: 50), fill: "FF0000"))]
            return try f.open()
        }
        // cx="0": PresentationInfo falls back to 720 × 540.
        let zero = try open("cx=\"0\" cy=\"6858000\"")
        let t0 = try #require(zero.deck.thumbnail(0, maxPixel: 256))
        #expect(t0.width == 256 && t0.height == 192)
        // Huge: the short side is clamped to at least one pixel.
        let huge = try open("cx=\"1e300\" cy=\"6858000\"")
        let t1 = try #require(huge.deck.thumbnail(0, maxPixel: 256))
        #expect(t1.width == 256 && t1.height == 1)
        let square = try open("cx=\"1e300\" cy=\"1e300\"")
        let t2 = try #require(square.deck.thumbnail(0, maxPixel: 256))
        #expect(t2.width == 256 && t2.height == 256)
        // Infinite: no thumbnail, no trap anywhere.
        let inf = try open("cx=\"inf\" cy=\"6858000\"")
        #expect(inf.deck.thumbnail(0, maxPixel: 256) == nil)
        _ = inf.deck.slideText(0)
        _ = inf.deck.wordBoxes(0)
        _ = Pixels(width: 10, height: 10) { inf.deck.draw(0, in: $0, rect: CGRect(x: 0, y: 0, width: 10, height: 10)) }
    }
}

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>: renders every visible slide with a table at 1600 px
/// to /tmp/slidekit-t12a/ (local comparison output only), prints the table style IDs (and whether the deck
/// defines them) and every table whose laid-out text differs from its plain XML text.
@Suite struct TableCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]

    @Test(.enabled(if: corpus != nil)) func renderTableSlides() throws {
        let dir = URL(fileURLWithPath: try #require(Self.corpus))
        let out = URL(fileURLWithPath: "/tmp/slidekit-t12a", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let deck = try SlideDeck(url: url)
            let styles = deck.store.tableStyles()
            let name = url.deletingPathExtension().lastPathComponent.prefix(12)
            for i in 0..<deck.slideCount {
                let ref = try #require(deck.slide(i))
                let model = deck.store.slideModel(ref.partPath)
                let frames = Self.tableFrames(model.elements)
                guard !frames.isEmpty else { continue }
                let layout = deck.store.textLayout(ref)
                for f in frames {
                    guard let t = f.table, let tbl = f.graphicData?.child("tbl") else { continue }
                    let id = tbl.child("tblPr")?.child("tableStyleId")?.text ?? "-"
                    let known = TableStyleList.normalize(id).map { styles.styles[$0] != nil } ?? false
                    print("[corpus-table] \(name) #\(i + 1) (\(ref.partPath)): style \(id) in deck: \(known), "
                          + "\(t.columns.count) cols × \(t.rowHeights.count) rows, \(t.cells.count) cells")
                    let laidOut = (layout.tables[t.id]?.cells ?? []).flatMap { c -> [String] in
                        let p = c.text.sets.map(\.plainText)
                        return p.contains { !$0.isEmpty } ? p : []
                    }
                    let xml = Self.xmlParagraphs(tbl)
                    if laidOut != xml { print("[corpus-table]   text differs:\n    xml: \(xml)\n    new: \(laidOut)") }
                }
                let image = try #require(deck.thumbnail(i, maxPixel: 1600))
                let dest = try #require(CGImageDestinationCreateWithURL(
                    out.appendingPathComponent("\(name)-\(i + 1).png") as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
    }

    static func tableFrames(_ elements: [SlideElement]) -> [GraphicFrameModel] {
        elements.flatMap { e -> [GraphicFrameModel] in
            switch e {
            case .graphicFrame(let f): f.table == nil ? [] : [f]
            case .group(_, let children): tableFrames(children)
            default: []
            }
        }
    }

    /// Task 11's XML table text: runs, fields' stored text, breaks; hMerge/vMerge and empty cells skipped.
    static func xmlParagraphs(_ tbl: OOXMLNode) -> [String] {
        var out: [String] = []
        for tr in tbl.children("tr") {
            for tc in tr.children("tc") {
                if Transform2D.isTrue(tc.attr("hMerge")) || Transform2D.isTrue(tc.attr("vMerge")) { continue }
                let paras = (tc.child("txBody")?.children("p") ?? []).map { p in
                    p.children.map { c in
                        switch c.name {
                        case "r", "fld": c.child("t")?.text ?? ""
                        case "br": "\n"
                        default: ""
                        }
                    }.joined()
                }
                if paras.contains(where: { !$0.isEmpty }) { out += paras }
            }
        }
        return out
    }
}
