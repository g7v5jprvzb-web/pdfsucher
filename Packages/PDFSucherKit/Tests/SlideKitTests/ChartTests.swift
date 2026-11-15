// ChartTests.swift — Task 12b (SlideKit tests)
// Charts (c:chartSpace): bar/column (clustered, stacked), line, pie/doughnut with series and point colours,
// title/categories/legend in slideText, unsupported types and hostile values.
import CoreGraphics
import Foundation
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

enum C {
    static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"

    static func strCache(_ values: [String]) -> String {
        "<c:strCache><c:ptCount val=\"\(values.count)\"/>"
            + values.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\($0.element)</c:v></c:pt>" }.joined() + "</c:strCache>"
    }

    static func numCache(_ values: [String], ptCount: String? = nil) -> String {
        "<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(ptCount ?? String(values.count))\"/>"
            + values.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\($0.element)</c:v></c:pt>" }.joined() + "</c:numCache>"
    }

    /// One `c:ser`; `color` = an explicit solid fill (hex), `line` = an explicit 4 pt line colour.
    static func ser(_ idx: Int, name: String? = nil, cats: [String]? = nil, values: [String], color: String? = nil,
                    line: String? = nil, extra: String = "") -> String {
        var s = "<c:ser><c:idx val=\"\(idx)\"/><c:order val=\"\(idx)\"/>"
        if let name { s += "<c:tx><c:strRef><c:f>S!$B$1</c:f>\(strCache([name]))</c:strRef></c:tx>" }
        if color != nil || line != nil {
            s += "<c:spPr>" + (color.map { X.solid($0) } ?? "")
                + (line.map { "<a:ln w=\"50800\">\(X.solid($0))</a:ln>" } ?? "") + "</c:spPr>"
        }
        s += extra
        if let cats { s += "<c:cat><c:strRef><c:f>S!$A$2</c:f>\(strCache(cats))</c:strRef></c:cat>" }
        s += "<c:val><c:numRef><c:f>S!$B$2</c:f>\(numCache(values))</c:numRef></c:val></c:ser>"
        return s
    }

    static func bar(_ series: String, dir: String = "col", grouping: String = "clustered", extra: String = "") -> String {
        "<c:barChart><c:barDir val=\"\(dir)\"/><c:grouping val=\"\(grouping)\"/><c:varyColors val=\"0\"/>\(series)"
            + "<c:gapWidth val=\"100\"/>\(extra)<c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>"
    }

    static func line(_ series: String) -> String {
        "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(series)<c:marker val=\"1\"/>"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:lineChart>"
    }

    static func pie(_ series: String, kind: String = "pieChart", extra: String = "") -> String {
        "<c:\(kind)><c:varyColors val=\"1\"/>\(series)\(extra)</c:\(kind)>"
    }

    static func axes(deleted: Bool) -> String {
        let d = deleted ? "1" : "0"
        return "<c:catAx><c:axId val=\"1\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"\(d)\"/><c:axPos val=\"b\"/><c:crossAx val=\"2\"/></c:catAx>"
            + "<c:valAx><c:axId val=\"2\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"\(d)\"/><c:axPos val=\"l\"/>"
            + "<c:majorGridlines/><c:crossAx val=\"1\"/></c:valAx>"
    }

    static func chartSpace(_ plot: String, axes: String = C.axes(deleted: true), title: String = "",
                           autoTitleDeleted: Bool = true, legend: String = "") -> String {
        "<c:chartSpace xmlns:c=\"\(NS.c)\" xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\"><c:chart>\(title)"
            + "<c:autoTitleDeleted val=\"\(autoTitleDeleted ? 1 : 0)\"/><c:plotArea><c:layout/>\(plot)\(axes)</c:plotArea>\(legend)"
            + "<c:plotVisOnly val=\"1\"/></c:chart></c:chartSpace>"
    }

    static func title(_ text: String) -> String {
        "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"de-DE\" sz=\"1400\"/><a:t>\(text)</a:t></a:r></a:p></c:rich></c:tx>"
            + "<c:overlay val=\"0\"/></c:title>"
    }

    static func legend(_ pos: String) -> String { "<c:legend><c:legendPos val=\"\(pos)\"/><c:overlay val=\"0\"/></c:legend>" }

    static func deck(_ chartXML: String, frame: CGRect, rId: String = "rId5", target: String = "../charts/chart1.xml") throws -> OpenedDeck {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.frame(4, frame, uri: chartURI, "<c:chart xmlns:c=\"\(NS.c)\" r:id=\"\(rId)\"/>"),
                          rels: X.rel("rId5", "chart", target))]
        f.media["ppt/charts/chart1.xml"] = Data(chartXML.utf8)
        return try f.open()
    }
}

/// Runs of pixels with one exact colour along a scan line.
extension Pixels {
    /// Per column x in `xs`: the count of pixels of `hex` in rows `ys`.
    func columnCounts(_ hex: String, xs: Range<Int>, ys: Range<Int>) -> [Int] {
        xs.map { x in ys.reduce(0) { $0 + (self.hex(x, $1) == hex ? 1 : 0) } }
    }

    func rowCounts(_ hex: String, xs: Range<Int>, ys: Range<Int>) -> [Int] {
        ys.map { y in xs.reduce(0) { $0 + (self.hex($1, y) == hex ? 1 : 0) } }
    }

    /// Consecutive runs of non-zero counts → (start, length, median count).
    static func bars(_ counts: [Int]) -> [(start: Int, length: Int, height: Int)] {
        var out: [(Int, Int, Int)] = []
        var i = 0
        while i < counts.count {
            guard counts[i] > 0 else { i += 1; continue }
            var j = i
            while j < counts.count, counts[j] > 0 { j += 1 }
            let sorted = counts[i..<j].sorted()
            out.append((i, j - i, sorted[sorted.count / 2]))
            i = j
        }
        return out
    }

    func count(_ hex: String, in r: CGRect) -> Int {
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where self.hex(x, y) == hex { n += 1 } }
        return n
    }
}

@Suite struct ChartTests {
    static let frame = CGRect(x: 40, y: 40, width: 400, height: 300)
    static let xs = 40..<440, ys = 40..<340

    @Test func clusteredColumnBarsHaveRelativeHeights() throws {
        let series = C.ser(0, name: "A", cats: ["x", "y", "z"], values: ["10", "20", "40"])
            + C.ser(1, name: "B", cats: ["x", "y", "z"], values: ["5", "5", "5"], color: "FF0000")
        let o = try C.deck(C.chartSpace(C.bar(series)), frame: Self.frame)
        let px = o.deck.pixels(0)
        // Series 1 without spPr: accent1 (blue); series 2: its own red.
        let blue = Pixels.bars(px.columnCounts("0000FF", xs: Self.xs, ys: Self.ys))
        let red = Pixels.bars(px.columnCounts("FF0000", xs: Self.xs, ys: Self.ys))
        try #require(blue.count == 3 && red.count == 3)
        let h = blue.map { Double($0.height) }
        #expect(abs(h[1] / h[0] - 2) < 0.06)
        #expect(abs(h[2] / h[0] - 4) < 0.1)
        #expect(abs(Double(red[0].height) / h[0] - 0.5) < 0.05)
        // Clustered: each red bar right next to its blue bar, same width.
        for k in 0..<3 {
            #expect(red[k].start > blue[k].start)
            #expect(abs(red[k].length - blue[k].length) <= 2)
        }
        // Bars sit on a common baseline.
        let bottoms = (0..<3).map { k in
            (Self.ys).last { px.hex(Self.xs.lowerBound + blue[k].start + blue[k].length / 2, $0) == "0000FF" } ?? 0
        }
        #expect(bottoms.max()! - bottoms.min()! <= 1)
    }

    @Test func stackedColumnsStackSeries() throws {
        let series = C.ser(0, values: ["10", "10"]) + C.ser(1, values: ["10", "30"], color: "FF0000")
        let o = try C.deck(C.chartSpace(C.bar(series, grouping: "stacked", extra: "<c:overlap val=\"100\"/>")), frame: Self.frame)
        let px = o.deck.pixels(0)
        let blue = Pixels.bars(px.columnCounts("0000FF", xs: Self.xs, ys: Self.ys))
        let red = Pixels.bars(px.columnCounts("FF0000", xs: Self.xs, ys: Self.ys))
        try #require(blue.count == 2 && red.count == 2)
        #expect(abs(blue[0].height - blue[1].height) <= 1)
        #expect(abs(Double(red[1].height) / Double(red[0].height) - 3) < 0.1)
        #expect(abs(red[0].start - blue[0].start) <= 1)
        // Red on top of blue.
        let x = Self.xs.lowerBound + blue[0].start + blue[0].length / 2
        let blueTop = Self.ys.first { px.hex(x, $0) == "0000FF" }!
        let redBottom = Self.ys.last { px.hex(x, $0) == "FF0000" }!
        #expect(abs(blueTop - redBottom) <= 2)
    }

    @Test func horizontalBars() throws {
        let o = try C.deck(C.chartSpace(C.bar(C.ser(0, values: ["10", "20"]), dir: "bar")), frame: Self.frame)
        let px = o.deck.pixels(0)
        let bars = Pixels.bars(px.rowCounts("0000FF", xs: Self.xs, ys: Self.ys))
        try #require(bars.count == 2)
        // The first category is at the bottom.
        #expect(abs(Double(bars[0].height) / Double(bars[1].height) - 2) < 0.06)
    }

    @Test func pieWedgesInAccentColours() throws {
        let frame = CGRect(x: 300, y: 100, width: 300, height: 300)
        let dPt = "<c:dPt><c:idx val=\"3\"/><c:bubble3D val=\"0\"/><c:spPr>\(X.solid("000000"))</c:spPr></c:dPt>"
        let o = try C.deck(C.chartSpace(C.pie(C.ser(0, cats: ["A", "B", "C", "D"], values: ["1", "1", "1", "1"], extra: dPt)),
                                        axes: ""), frame: frame)
        let px = o.deck.pixels(0)
        // Clockwise from 12 o'clock: accent1 top right, accent2 bottom right, accent3 bottom left, dPt 4 top left.
        #expect(px.hex(450 + 40, 250 - 40) == "0000FF")
        #expect(px.hex(450 + 40, 250 + 40) == "00FF00")
        #expect(px.hex(450 - 40, 250 + 40) == "FF0000")
        #expect(px.hex(450 - 40, 250 - 40) == "000000")
        #expect(px.hex(305, 105) == "FFFFFF")
    }

    @Test func doughnutHasAHole() throws {
        let frame = CGRect(x: 300, y: 100, width: 300, height: 300)
        let o = try C.deck(C.chartSpace(C.pie(C.ser(0, values: ["1", "1"]), kind: "doughnutChart",
                                              extra: "<c:firstSliceAng val=\"0\"/><c:holeSize val=\"50\"/>"), axes: ""), frame: frame)
        let px = o.deck.pixels(0)
        #expect(px.hex(450, 250) == "FFFFFF")
        #expect(px.hex(450 + 110, 250) == "0000FF")
        #expect(px.hex(450 - 110, 250) == "00FF00")
    }

    @Test func pieSkipsNegativeAndNonFiniteValues() throws {
        let frame = CGRect(x: 300, y: 100, width: 300, height: 300)
        let o = try C.deck(C.chartSpace(C.pie(C.ser(0, values: ["-5", "NaN", "3", "abc", "1e400", "-inf", "0"])), axes: ""),
                           frame: frame)
        let px = o.deck.pixels(0)
        // Only point 3 (idx 2) is drawn: the whole pie in accent3.
        for (dx, dy) in [(40, -40), (40, 40), (-40, 40), (-40, -40)] { #expect(px.hex(450 + dx, 250 + dy) == "FF0000") }
    }

    @Test func lineChartDraws() throws {
        let o = try C.deck(C.chartSpace(C.line(C.ser(0, values: ["1", "3", "2"], line: "FF0000"))), frame: Self.frame)
        let px = o.deck.pixels(0)
        let cols = px.columnCounts("FF0000", xs: Self.xs, ys: Self.ys)
        let lit = cols.indices.filter { cols[$0] > 0 }
        try #require(lit.count > 100)
        // The highest point (min y) is the middle one.
        let tops = lit.map { x in (x, Self.ys.first { px.hex(Self.xs.lowerBound + x, $0) == "FF0000" }!) }
        let peak = tops.min { $0.1 < $1.1 }!.0
        let span = lit.last! - lit.first!
        #expect(abs(Double(peak - lit.first!) / Double(span) - 0.5) < 0.1)
    }

    @Test func titleCategoriesAndLegendInSlideText() throws {
        let series = C.ser(0, name: "Serie A", cats: ["Nord", "Süd"], values: ["3", "4"])
            + C.ser(1, name: "Serie B", cats: ["Nord", "Süd"], values: ["1", "2"])
        let o = try C.deck(C.chartSpace(C.bar(series), axes: C.axes(deleted: false), title: C.title("Umsatz 2024"),
                                        autoTitleDeleted: false, legend: C.legend("r")), frame: Self.frame)
        let text = o.deck.slideText(0)
        #expect(text == "Umsatz 2024 Nord Süd Serie A Serie B")
        let t = text as NSString
        let boxes = o.deck.wordBoxes(0)
        let words = boxes.map { t.substring(with: $0.range) }
        #expect(words.starts(with: ["Umsatz", "2024"]))
        #expect(words.contains("Nord") && words.contains("Serie"))
        // The title box is in the upper part of the frame, centred.
        let title = try #require(boxes.first).box
        let fr = CGRect(x: 40.0 / 960, y: 40.0 / 540, width: 400.0 / 960, height: 300.0 / 540)
        #expect(fr.contains(title))
        #expect(title.minY < fr.minY + fr.height * 0.15)
        let px = o.deck.pixels(0)
        #expect(px.count("0000FF", in: Self.frame) > 500)
        #expect(px.count("00FF00", in: Self.frame) > 200)
    }

    @Test func legendPositions() throws {
        var centres: [String: CGPoint] = [:]
        for pos in ["r", "l", "t", "b", "tr", "zz"] {
            let o = try C.deck(C.chartSpace(C.bar(C.ser(0, name: "Eins", values: ["1"]) + C.ser(1, name: "Zwei", values: ["2"])),
                                            legend: C.legend(pos)), frame: Self.frame)
            #expect(o.deck.slideText(0) == "Eins Zwei")
            let fr = CGRect(x: 40.0 / 960, y: 40.0 / 540, width: 400.0 / 960, height: 300.0 / 540).insetBy(dx: -0.001, dy: -0.001)
            let boxes = o.deck.wordBoxes(0)
            #expect(boxes.count == 2 && boxes.allSatisfy { fr.contains($0.box) })
            if let b = boxes.first?.box { centres[pos] = CGPoint(x: b.midX, y: b.midY) }
        }
        let l = try #require(centres["l"]), r = try #require(centres["r"])
        let t = try #require(centres["t"]), b = try #require(centres["b"])
        #expect(l.x < 0.2 && r.x > 0.3 && l.x < r.x)
        #expect(t.y < 0.2 && b.y > 0.5 && t.y < b.y)
        #expect(centres["tr"] == r && centres["zz"] == r)
    }

    @Test func barPointColourOverrides() throws {
        let dPt = "<c:dPt><c:idx val=\"1\"/><c:invertIfNegative val=\"0\"/><c:bubble3D val=\"0\"/><c:spPr>\(X.solid("FF0000"))</c:spPr></c:dPt>"
        let o = try C.deck(C.chartSpace(C.bar(C.ser(0, values: ["10", "10", "10"], extra: dPt))), frame: Self.frame)
        let px = o.deck.pixels(0)
        let blue = Pixels.bars(px.columnCounts("0000FF", xs: Self.xs, ys: Self.ys))
        let red = Pixels.bars(px.columnCounts("FF0000", xs: Self.xs, ys: Self.ys))
        try #require(blue.count == 2 && red.count == 1)
        #expect(blue[0].start < red[0].start && red[0].start < blue[1].start)
        // One series with varyColors: each bar in its accent.
        let vary = C.bar(C.ser(0, values: ["10", "10", "10"])).replacingOccurrences(of: "<c:varyColors val=\"0\"/>", with: "<c:varyColors val=\"1\"/>")
        let v = try C.deck(C.chartSpace(vary), frame: Self.frame).deck.pixels(0)
        for hex in ["0000FF", "00FF00", "FF0000"] {
            #expect(Pixels.bars(v.columnCounts(hex, xs: Self.xs, ys: Self.ys)).count == 1)
        }
    }

    @Test func unnamedSeriesAreNamedLikePowerPoint() throws {
        let o = try C.deck(C.chartSpace(C.bar(C.ser(0, values: ["1"]) + C.ser(1, values: ["2"])), legend: C.legend("r")),
                           frame: Self.frame)
        #expect(o.deck.slideText(0) == "Series1 Series2")
    }

    @Test func niceTicks() throws {
        #expect(ChartRenderer.ticks(lo: 5, hi: 5, fixedLo: false, fixedHi: false) == nil)
        let neg = try #require(ChartRenderer.ticks(lo: -37, hi: -3, fixedLo: false, fixedHi: false))
        #expect(neg.lo == -40 && neg.hi == 0 && neg.ticks == [-40, -30, -20, -10, 0])
        let tiny = try #require(ChartRenderer.ticks(lo: 1, hi: 1 + 1e-9, fixedLo: false, fixedHi: false))
        #expect(tiny.ticks.count >= 2 && tiny.ticks.count <= 50 && tiny.ticks.allSatisfy(\.isFinite))
        #expect(tiny.lo <= 1 && tiny.hi >= 1 + 1e-9)
        let plain = try #require(ChartRenderer.ticks(lo: 0, hi: 77, fixedLo: false, fixedHi: false))
        #expect(plain.ticks == [0, 20, 40, 60, 80])
        #expect(ChartRenderer.ticks(lo: 0, hi: .infinity, fixedLo: false, fixedHi: false) == nil)
        #expect(ChartRenderer.format(-0.0001, step: 0.5, percent: false) == "0.0")
        #expect(ChartRenderer.format(40, step: 20, percent: true) == "40%")
    }

    @Test func autoTitleForASingleSeries() throws {
        let o = try C.deck(C.chartSpace(C.bar(C.ser(0, name: "Einzige", values: ["1"])), autoTitleDeleted: false),
                           frame: Self.frame)
        #expect(o.deck.slideText(0) == "Einzige")
        let deleted = try C.deck(C.chartSpace(C.bar(C.ser(0, name: "Einzige", values: ["1"])), autoTitleDeleted: true),
                                 frame: Self.frame)
        #expect(deleted.deck.slideText(0) == "")
    }

    @Test func unsupportedChartTypeIsEmpty() throws {
        let area = "<c:areaChart><c:grouping val=\"standard\"/>\(C.ser(0, name: "A", cats: ["x"], values: ["1"]))</c:areaChart>"
        let o = try C.deck(C.chartSpace(area, axes: C.axes(deleted: false), title: C.title("Fläche"), legend: C.legend("r")),
                           frame: Self.frame)
        let px = o.deck.pixels(0)
        var nonWhite = 0
        for y in Self.ys { for x in Self.xs where px.hex(x, y) != "FFFFFF" { nonWhite += 1 } }
        #expect(nonWhite == 0)
        #expect(o.deck.slideText(0) == "")
    }

    @Test func secondChartGroupOfTheSameKindIsDrawn() throws {
        // Two lineCharts (as in the corpus chart, each on its own deleted axis): both series are drawn.
        let plot = C.line(C.ser(1, name: "B", values: ["1", "2"], line: "FF0000")) + C.line(C.ser(0, name: "A", values: ["2", "1"], line: "00FF00"))
        let o = try C.deck(C.chartSpace(plot, legend: C.legend("b")), frame: Self.frame)
        let px = o.deck.pixels(0)
        #expect(px.count("FF0000", in: Self.frame) > 100)
        #expect(px.count("00FF00", in: Self.frame) > 100)
        #expect(o.deck.slideText(0) == "B A")
    }

    @Test func hostileValuesDoNotCrash() throws {
        let nasty = ["NaN", "-inf", "1e308", "-1e308", "abc", "", "-5", "0", "1e-320"]
        let plots = [
            C.bar(C.ser(0, cats: ["a"], values: nasty) + C.ser(1, values: nasty), grouping: "stacked"),
            C.bar(C.ser(0, values: nasty), grouping: "percentStacked"),
            C.bar(C.ser(0, values: ["0", "0"]), grouping: "percentStacked"),
            C.bar(C.ser(0, values: nasty), dir: "bar", extra: "<c:gapWidth val=\"-500\"/><c:overlap val=\"1e9\"/>"),
            C.line(C.ser(0, values: nasty)),
            C.line(C.ser(0, values: ["5", "5", "5"])),
            C.pie(C.ser(0, values: nasty), kind: "doughnutChart", extra: "<c:holeSize val=\"nan\"/><c:firstSliceAng val=\"1e300\"/>"),
            C.pie(C.ser(0, values: ["0", "-1"]), kind: "pie3DChart"),
            C.pie("", kind: "pieChart"),
            C.bar(""),
            "<c:barChart><c:ser><c:val><c:numRef>\(C.numCache(["1"], ptCount: "1000000000000"))</c:numRef></c:val></c:ser></c:barChart>",
            "<c:barChart><c:ser><c:val><c:numRef><c:numCache><c:ptCount val=\"-3\"/><c:pt idx=\"-1\"><c:v>1</c:v></c:pt>"
                + "<c:pt idx=\"99999999999\"><c:v>2</c:v></c:pt><c:pt><c:v>3</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart>",
            "<c:lineChart><c:ser><c:tx><c:v>Literal</c:v></c:tx></c:ser></c:lineChart>",
        ]
        let scaling = "<c:catAx><c:axId val=\"1\"/><c:delete val=\"0\"/></c:catAx><c:valAx><c:axId val=\"2\"/><c:scaling>"
            + "<c:max val=\"-1e300\"/><c:min val=\"nan\"/></c:scaling><c:delete val=\"0\"/><c:majorGridlines/></c:valAx>"
        for plot in plots {
            for axes in [C.axes(deleted: false), scaling] {
                let o = try C.deck(C.chartSpace(plot, axes: axes, title: C.title("T"), legend: C.legend("r")), frame: Self.frame)
                _ = o.deck.pixels(0)
                _ = o.deck.slideText(0)
                _ = o.deck.wordBoxes(0)
            }
        }
        // Broken parts and references.
        let cases: [(String, String, String)] = [
            ("<c:chartSpace", "rId5", "../charts/chart1.xml"),
            ("<c:chartSpace xmlns:c=\"\(NS.c)\"/>", "rId5", "../charts/chart1.xml"),
            (C.chartSpace(C.bar(C.ser(0, values: ["1"]))), "rId77", "../charts/chart1.xml"),
            (C.chartSpace(C.bar(C.ser(0, values: ["1"]))), "rId5", "../charts/missing.xml"),
        ]
        for (xml, rId, target) in cases {
            let o = try C.deck(xml, frame: Self.frame, rId: rId, target: target)
            #expect(o.deck.pixels(0).hex(240, 190) == "FFFFFF")
            #expect(o.deck.slideText(0) == "")
        }
        // Zero-sized and non-finite frames.
        for frame in [CGRect(x: 40, y: 40, width: 0, height: 0), CGRect(x: 40, y: 40, width: 1, height: 1e9)] {
            let o = try C.deck(C.chartSpace(C.bar(C.ser(0, values: ["1"]))), frame: frame)
            _ = o.deck.pixels(0)
            _ = o.deck.wordBoxes(0)
        }
    }
}
