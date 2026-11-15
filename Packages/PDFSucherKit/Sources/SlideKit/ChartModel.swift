// ChartModel.swift — Task 12b (SlideKit)
// The supported subset of a chart part (`c:chartSpace`), resolved once while the slide model is built: the plot
// kind (the first barChart/bar3DChart, lineChart, pieChart/pie3DChart/doughnutChart of the plot area; further
// chart groups of the same family are kept), series from the cached values (`c:strCache`/`c:numCache`, literals
// too), colours, axes, legend, title and text styles. Anything else → no model (empty frame). Laid out and drawn
// by ChartRenderer.swift.
//
// Robustness: point counts are capped (`maxPoints`, `maxSeries`), values must be finite with |v| ≤ 1e15 (else
// the point is missing), every index is range-checked. Colours: `c:spPr` solid fill (a line's `a:ln` fill for
// line charts), else theme accent 1–6 by the series' `c:idx`; pie points use `c:dPt` overrides, else accent by
// point index when the group varies colours (docs/decisions.md).
import CoreGraphics
import Foundation
import OOXMLKit

/// Text properties of one chart element (title, legend, axis labels).
struct ChartTextStyle: Sendable, Equatable {
    var size: CGFloat
    var bold: Bool
    var color: RGBA
    var typeface: String?

    var run: RunStyle { RunStyle(typeface: typeface, size: size, bold: bold, color: color) }

    /// Applies `a:defRPr`/`a:rPr` attributes and children (sz, b, solid fill, latin typeface).
    func applying(_ rPr: OOXMLNode?, env: TextEnvironment) -> ChartTextStyle {
        guard let rPr else { return self }
        var s = self
        if let sz = TextEnvironment.number(rPr.attr("sz")), sz >= 100, sz <= 400_000 { s.size = CGFloat(sz / 100) }
        if let b = rPr.attr("b") { s.bold = TextEnvironment.flag(b) }
        if let fill = rPr.child("solidFill"), let c = ColorResolver.resolve(fill, in: env.colors) { s.color = c }
        if let t = env.typeface(rPr.child("latin")?.attr("typeface")) { s.typeface = t }
        return s
    }

    /// `c:txPr`'s first paragraph default run properties.
    func applying(txPr: OOXMLNode?, env: TextEnvironment) -> ChartTextStyle {
        applying(txPr?.child("p")?.child("pPr")?.child("defRPr"), env: env)
    }
}

struct ChartSeries: Sendable {
    let name: String
    /// One entry per category; nil = missing or unusable.
    let values: [Double?]
    let color: RGBA
    /// Line charts: the stroke width in points.
    let lineWidth: CGFloat
    /// `c:dPt` fill overrides by point index.
    let pointColors: [Int: RGBA]
}

struct ChartGroup: Sendable {
    enum Grouping: Sendable { case clustered, stacked, percentStacked }

    let grouping: Grouping
    let series: [ChartSeries]
    /// `c:gapWidth` in percent of a bar's width.
    let gapWidth: Double
    let varyColors: Bool
}

struct ChartModel: Sendable {
    enum Kind: Sendable, Equatable {
        /// Vertical bars (`barDir col`).
        case column
        /// Horizontal bars (`barDir bar`).
        case bar
        case line
        /// Pie or doughnut (`hole` = inner radius as a fraction of the outer one, 0 for a pie).
        case pie(hole: Double, firstSliceAngle: Double)
    }

    enum LegendPosition: Sendable { case right, left, top, bottom }

    static let maxPoints = 4096
    static let maxSeries = 255
    static let maxValue = 1e15
    static let defaultTextSize: CGFloat = 10
    /// Title size when the chart gives none: base size × this (PowerPoint: 18.6 pt over 13.3 pt).
    static let titleScale: CGFloat = 1.4

    /// Unique per slide model; keys `SlideTextLayout.charts`.
    let id: Int
    let kind: Kind
    /// Bar/line: every chart group of the family, in plot order; pie: the first group.
    let groups: [ChartGroup]
    /// One label per category (missing labels: the 1-based index).
    let categories: [String]
    /// Title paragraphs (empty = no title).
    let title: [String]
    let titleStyle: ChartTextStyle
    let legend: LegendPosition?
    let legendStyle: ChartTextStyle
    let categoryStyle: ChartTextStyle
    let valueStyle: ChartTextStyle
    let showCategoryLabels: Bool
    let showValueLabels: Bool
    let gridlines: Bool
    /// `c:scaling` min/max of the value axis.
    let valueMin: Double?
    let valueMax: Double?
    /// Solid fills of the chart space and of the plot area.
    let background: RGBA?
    let plotBackground: RGBA?
    /// Theme accents 1–6 (pie points without an override).
    let accents: [RGBA]

    var categoryCount: Int { categories.count }

    // MARK: parsing

    static let families: [String: String] = [
        "barChart": "bar", "bar3DChart": "bar", "lineChart": "line",
        "pieChart": "pie", "pie3DChart": "pie", "doughnutChart": "pie",
    ]

    /// nil when the chart has no supported plot (an empty frame is drawn).
    init?(chartSpace cs: OOXMLNode, id: Int, colors: ColorContext) {
        guard cs.name == "chartSpace", let chart = cs.child("chart"), let plot = chart.child("plotArea"),
              let first = plot.children.first(where: { Self.families[$0.name] != nil }),
              let family = Self.families[first.name] else { return nil }
        let env = TextEnvironment(colors: colors, fontRef: nil)
        self.id = id

        let groupNodes = family == "pie" ? [first] : plot.children.filter { Self.families[$0.name] == family }
        var running = 0
        var groups: [ChartGroup] = []
        for g in groupNodes {
            let isLine = family == "line"
            let vary = g.child("varyColors").map { Self.bool($0, default: true) } ?? (family == "pie")
            var series: [ChartSeries] = []
            for s in g.children("ser") where running < Self.maxSeries {
                series.append(Self.series(s, index: running, line: isLine, colors: colors))
                running += 1
            }
            let grouping: ChartGroup.Grouping = switch g.child("grouping")?.attr("val") {
            case "stacked": .stacked
            case "percentStacked": .percentStacked
            default: .clustered
            }
            let gap = TextEnvironment.number(g.child("gapWidth")?.attr("val")).map { min(max($0, 0), 500) } ?? 150
            groups.append(ChartGroup(grouping: grouping, series: series, gapWidth: gap, varyColors: vary))
        }
        self.groups = groups

        switch family {
        case "bar": kind = first.child("barDir")?.attr("val") == "bar" ? .bar : .column
        case "line": kind = .line
        default:
            let hole = first.name == "doughnutChart"
                ? (TextEnvironment.number(first.child("holeSize")?.attr("val")).map { min(max($0, 10), 90) } ?? 50) / 100 : 0
            let angle = TextEnvironment.number(first.child("firstSliceAng")?.attr("val"))
                .map { $0.truncatingRemainder(dividingBy: 360) } ?? 0
            kind = .pie(hole: hole, firstSliceAngle: angle)
        }

        // Categories: the first series with labels; the count is the longest series.
        let allSeries = groupNodes.flatMap { $0.children("ser") }
        let labels = allSeries.lazy.compactMap { $0.child("cat").flatMap(Self.labels) }.first ?? []
        let count = min(max(labels.count, groups.flatMap(\.series).map(\.values.count).max() ?? 0), Self.maxPoints)
        categories = (0..<count).map { i in labels.indices.contains(i) ? labels[i] ?? String(i + 1) : String(i + 1) }

        // Text styles: the chart space's txPr, then the element's own.
        let base = ChartTextStyle(size: Self.defaultTextSize, bold: false, color: env.defaultColor,
                                  typeface: env.typeface("+mn-lt"))
            .applying(txPr: cs.child("txPr"), env: env)
        let titleNode = chart.child("title")
        var titleStyle = base
        if cs.child("txPr")?.child("p")?.child("pPr")?.child("defRPr")?.attr("sz") == nil {
            titleStyle.size = base.size * Self.titleScale
        }
        titleStyle = titleStyle.applying(txPr: titleNode?.child("txPr"), env: env)
        let rich = titleNode?.child("tx")?.child("rich")
        titleStyle = titleStyle.applying(rich?.child("p")?.child("pPr")?.child("defRPr"), env: env)
        titleStyle = titleStyle.applying(rich?.child("p")?.children("r").first?.child("rPr"), env: env)
        self.titleStyle = titleStyle
        title = Self.title(titleNode, chart: chart, series: groups.flatMap(\.series), seriesNodes: allSeries)

        let legendNode = chart.child("legend")
        legend = legendNode.map { l in
            switch l.child("legendPos")?.attr("val") {
            case "l": .left
            case "t": .top
            case "b": .bottom
            default: .right
            }
        }
        legendStyle = base.applying(txPr: legendNode?.child("txPr"), env: env)

        // Axes: those of the first group (its c:axId), else the first of each kind.
        let axIds = Set(first.children("axId").compactMap { $0.attr("val") })
        func axis(_ names: [String]) -> OOXMLNode? {
            let all = plot.children.filter { names.contains($0.name) }
            return all.first { ($0.child("axId")?.attr("val")).map(axIds.contains) ?? false } ?? all.first
        }
        let catAx = family == "pie" ? nil : axis(["catAx", "dateAx"])
        let valAx = family == "pie" ? nil : axis(["valAx"])
        func shown(_ ax: OOXMLNode?) -> Bool {
            guard let ax else { return false }
            return !Self.bool(ax.child("delete"), default: true) && ax.child("tickLblPos")?.attr("val") != "none"
        }
        showCategoryLabels = shown(catAx)
        showValueLabels = shown(valAx)
        gridlines = valAx?.child("majorGridlines") != nil
        categoryStyle = base.applying(txPr: catAx?.child("txPr"), env: env)
        valueStyle = base.applying(txPr: valAx?.child("txPr"), env: env)
        let scaling = valAx?.child("scaling")
        valueMin = TextEnvironment.number(scaling?.child("min")?.attr("val")).flatMap { abs($0) <= Self.maxValue ? $0 : nil }
        valueMax = TextEnvironment.number(scaling?.child("max")?.attr("val")).flatMap { abs($0) <= Self.maxValue ? $0 : nil }

        accents = (0..<6).map { Self.accent($0, colors: colors) }
        background = Self.solid(cs.child("spPr"), colors: colors)
        plotBackground = Self.solid(plot.child("spPr"), colors: colors)
    }

    /// `<x val="…"/>` as a flag; a missing val attribute → `default` (the schema default of most chart flags).
    static func bool(_ n: OOXMLNode?, default d: Bool) -> Bool {
        guard let v = n?.attr("val") else { return d }
        return v == "1" || v == "true"
    }

    static func solid(_ spPr: OOXMLNode?, colors: ColorContext) -> RGBA? {
        spPr?.child("solidFill").flatMap { ColorResolver.resolve($0, in: colors) }
    }

    static func accent(_ i: Int, colors: ColorContext) -> RGBA {
        let name = "accent\(((i % 6) + 6) % 6 + 1)"
        return ColorResolver.resolve(OOXMLNode(name: "solidFill", children: [OOXMLNode(name: "schemeClr", attributes: ["val": name])]),
                                     in: colors) ?? RGBA(r: 0.3, g: 0.45, b: 0.75)
    }

    private static func series(_ s: OOXMLNode, index: Int, line: Bool, colors: ColorContext) -> ChartSeries {
        let idx = s.child("idx")?.attr("val").flatMap { Int($0) }.map { max($0, 0) } ?? index
        let spPr = s.child("spPr")
        let ln = spPr?.child("ln")
        let own = line ? (solid(ln, colors: colors) ?? solid(spPr, colors: colors)) : solid(spPr, colors: colors)
        let width = TextEnvironment.points(ln?.attr("w")).map { min(max($0, 0.25), 20) } ?? 2.25
        var points: [Int: RGBA] = [:]
        for d in s.children("dPt") {
            guard let i = d.child("idx")?.attr("val").flatMap({ Int($0) }), i >= 0, i < maxPoints,
                  let c = solid(d.child("spPr"), colors: colors) else { continue }
            points[i] = c
        }
        let values = s.child("val").flatMap { cache($0) }?.map { v -> Double? in
            guard let v, let d = Double(v.trimmingCharacters(in: .whitespaces)), d.isFinite, abs(d) <= maxValue else { return nil }
            return d
        } ?? []
        return ChartSeries(name: name(s.child("tx")) ?? "Series\(index + 1)", values: values,
                           color: own ?? accent(idx, colors: colors), lineWidth: width, pointColors: points)
    }

    /// `c:tx`: a string reference's first cached point or a literal `c:v`.
    static func name(_ tx: OOXMLNode?) -> String? {
        if let v = tx?.child("v")?.text, !v.isEmpty { return v }
        guard let ref = tx?.child("strRef"), let pts = ref.child("strCache").flatMap(points), let first = pts.first ?? nil,
              !first.isEmpty else { return nil }
        return first
    }

    /// Category labels of `c:cat` (string or number reference or literal).
    static func labels(_ cat: OOXMLNode) -> [String?]? {
        cache(cat)
    }

    /// The cached point texts of a `c:cat`/`c:val` (strRef, numRef, strLit, numLit), indexed by `c:pt idx`.
    static func cache(_ holder: OOXMLNode) -> [String?]? {
        for c in holder.children {
            switch c.name {
            case "strRef": if let p = c.child("strCache").flatMap(points) { return p }
            case "numRef": if let p = c.child("numCache").flatMap(points) { return p }
            case "strLit", "numLit": if let p = points(c) { return p }
            default: continue
            }
        }
        return nil
    }

    /// `c:pt` texts by idx: count = min(ptCount, highest idx + 1, maxPoints).
    static func points(_ cache: OOXMLNode) -> [String?]? {
        let pts = cache.children("pt").compactMap { pt -> (Int, String)? in
            guard let i = pt.attr("idx").flatMap({ Int($0) }), i >= 0, i < maxPoints else { return nil }
            return (i, pt.child("v")?.text ?? "")
        }
        let declared = TextEnvironment.number(cache.child("ptCount")?.attr("val")).map { min(max($0, 0), Double(maxPoints)) }
        let highest = (pts.map(\.0).max() ?? -1) + 1
        let count = min(declared.map { Int($0) } ?? highest, highest)
        guard count > 0 else { return [] }
        var out = [String?](repeating: nil, count: count)
        for (i, v) in pts where i < count { out[i] = v }
        return out
    }

    /// Title paragraphs: `c:title` rich text (or a string reference); a `c:title` without text, or none with
    /// `autoTitleDeleted` = 0, shows the series name when there is exactly one series.
    private static func title(_ t: OOXMLNode?, chart: OOXMLNode, series: [ChartSeries], seriesNodes: [OOXMLNode]) -> [String] {
        if let tx = t?.child("tx") {
            if let rich = tx.child("rich") {
                let paras = rich.children("p").map { p in
                    p.children.map { c in
                        switch c.name {
                        case "r", "fld": c.child("t")?.text ?? ""
                        case "br": " "
                        default: ""
                        }
                    }.joined()
                }
                return paras.contains { !$0.isEmpty } ? paras : []
            }
            return name(tx).map { [$0] } ?? []
        }
        let auto = t != nil || chart.child("autoTitleDeleted").map { !bool($0, default: true) } ?? false
        guard auto, series.count == 1, let n = seriesNodes.first.flatMap({ name($0.child("tx")) }) else { return [] }
        return [n]
    }
}
