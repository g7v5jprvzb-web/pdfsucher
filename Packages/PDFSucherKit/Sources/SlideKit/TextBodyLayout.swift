// TextBodyLayout.swift — Task 10 (SlideKit)
// Text bodies: builds OOXMLKit paragraphs from `p:txBody` (runs, breaks, fields, auto-numbering) with the
// style cascade of TextStyles.swift, sets them with ParagraphSetter into the shape's text box (insets, anchor,
// wrap, vertical text, rotation, autofit scale, columns) and draws them through DrawingRenderer's text pass.
//
// Laid-out text is cached per slide in `DeckStore.textLayout(_:)` (immutable, Sendable, deterministic) and is
// the source of word rects for Task 11: `ShapeTextLayout.slideWordRects()` gives every word's box in slide
// points (axis-aligned bounding box after rotation), with its paragraph and UTF-16 range in that paragraph's
// `SetParagraph.plainText`.
//
// Coordinates: "text space" is the text box after insets, origin top-left, y down, before vertical-text and
// `bodyPr rot` rotation; `toShape` maps it into the (unscaled) shape space, `toSlide` into slide points.
//
// Groups that scale their children (chExt ≠ ext) scale the shape boxes but not the text (PowerPoint): the
// shape's offset and extent are scaled into an "effective" shape, the text is laid out in that, and the group
// chain's scale is taken out of the transform (rotation/mirroring/translation stay). The text callback's
// context is in scaled shape space, so `draw` maps back with `toCallback`. Text is never clipped (PowerPoint does not clip): overflow runs past the box,
// a bottom anchor overflows upwards.
import CoreGraphics
import Foundation
import OOXMLKit

/// Lines `lines` of paragraph `paragraph`, placed with the top of their first line at `origin` (text space;
/// x = the paragraph's left edge).
struct TextPiece: Sendable, Equatable {
    let paragraph: Int
    let lines: Range<Int>
    let origin: CGPoint
    /// Text column (0 without columns).
    var column = 0

    init(paragraph: Int, lines: Range<Int>, origin: CGPoint, column: Int = 0) {
        self.paragraph = paragraph
        self.lines = lines
        self.origin = origin
        self.column = column
    }
}

/// A word box in slide points.
struct SlideWordRect: Sendable, Equatable {
    /// Index into `ShapeTextLayout.sets` / `paragraphs`.
    let paragraph: Int
    /// UTF-16 range in `sets[paragraph].plainText`.
    let range: NSRange
    /// Axis-aligned bounding box in slide points (origin top-left).
    let rect: CGRect
}

/// The laid-out text of one shape.
struct ShapeTextLayout: Sendable {
    /// `ShapeModel.tag` (index into `SlideModel.texts`).
    let tag: Int
    let layer: SlideLayer.Kind
    let placeholder: Placeholder?
    /// Styled input paragraphs and their set form (same indices).
    let paragraphs: [Paragraph]
    let sets: [SetParagraph]
    /// Where the lines go (one piece per paragraph, more with columns).
    let pieces: [TextPiece]
    /// Text box size in text space (after insets; width and height swapped for vertical text).
    let boxSize: CGSize
    /// Text space → effective shape space (shape size after group scaling, origin at its top-left).
    let toShape: CGAffineTransform
    /// Text space → the space of DrawingRenderer's text callback (equals `toShape` outside scaling groups).
    let toCallback: CGAffineTransform
    /// Text space → slide points (group transforms, shape rotation, the text mirror correction included).
    let toSlide: CGAffineTransform
    let fontScale: Double
    let lineSpaceReduction: Double
    /// Picture bullet fills by paragraph index.
    let pictureBullets: [Int: Fill]

    /// True when no paragraph has any text.
    var isEmpty: Bool { sets.allSatisfy { $0.plainText.isEmpty } }

    /// Draws into a context whose CTM is the shape space of the text callback (y down).
    func draw(in ctx: CGContext, renderer: DrawingRenderer, fonts: FontResolver) {
        ctx.saveGState()
        ctx.concatenate(toCallback)
        for piece in pieces {
            let set = sets[piece.paragraph]
            guard set.lines.indices.contains(piece.lines.lowerBound) else { continue }
            set.draw(lines: piece.lines, in: ctx, at: piece.origin, fonts: fonts)
            if piece.lines.lowerBound == 0, let fill = pictureBullets[piece.paragraph], let b = set.bullet {
                let dy = piece.origin.y - set.lines[0].top
                let r = b.rect.offsetBy(dx: piece.origin.x, dy: dy)
                renderer.drawShape(ShapeModel(transform: Transform2D(offset: r.origin, extent: r.size), fill: fill), in: ctx)
            }
        }
        ctx.restoreGState()
    }

    /// Every word's box in slide points, in paragraph and line order.
    func slideWordRects() -> [SlideWordRect] {
        var out: [SlideWordRect] = []
        for piece in pieces {
            let set = sets[piece.paragraph]
            guard set.lines.indices.contains(piece.lines.lowerBound) else { continue }
            let dy = piece.origin.y - set.lines[piece.lines.lowerBound].top
            for w in set.wordRects(lines: piece.lines) {
                let r = w.rect.offsetBy(dx: piece.origin.x, dy: dy).applying(toSlide)
                out.append(SlideWordRect(paragraph: piece.paragraph, range: w.range, rect: r))
            }
        }
        return out
    }
}

/// The laid-out text of all drawn shapes of one slide, in draw order (master, layout, slide; groups depth-first).
struct SlideTextLayout: Sendable {
    let shapes: [ShapeTextLayout]
    /// Laid-out tables by `TableModel.id`.
    let tables: [Int: TableLayout]
    /// Laid-out charts by `ChartModel.id` (ChartRenderer.swift).
    let charts: [Int: ChartLayout]
    private let byTag: [Int: Int]

    init(shapes: [ShapeTextLayout], tables: [Int: TableLayout] = [:], charts: [Int: ChartLayout] = [:]) {
        self.shapes = shapes
        self.tables = tables
        self.charts = charts
        var m: [Int: Int] = [:]
        for (i, s) in shapes.enumerated() { m[s.tag] = i }
        byTag = m
    }

    static let empty = SlideTextLayout(shapes: [])

    func shape(tag: Int) -> ShapeTextLayout? { byTag[tag].map { shapes[$0] } }
}

// MARK: - Building

enum TextBodyLayout {
    /// PowerPoint's single line height: 1.2 × the font size.
    static let lineHeightBase = LineHeightBase.fontSize(factor: 1.2)
    /// Width used for `wrap="none"` measuring.
    static let unbounded: CGFloat = 100_000

    static func build(model: SlideModel, slideNumber: Int, store: DeckStore) -> SlideTextLayout {
        var builder = Builder(model: model, slideNumber: slideNumber, store: store,
                              setter: ParagraphSetter(fonts: store.fonts, lineHeightBase: lineHeightBase,
                                                      lineBreakSetsLineHeight: false, fontMetricsGrowLines: false),
                              defaultTextStyle: store.defaultTextStyle())
        builder.walk(model.elements, toSlide: .identity, mirrored: false)
        return SlideTextLayout(shapes: builder.out, tables: builder.tables, charts: builder.charts)
    }

    /// True when the body has no visible text: no run or field with text (a slide number field always has).
    static func isEmptyText(_ txBody: OOXMLNode?) -> Bool {
        guard let txBody else { return true }
        for p in txBody.children("p") {
            for c in p.children where c.name == "r" || c.name == "fld" {
                if c.name == "fld" && c.attr("type") == "slidenum" { return false }
                if !(c.child("t")?.text.isEmpty ?? true) { return false }
            }
        }
        return true
    }

    /// `Transform2D.textAffine` (internal to OOXMLKit): like `affine` without flips; flipV turns by 180°.
    static func textAffine(_ t: Transform2D) -> CGAffineTransform {
        var u = t
        u.flipH = false
        u.flipV = false
        if t.flipV { u.rotation += 180 }
        return u.affine
    }

    /// Lays out the text of one slide (shapes here, tables in TableRenderer.swift).
    struct Builder {
        let model: SlideModel
        let slideNumber: Int
        let store: DeckStore
        let setter: ParagraphSetter
        let defaultTextStyle: OOXMLNode?
        var out: [ShapeTextLayout] = []
        var tables: [Int: TableLayout] = [:]
        var charts: [Int: ChartLayout] = [:]

        init(model: SlideModel, slideNumber: Int, store: DeckStore, setter: ParagraphSetter, defaultTextStyle: OOXMLNode?) {
            self.model = model
            self.slideNumber = slideNumber
            self.store = store
            self.setter = setter
            self.defaultTextStyle = defaultTextStyle
        }

        /// Same traversal as SlideRenderer: group child space and mirror parity.
        mutating func walk(_ elements: [SlideElement], toSlide m: CGAffineTransform, mirrored: Bool) {
            for e in elements {
                switch e {
                case .shape(let s):
                    guard let tag = s.tag, model.texts.indices.contains(tag) else { continue }
                    if let l = shape(s, tag: tag, parentToSlide: m, mirrored: mirrored) { out.append(l) }
                case .group(let g, let children):
                    let c = g.transform.childToParent
                    guard [c.a, c.b, c.c, c.d, c.tx, c.ty].allSatisfy(\.isFinite) else { continue }
                    walk(children, toSlide: c.concatenating(m), mirrored: mirrored != (g.transform.flipH != g.transform.flipV))
                case .graphicFrame(let f):
                    if let t = f.table { tables[t.id] = table(t, parentToSlide: m) }
                    if let c = f.chart {
                        charts[c.id] = ChartRenderer.layout(c, transform: f.transform, parentToSlide: m, setter: setter)
                    }
                case .picture:
                    continue
                }
            }
        }

        private func shape(_ s: ShapeModel, tag: Int, parentToSlide: CGAffineTransform, mirrored: Bool) -> ShapeTextLayout? {
            let source = model.texts[tag]
            guard let txBody = source.txBody else { return nil }
            let t0 = s.transform
            guard [t0.offset.x, t0.offset.y, t0.extent.width, t0.extent.height, CGFloat(t0.rotation)].allSatisfy(\.isFinite)
            else { return nil }
            // Split the group chain M into scale S (applied to the shape box) and the rest R: M = S · R. SlideRenderer
            // draws the shape the same way (scaled box under R).
            guard let split = GroupScale(parentToSlide) else { return nil }
            let rest = split.rest
            let t = split.scaled(t0)
            var effective = s
            effective.transform = t

            let body = BodyProps(([txBody] + source.inheritedTxBodies).compactMap { $0.child("bodyPr") })
            let env = TextEnvironment(colors: model.colors, fontRef: source.style?.child("fontRef"))
            // Base: master txStyles for placeholders, defaultTextStyle for everything else; then the fontRef.
            var sources: [OOXMLNode?]
            if let ph = source.placeholder {
                sources = [model.master?.root.child("txStyles")?.child(TextStyleCascade.masterStyleName(placeholderType: ph.type))]
            } else {
                sources = [defaultTextStyle]
            }
            sources.append(TextStyleCascade.fontRefSource(source.style?.child("fontRef")))
            if source.placeholder != nil {
                sources += source.inheritedTxBodies.reversed().map { $0.child("lstStyle") }
            }
            sources.append(txBody.child("lstStyle"))
            let built = paragraphs(txBody, cascade: TextStyleCascade(sources: sources), env: env, part: source.part)

            // Text box: the geometry's text rect minus the insets.
            let textRect = effective.textRect
            let inner = CGRect(x: textRect.minX + body.insets.left, y: textRect.minY + body.insets.top,
                               width: max(textRect.width - body.insets.left - body.insets.right, 0),
                               height: max(textRect.height - body.insets.top - body.insets.bottom, 0))
            let box = body.vertical ? CGSize(width: inner.height, height: inner.width) : inner.size
            let toShape = CGAffineTransform(translationX: -box.width / 2, y: -box.height / 2)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(body.rotation * .pi / 180)))
                .concatenating(CGAffineTransform(translationX: inner.midX, y: inner.midY))
            func mirror(_ r: CGRect) -> CGAffineTransform {
                mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * r.midX, ty: 0) : .identity
            }
            let toSlide = toShape.concatenating(mirror(textRect)).concatenating(TextBodyLayout.textAffine(t)).concatenating(rest)
            // The callback space as DrawingRenderer sets it up for the scaled shape under R (see SlideRenderer).
            let callbackToSlide = mirror(textRect).concatenating(TextBodyLayout.textAffine(t)).concatenating(rest)
            let toCallback = abs(callbackToSlide.a * callbackToSlide.d - callbackToSlide.b * callbackToSlide.c) > 1e-12
                ? toSlide.concatenating(callbackToSlide.inverted()) : toShape

            let (sets, pieces, _) = place(built.paragraphs, numbers: built.numbers, body: body, box: box)
            return ShapeTextLayout(tag: tag, layer: source.layer, placeholder: source.placeholder,
                                   paragraphs: built.paragraphs, sets: sets, pieces: pieces, boxSize: box,
                                   toShape: toShape, toCallback: toCallback, toSlide: toSlide, fontScale: body.fontScale,
                                   lineSpaceReduction: body.lineSpaceReduction, pictureBullets: built.pictures)
        }

        // MARK: paragraphs

        func paragraphs(_ txBody: OOXMLNode, cascade: TextStyleCascade, env: TextEnvironment,
                                part: PartContext) -> (paragraphs: [Paragraph], numbers: [Int?], pictures: [Int: Fill]) {
            var paras: [Paragraph] = []
            var numbers: [Int?] = []
            var pictures: [Int: Fill] = [:]
            var counter = AutoNumberCounter()
            for p in txBody.children("p") {
                let pPr = p.child("pPr")
                let level = TextStyleCascade.clamp(pPr?.attr("lvl").flatMap { Int($0) } ?? 0)
                var props = cascade.level(level)
                props.apply(pPr: pPr)
                var runs: [Run] = []
                for c in p.children {
                    switch c.name {
                    case "r":
                        var rp = props
                        rp.apply(rPr: c.child("rPr"))
                        runs.append(textRun(c.child("t")?.text ?? "", props: rp, env: env))
                    case "fld":
                        var rp = props
                        rp.apply(rPr: c.child("rPr"))
                        // slidenum: PowerPoint's number (hidden slides before it count); stored text (also "<#>"
                        // or "‹#›") is never shown. datetime* and other fields: the stored text.
                        let text = c.attr("type") == "slidenum" ? String(slideNumber) : c.child("t")?.text ?? ""
                        runs.append(textRun(text, props: rp, env: env))
                    case "br":
                        var rp = props
                        rp.apply(rPr: c.child("rPr"))
                        runs.append(Run(content: .lineBreak, style: env.runStyle(rp)))
                    default:
                        continue
                    }
                }
                var ep = props
                ep.apply(rPr: p.child("endParaRPr"))
                let endStyle = env.runStyle(ep)
                let first = runs.first { if case .text(let s) = $0.content { !s.isEmpty } else { false } }?.style ?? endStyle
                let style = env.paragraphStyle(props, firstRun: first, part: part)
                let hasText = runs.contains { if case .text(let s) = $0.content { !s.isEmpty } else { false } }
                numbers.append(counter.next(level: level, bullet: style.bullet, hasText: hasText))
                if case .picture = style.bullet, let blip = props.pChildren["bu"]?.child("blip") {
                    pictures[paras.count] = FillResolver.fill(element: OOXMLNode(name: "blipFill", children: [blip]),
                                                              colors: env.colors, part: part)
                }
                paras.append(Paragraph(runs: runs, style: style, endRunStyle: endStyle))
            }
            return (paras, numbers, pictures)
        }

        /// A text run; symbol fonts (latin Wingdings/Symbol, or `a:sym` for private-use characters) are mapped
        /// to Unicode through `FontResolver.mapSymbolText`.
        private func textRun(_ text: String, props: LevelProps, env: TextEnvironment) -> Run {
            var style = env.runStyle(props)
            var text = text
            if let tf = style.typeface {
                let mapped = FontResolver.mapSymbolText(text, typeface: tf)
                if mapped.text != text {
                    text = mapped.text
                    style.typeface = env.defaultTypeface
                }
            }
            if let sym = env.typeface(props.rChildren["sym"]?.attr("typeface")),
               text.unicodeScalars.contains(where: { (0xF020...0xF0FF).contains($0.value) }) {
                text = String(String.UnicodeScalarView(text.unicodeScalars.flatMap { s -> [Unicode.Scalar] in
                    guard (0xF020...0xF0FF).contains(s.value) else { return [s] }
                    return Array(FontResolver.mapSymbolText(String(s), typeface: sym).text.unicodeScalars)
                }))
            }
            return Run(content: .text(text), style: style)
        }

        // MARK: placement

        /// Sets the paragraphs and places their lines in the box: columns, wrap none, anchor, anchorCtr. `height`:
        /// the text's height (the tallest column).
        func place(_ paras: [Paragraph], numbers: [Int?], body: BodyProps,
                   box: CGSize) -> (sets: [SetParagraph], pieces: [TextPiece], height: CGFloat) {
            let cols = max(body.columns, 1)
            let colWidth = cols > 1 ? max((box.width - CGFloat(cols - 1) * body.columnSpacing) / CGFloat(cols), 0) : box.width
            var sets: [SetParagraph] = []
            var xShift: [CGFloat] = []
            for (i, p) in paras.enumerated() {
                let (set, dx) = setParagraph(p, number: numbers[i], body: body, width: colWidth)
                sets.append(set)
                xShift.append(dx)
            }

            // Stack: spaceAfter(previous) + spaceBefore(next); the first paragraph's spaceBefore is ignored. With
            // columns, a line that would cross the bottom of a non-empty column moves to the next one.
            func columnX(_ c: Int) -> CGFloat { CGFloat(c) * (colWidth + body.columnSpacing) }
            var pieces: [TextPiece] = []
            var column = 0
            var y: CGFloat = 0
            var columnBottom: [CGFloat] = [0]
            for (i, set) in sets.enumerated() {
                if i > 0 { y += sets[i - 1].spaceAfter + set.spaceBefore }
                var start = 0
                var top = y
                if cols > 1 {
                    for (k, line) in set.lines.enumerated() {
                        if column < cols - 1, y > 0, y + line.height > box.height {
                            if k > start {
                                pieces.append(TextPiece(paragraph: i, lines: start..<k,
                                                        origin: CGPoint(x: columnX(column) + xShift[i], y: top),
                                                        column: column))
                            }
                            columnBottom[column] = y
                            column += 1
                            columnBottom.append(0)
                            top = 0
                            start = k
                            y = 0
                        }
                        y += line.height
                    }
                } else {
                    y += set.height
                }
                if start < set.lines.count {
                    pieces.append(TextPiece(paragraph: i, lines: start..<set.lines.count,
                                            origin: CGPoint(x: columnX(column) + xShift[i], y: top), column: column))
                }
                columnBottom[column] = y
            }

            // PowerPoint (measured, docs/decisions.md): the body's first baseline sits at
            // max(0.75 × line height, single − descent) below the top instead of height − descent. This only differs
            // above single spacing (lnSpc > ~105 %, exact above the single height); everything below moves up with
            // it and the block is that much shorter.
            if let first = sets.first?.lines.first, let para = paras.first {
                let lift = max(first.height - first.descent
                               - max(0.75 * first.height, singleHeight(para, body: body) - first.descent), 0)
                if lift > 0 {
                    for k in pieces.indices where pieces[k].column == 0 {
                        pieces[k] = TextPiece(paragraph: pieces[k].paragraph, lines: pieces[k].lines,
                                              origin: CGPoint(x: pieces[k].origin.x, y: pieces[k].origin.y - lift))
                    }
                    columnBottom[0] -= lift
                }
            }

            let height = columnBottom.max() ?? 0
            let dy: CGFloat = switch body.anchor {
            case .top: 0
            case .center: (box.height - height) / 2
            case .bottom: box.height - height
            }
            var dx: CGFloat = 0
            if body.anchorCenter, cols == 1 {
                var lo = CGFloat.infinity, hi = -CGFloat.infinity
                for p in pieces {
                    for l in sets[p.paragraph].lines[p.lines] where l.width > 0 {
                        lo = min(lo, p.origin.x + l.origin.x)
                        hi = max(hi, p.origin.x + l.origin.x + l.width)
                    }
                    if let b = sets[p.paragraph].bullet, p.lines.lowerBound == 0 { lo = min(lo, p.origin.x + b.rect.minX) }
                }
                if lo.isFinite, hi.isFinite { dx = box.width / 2 - (lo + hi) / 2 }
            }
            let placed = pieces.map { TextPiece(paragraph: $0.paragraph, lines: $0.lines,
                                                origin: CGPoint(x: $0.origin.x + dx, y: $0.origin.y + dy), column: $0.column) }
            return (sets, placed, height)
        }

        /// Single line height of `p`'s first line: the line-height factor × the size of the first run with text
        /// (the paragraph mark's size when there is none, as the setter does) × the autofit font scale.
        private func singleHeight(_ p: Paragraph, body: BodyProps) -> CGFloat {
            let factor: CGFloat = switch TextBodyLayout.lineHeightBase {
            case .fontSize(let f): f.isFinite && f > 0 ? f : 1.2
            case .fontMetrics: 1.2
            }
            let first = p.runs.first { if case .text(let t) = $0.content { !t.isEmpty } else { false } }
            let size = (first?.style ?? p.endRunStyle).size
            let scale = body.fontScale.isFinite && body.fontScale > 0 ? CGFloat(body.fontScale) : 1
            return size.isFinite && size > 0 ? factor * size * scale : 0
        }

        /// One paragraph at `width`; `wrap="none"`: measured unbounded, then aligned within the box (the returned
        /// x shift places the paragraph).
        private func setParagraph(_ p: Paragraph, number: Int?, body: BodyProps, width: CGFloat) -> (SetParagraph, CGFloat) {
            func set(_ p: Paragraph, _ w: CGFloat) -> SetParagraph {
                setter.set(p, width: w, fontScale: body.fontScale, lineSpaceReduction: body.lineSpaceReduction,
                           autoNumber: number)
            }
            guard !body.wrap else { return (set(p, width), 0) }
            var left = p
            left.style.align = .left
            let measured = set(left, TextBodyLayout.unbounded)
            switch p.style.align {
            case .left, .justify, .distributed:
                return (measured, 0)
            case .center, .right:
                let natural = (measured.lines.map { $0.origin.x + $0.width }.max() ?? 0) + p.style.marginRight + 1
                let shift = p.style.align == .center ? (width - natural) / 2 : width - natural
                return (set(p, natural), shift)
            }
        }
    }
}

/// Auto-numbering of one text body (docs/decisions.md): a counter per level. A numbered paragraph continues
/// its level's count when the scheme and startAt match the previous numbered paragraph of that level, else it
/// starts at startAt. A non-numbered paragraph with text ends its level's list; any paragraph with text ends the
/// lists of deeper levels. Empty paragraphs show no number and change nothing.
struct AutoNumberCounter {
    private var levels: [Int: (scheme: String, startAt: Int, next: Int)] = [:]

    mutating func next(level: Int, bullet: Bullet?, hasText: Bool) -> Int? {
        guard hasText else { return nil }
        for l in levels.keys where l > level { levels[l] = nil }
        guard case .autoNumber(let scheme, let startAt, _, _, _) = bullet else {
            levels[level] = nil
            return nil
        }
        var n = startAt
        if let c = levels[level], c.scheme == scheme, c.startAt == startAt { n = c.next }
        levels[level] = (scheme, startAt, n < Int.max ? n + 1 : n)
        return n
    }
}
