// ChartRenderer.swift — Task 12b (SlideKit)
// Lays out and draws a `ChartModel` in its frame ("simple" charts, spec §6): title on top, legend at its side,
// value axis with nice-number ticks (labels, gridlines), category labels, then bars (clustered, stacked, percent
// stacked; vertical or horizontal), lines (gaps at missing points) or pie/doughnut wedges.
//
// The layout is computed once per slide with the text (`SlideTextLayout.charts`, built by TextBodyLayout's walk)
// so drawing and slideText use the same set paragraphs. Chart space: the frame's extent, origin top left; it maps
// into the frame's parent like shape text (rotation, no flips). Searchable text (slideText, wordBoxes): the title,
// the category labels and the legend entries, in that order; value-axis numbers are drawn only.
import CoreGraphics
import Foundation
import OOXMLKit

struct ChartLayout: Sendable {
    struct Text: Sendable {
        let set: SetParagraph
        /// Top left of the paragraph in chart space.
        let origin: CGPoint
        let searchable: Bool
    }

    enum Mark: Sendable {
        case rect(CGRect, RGBA)
        case polygon([CGPoint], RGBA)
        case polyline([CGPoint], RGBA, width: CGFloat)
    }

    let marks: [Mark]
    /// Searchable texts first (title, categories, legend), then the value labels.
    let texts: [Text]
    /// Chart space → the frame's parent space (the space the renderer draws the frame in).
    let toParent: CGAffineTransform
    /// Chart space → slide points.
    let toSlide: CGAffineTransform

    /// Draws into a context whose CTM is the frame's parent space (y down).
    func draw(in ctx: CGContext, fonts: FontResolver) {
        ctx.saveGState()
        ctx.concatenate(toParent)
        for m in marks {
            switch m {
            case .rect(let r, let c):
                ctx.setFillColor(Self.cgColor(c))
                ctx.fill(r)
            case .polygon(let pts, let c):
                guard pts.count > 2 else { continue }
                ctx.setFillColor(Self.cgColor(c))
                ctx.beginPath()
                ctx.addLines(between: pts)
                ctx.closePath()
                ctx.fillPath()
            case .polyline(let pts, let c, let w):
                guard pts.count > 1 else { continue }
                ctx.setStrokeColor(Self.cgColor(c))
                ctx.setLineWidth(w)
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.beginPath()
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
        }
        for t in texts {
            t.set.draw(lines: 0..<t.set.lines.count, in: ctx, at: t.origin, fonts: fonts)
        }
        ctx.restoreGState()
    }

    /// Searchable paragraphs and their word boxes (slide points; `paragraph` indexes `searchableTexts`).
    var searchableTexts: [Text] { texts.filter(\.searchable) }

    func slideWordRects() -> [SlideWordRect] {
        var out: [SlideWordRect] = []
        for (i, t) in searchableTexts.enumerated() {
            let dy = t.origin.y - (t.set.lines.first?.top ?? 0)
            for w in t.set.wordRects(lines: 0..<t.set.lines.count) {
                out.append(SlideWordRect(paragraph: i, range: w.range,
                                         rect: w.rect.offsetBy(dx: t.origin.x, dy: dy).applying(toSlide)))
            }
        }
        return out
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}

enum ChartRenderer {
    static let gridColor = RGBA(r: 0xD9 / 255.0, g: 0xD9 / 255.0, b: 0xD9 / 255.0)
    static let axisColor = RGBA(r: 0xBF / 255.0, g: 0xBF / 255.0, b: 0xBF / 255.0)
    /// Category labels drawn at most (every k-th beyond that).
    static let maxCategoryLabels = 100
    static let gap: CGFloat = 4

    /// nil for a degenerate frame (empty or not finite).
    static func layout(_ m: ChartModel, transform: Transform2D, parentToSlide: CGAffineTransform,
                       setter: ParagraphSetter) -> ChartLayout? {
        let w = transform.extent.width, h = transform.extent.height
        guard w.isFinite, h.isFinite, w > 0, h > 0,
              [transform.offset.x, transform.offset.y, CGFloat(transform.rotation)].allSatisfy(\.isFinite) else { return nil }
        let toParent = TextBodyLayout.textAffine(transform)
        var b = Builder(model: m, setter: setter, size: CGSize(width: w, height: h))
        b.build()
        return ChartLayout(marks: b.marks, texts: b.title + b.categoryTexts + b.legendTexts + b.valueTexts,
                           toParent: toParent, toSlide: toParent.concatenating(parentToSlide))
    }

    /// Nice-number ticks covering lo…hi (fixed ends are kept as given); nil if the range is unusable.
    static func ticks(lo: Double, hi: Double, fixedLo: Bool, fixedHi: Bool) -> (lo: Double, hi: Double, ticks: [Double])? {
        let span = hi - lo
        guard lo.isFinite, hi.isFinite, span.isFinite, span > 0 else { return nil }
        let raw = span / 5
        let mag = pow(10, floor(log10(raw)))
        let f = raw / mag
        let step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * mag
        guard step.isFinite, step > 0 else { return nil }
        let a = fixedLo ? lo : floor(lo / step) * step
        let b = fixedHi ? hi : ceil(hi / step) * step
        guard a.isFinite, b.isFinite, b > a else { return nil }
        let first = ceil(a / step - 1e-9)
        var out: [Double] = []
        var k = 0.0
        while out.count < 50 {
            let t = (first + k) * step
            if t > b + step * 1e-9 { break }
            out.append(abs(t) < step * 1e-9 ? 0 : t)
            k += 1
        }
        return (a, b, out)
    }

    /// A tick label: as many decimals as the step needs (at most 6), "%" for percent axes.
    static func format(_ v: Double, step: Double, percent: Bool) -> String {
        let decimals = step >= 1 || step <= 0 ? 0 : min(6, Int(ceil(-log10(step) - 1e-9)))
        var s = String(format: "%.\(decimals)f", v)
        if Double(s) == 0 { s = String(format: "%.\(decimals)f", 0.0) }
        return percent ? s + "%" : s
    }

    // MARK: - Builder

    private struct Builder {
        let model: ChartModel
        let setter: ParagraphSetter
        let size: CGSize
        var marks: [ChartLayout.Mark] = []
        var title: [ChartLayout.Text] = []
        var categoryTexts: [ChartLayout.Text] = []
        var legendTexts: [ChartLayout.Text] = []
        var valueTexts: [ChartLayout.Text] = []

        init(model: ChartModel, setter: ParagraphSetter, size: CGSize) {
            self.model = model
            self.setter = setter
            self.size = size
        }

        func text(_ s: String, _ style: ChartTextStyle, width: CGFloat, align: Align = .left) -> SetParagraph {
            let p = Paragraph(runs: [Run(content: .text(s), style: style.run)], style: ParagraphStyle(align: align),
                              endRunStyle: style.run)
            return setter.set(p, width: max(width, 1))
        }

        /// The widest line of `s` set without wrapping.
        func naturalWidth(_ s: String, _ style: ChartTextStyle) -> CGFloat {
            text(s, style, width: TextBodyLayout.unbounded).lines.map { $0.origin.x + $0.width }.max() ?? 0
        }

        mutating func build() {
            let full = CGRect(origin: .zero, size: size)
            if let bg = model.background { marks.append(.rect(full, bg)) }
            let pad = min(max(min(size.width, size.height) * 0.03, 2), 10)
            var area = full.insetBy(dx: pad, dy: pad)
            guard area.width > 0, area.height > 0 else { return }

            var y = area.minY
            for line in model.title where !line.isEmpty {
                let set = text(line, model.titleStyle, width: area.width, align: .center)
                title.append(.init(set: set, origin: CGPoint(x: area.minX, y: y), searchable: true))
                y += set.height
            }
            if !title.isEmpty { area = Self.cut(area, top: y - area.minY + ChartRenderer.gap) }
            if let pos = model.legend { area = legend(pos, in: area) }
            guard area.width > 1, area.height > 1 else { return }

            switch model.kind {
            case .pie(let hole, let angle): pie(in: area, hole: hole, firstSliceAngle: angle)
            case .column, .bar, .line: axes(in: area)
            }
        }

        static func cut(_ r: CGRect, top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0) -> CGRect {
            CGRect(x: r.minX + left, y: r.minY + top, width: max(r.width - left - right, 0), height: max(r.height - top - bottom, 0))
        }

        // MARK: legend

        /// Entries: series (bar/line) or categories (a pie with varied colours).
        var legendEntries: [(String, RGBA)] {
            if case .pie = model.kind, let g = model.groups.first, let s = g.series.first, g.varyColors {
                return model.categories.indices.prefix(ChartRenderer.maxCategoryLabels).map { i in
                    (model.categories[i], s.pointColors[i] ?? model.accents[i % model.accents.count])
                }
            }
            return model.groups.flatMap(\.series).map { ($0.name, $0.color) }
        }

        mutating func legend(_ pos: ChartModel.LegendPosition, in area: CGRect) -> CGRect {
            let style = model.legendStyle
            let entries = legendEntries
            guard !entries.isEmpty else { return area }
            let key = max(style.size * 0.7, 2)
            let isLine = model.kind == .line
            let keyW = isLine ? key * 1.6 : key
            let inner = keyW + 4
            let naturals = entries.map { naturalWidth($0.0, style) + 1 }
            switch pos {
            case .left, .right:
                let lw = min((naturals.max() ?? 0) + inner, area.width * 0.4)
                let sets = entries.map { text($0.0, style, width: lw - inner) }
                let total = sets.reduce(0) { $0 + $1.height }
                var y = area.midY - total / 2
                let x = pos == .right ? area.maxX - lw : area.minX
                for (set, e) in zip(sets, entries) {
                    addEntry(set, color: e.1, at: CGPoint(x: x, y: y), key: key, keyW: keyW, isLine: isLine)
                    y += set.height
                }
                return pos == .right ? Self.cut(area, right: lw + ChartRenderer.gap * 2)
                    : Self.cut(area, left: lw + ChartRenderer.gap * 2)
            case .top, .bottom:
                // Rows of entries, each row centred.
                let spacing: CGFloat = 12
                var rows: [[Int]] = [[]]
                var rowWidth: CGFloat = 0
                for (i, n) in naturals.enumerated() {
                    let ew = inner + n
                    if let last = rows.last, !last.isEmpty, rowWidth + spacing + ew > area.width {
                        rows.append([])
                        rowWidth = 0
                    }
                    rowWidth += (rows[rows.count - 1].isEmpty ? 0 : spacing) + ew
                    rows[rows.count - 1].append(i)
                }
                let sets = entries.enumerated().map { text($0.element.0, style, width: min(naturals[$0.offset], area.width - inner)) }
                let rowH = rows.map { r in r.map { sets[$0].height }.max() ?? 0 }
                let total = rowH.reduce(0, +)
                var y = pos == .bottom ? area.maxY - total : area.minY
                for (r, row) in rows.enumerated() {
                    let width = row.map { inner + min(naturals[$0], area.width - inner) }.reduce(0, +)
                        + spacing * CGFloat(max(row.count - 1, 0))
                    var x = area.midX - width / 2
                    for i in row {
                        addEntry(sets[i], color: entries[i].1, at: CGPoint(x: x, y: y), key: key, keyW: keyW, isLine: isLine)
                        x += inner + min(naturals[i], area.width - inner) + spacing
                    }
                    y += rowH[r]
                }
                return pos == .bottom ? Self.cut(area, bottom: total + ChartRenderer.gap)
                    : Self.cut(area, top: total + ChartRenderer.gap)
            }
        }

        mutating func addEntry(_ set: SetParagraph, color: RGBA, at p: CGPoint, key: CGFloat, keyW: CGFloat, isLine: Bool) {
            let lineH = set.lines.first?.height ?? set.height
            let midY = p.y + lineH / 2
            let keyH = isLine ? max(key * 0.3, 1) : key
            marks.append(.rect(CGRect(x: p.x, y: midY - keyH / 2, width: keyW, height: keyH), color))
            legendTexts.append(.init(set: set, origin: CGPoint(x: p.x + keyW + 4, y: p.y), searchable: true))
        }

        // MARK: pie

        mutating func pie(in area: CGRect, hole: Double, firstSliceAngle: Double) {
            guard let g = model.groups.first, let s = g.series.first else { return }
            let valid = s.values.enumerated().compactMap { (i, v) -> (Int, Double)? in
                guard let v, v > 0 else { return nil }
                return (i, v)
            }
            let total = valid.reduce(0) { $0 + $1.1 }
            guard total > 0, total.isFinite else { return }
            let r = min(area.width, area.height) / 2
            let inner = r * CGFloat(hole)
            let c = CGPoint(x: area.midX, y: area.midY)
            func point(_ deg: Double, _ radius: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: c.x + radius * CGFloat(sin(a)), y: c.y - radius * CGFloat(cos(a)))
            }
            var start = firstSliceAngle
            for (i, v) in valid {
                let sweep = v / total * 360
                let n = min(max(Int((sweep / 2).rounded(.up)), 2), 360)
                var pts: [CGPoint] = []
                for k in 0...n { pts.append(point(start + sweep * Double(k) / Double(n), r)) }
                if inner > 0 {
                    for k in (0...n).reversed() { pts.append(point(start + sweep * Double(k) / Double(n), inner)) }
                } else if sweep < 360 {
                    pts.append(c)
                }
                let color = s.pointColors[i] ?? (g.varyColors ? model.accents[i % model.accents.count] : s.color)
                marks.append(.polygon(pts, color))
                start += sweep
            }
        }

        // MARK: bars and lines

        /// Per group and series: each category's (from, to) in value units (to = the plotted value for lines).
        func stacks() -> [[[(Double, Double)?]]] {
            let n = model.categoryCount
            return model.groups.map { g in
                var pos = [Double](repeating: 0, count: n), neg = [Double](repeating: 0, count: n)
                var totals = [Double](repeating: 0, count: n)
                if g.grouping == .percentStacked {
                    for s in g.series { for (i, v) in s.values.prefix(n).enumerated() { totals[i] += abs(v ?? 0) } }
                }
                return g.series.map { s in
                    (0..<n).map { i -> (Double, Double)? in
                        guard s.values.indices.contains(i), let raw = s.values[i] else { return nil }
                        switch g.grouping {
                        case .clustered:
                            return (0, raw)
                        case .stacked, .percentStacked:
                            var v = raw
                            if g.grouping == .percentStacked {
                                guard totals[i] > 0 else { return nil }
                                v = raw / totals[i] * 100
                            }
                            if v >= 0 { defer { pos[i] += v }; return (pos[i], pos[i] + v) }
                            defer { neg[i] += v }
                            return (neg[i], neg[i] + v)
                        }
                    }
                }
            }
        }

        mutating func axes(in area0: CGRect) {
            let n = model.categoryCount
            guard n > 0 else { return }
            let data = stacks()
            let ends = data.flatMap { $0.flatMap { $0.compactMap { $0 }.flatMap { [$0.0, $0.1] } } }
            let percent = model.groups.contains { $0.grouping == .percentStacked }
            var lo = min(ends.min() ?? 0, 0), hi = max(ends.max() ?? 0, 0)
            if percent { lo = (ends.min() ?? 0) < 0 ? -100 : 0; hi = 100 }
            if let mn = model.valueMin { lo = mn }
            if let mx = model.valueMax { hi = mx }
            var fixedLo = model.valueMin != nil, fixedHi = model.valueMax != nil
            if !(hi > lo) {
                lo = min(ends.min() ?? 0, 0); hi = max(ends.max() ?? 0, 0); fixedLo = false; fixedHi = false
                if !(hi > lo) { hi = lo + 1 }
            }
            guard let scale = ChartRenderer.ticks(lo: lo, hi: hi, fixedLo: fixedLo, fixedHi: fixedHi) else { return }
            let step = scale.ticks.count > 1 ? scale.ticks[1] - scale.ticks[0] : scale.hi - scale.lo
            let tickLabels = model.showValueLabels
                ? scale.ticks.map { ChartRenderer.format($0, step: step, percent: percent) } : []
            let horizontal = model.kind == .bar
            let labelEvery = max(1, (n + ChartRenderer.maxCategoryLabels - 1) / ChartRenderer.maxCategoryLabels)
            let catIndices = model.showCategoryLabels ? Array(stride(from: 0, to: n, by: labelEvery)) : []

            var plot = area0
            if horizontal {
                let catW = catIndices.isEmpty ? 0
                    : min((catIndices.map { naturalWidth(model.categories[$0], model.categoryStyle) }.max() ?? 0) + 6, area0.width * 0.4)
                let valH = tickLabels.isEmpty ? 0 : (text("0", model.valueStyle, width: 100).height + 3)
                plot = Self.cut(area0, bottom: valH, left: catW)
            } else {
                let valW = tickLabels.isEmpty ? 0
                    : min((tickLabels.map { naturalWidth($0, model.valueStyle) }.max() ?? 0) + 6, area0.width * 0.4)
                plot = Self.cut(area0, left: valW)
                let band = plot.width / CGFloat(n)
                let sets = catIndices.map { text(model.categories[$0], model.categoryStyle, width: band * CGFloat(labelEvery), align: .center) }
                let catH = sets.isEmpty ? 0 : (sets.map(\.height).max() ?? 0) + 3
                plot = Self.cut(plot, bottom: catH)
                for (i, set) in zip(catIndices, sets) {
                    let x = plot.minX + band * CGFloat(i) - band * CGFloat(labelEvery - 1) / 2
                    categoryTexts.append(.init(set: set, origin: CGPoint(x: x, y: plot.maxY + 3), searchable: true))
                }
            }
            guard plot.width > 1, plot.height > 1 else { categoryTexts = []; return }
            if let bg = model.plotBackground { marks.append(.rect(plot, bg)) }

            let span = scale.hi - scale.lo
            // Value → coordinate along the value axis (clamped to the axis).
            func v(_ x: Double) -> CGFloat {
                let f = CGFloat((min(max(x, scale.lo), scale.hi) - scale.lo) / span)
                return horizontal ? plot.minX + f * plot.width : plot.maxY - f * plot.height
            }
            let band = (horizontal ? plot.height : plot.width) / CGFloat(n)
            // Start of category i's band along the category axis (bars: first category at the bottom).
            func c(_ i: Int) -> CGFloat {
                horizontal ? plot.maxY - band * CGFloat(i + 1) : plot.minX + band * CGFloat(i)
            }

            // Gridlines and value labels.
            for (k, t) in scale.ticks.enumerated() {
                let p = v(t)
                if model.gridlines {
                    let line = horizontal ? [CGPoint(x: p, y: plot.minY), CGPoint(x: p, y: plot.maxY)]
                        : [CGPoint(x: plot.minX, y: p), CGPoint(x: plot.maxX, y: p)]
                    marks.append(.polyline(line, ChartRenderer.gridColor, width: 0.75))
                }
                guard tickLabels.indices.contains(k) else { continue }
                if horizontal {
                    let nw = naturalWidth(tickLabels[k], model.valueStyle) + 1
                    valueTexts.append(.init(set: text(tickLabels[k], model.valueStyle, width: nw),
                                            origin: CGPoint(x: p - nw / 2, y: plot.maxY + 3), searchable: false))
                } else {
                    let set = text(tickLabels[k], model.valueStyle, width: plot.minX - area0.minX - 4, align: .right)
                    valueTexts.append(.init(set: set, origin: CGPoint(x: area0.minX, y: p - set.height / 2), searchable: false))
                }
            }
            if horizontal {
                for i in catIndices {
                    let set = text(model.categories[i], model.categoryStyle, width: plot.minX - area0.minX - 6, align: .right)
                    categoryTexts.append(.init(set: set, origin: CGPoint(x: area0.minX, y: c(i) + band / 2 - set.height / 2),
                                               searchable: true))
                }
            }

            if model.kind == .line {
                for (g, group) in model.groups.enumerated() {
                    for (s, series) in group.series.enumerated() {
                        var run: [CGPoint] = []
                        for i in 0..<n {
                            guard let seg = data[g][s][i] else {
                                if run.count > 1 { marks.append(.polyline(run, series.color, width: series.lineWidth)) }
                                run = []
                                continue
                            }
                            run.append(CGPoint(x: c(i) + band / 2, y: v(seg.1)))
                        }
                        if run.count > 1 { marks.append(.polyline(run, series.color, width: series.lineWidth)) }
                    }
                }
            } else {
                let groupCount = CGFloat(max(model.groups.count, 1))
                for (g, group) in model.groups.enumerated() {
                    let width = band / (1 + CGFloat(group.gapWidth) / 100)
                    let slot = width / groupCount
                    let clustered = group.grouping == .clustered
                    let barW = clustered ? slot / CGFloat(max(group.series.count, 1)) : slot
                    // One series with varyColors: every bar in its accent (dPt overrides still win).
                    let vary = group.varyColors && group.series.count == 1
                    for (s, series) in group.series.enumerated() {
                        for i in 0..<n {
                            guard let seg = data[g][s][i] else { continue }
                            let start = c(i) + (band - width) / 2 + slot * CGFloat(g) + (clustered ? barW * CGFloat(s) : 0)
                            let a = v(seg.0), b = v(seg.1)
                            let r = horizontal ? CGRect(x: min(a, b), y: start, width: abs(b - a), height: barW)
                                : CGRect(x: start, y: min(a, b), width: barW, height: abs(b - a))
                            let color = series.pointColors[i] ?? (vary ? model.accents[i % model.accents.count] : series.color)
                            marks.append(.rect(r, color))
                        }
                    }
                }
            }
            if model.showCategoryLabels {
                let z = v(0)
                let line = horizontal ? [CGPoint(x: z, y: plot.minY), CGPoint(x: z, y: plot.maxY)]
                    : [CGPoint(x: plot.minX, y: z), CGPoint(x: plot.maxX, y: z)]
                marks.append(.polyline(line, ChartRenderer.axisColor, width: 0.75))
            }
        }
    }
}
