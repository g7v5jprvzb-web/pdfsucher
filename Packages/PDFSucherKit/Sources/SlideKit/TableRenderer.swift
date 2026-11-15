// TableRenderer.swift — Task 12a (SlideKit)
// Tables (`a:tbl` in a `p:graphicFrame`): the model (grid, merged cells, resolved fills, borders and text
// sources, built with the slide model), the layout (row heights grow to fit the cells' laid-out text, built
// with the slide's text layout) and drawing. docs/decisions.md, "Tables".
//
// Geometry: the frame's `p:xfrm` offset places the table; rotation and flips are ignored (PowerPoint does not
// rotate tables) and so is the frame extent: column widths come from `a:tblGrid/a:gridCol w`, row heights
// from `a:tr h` as a minimum, grown so every cell fits its text plus its margins (a cell spanning rows grows
// the last of them). Coordinates are in the frame's parent space (slide points, or a group's child space).
//
// Merges: the k-th `a:tc` of a row sits in grid column k. A cell claims `gridSpan` × `rowSpan` grid slots
// (clamped to the grid; it stops at the first row that is not entirely free, so anchors never overlap);
// `hMerge`/`vMerge` cells inside a claimed area are continuation cells. A continuation cell outside any span
// extends its left (hMerge) or upper (vMerge) neighbour when the neighbour stays a rectangle of free slots
// (old-style merges), else it is dropped. Continuation cells draw nothing and
// have no text; a merged cell draws once over its whole area.
//
// Cell text: the same cascade as a non-placeholder shape — presentation `p:defaultTextStyle` → the table
// style's `a:tcTxStyle` parts (TableStyles.swift) → the cell's `a:lstStyle` → `a:pPr` → `a:rPr`; the box is the
// cell minus `a:tcPr` marL/marR/marT/marB (defaults 91440/91440/45720/45720 EMU), anchored t/ctr/b.
//
// Drawing order: table background, cell fills, cell borders (each cell its own four edges plus diagonals, so a
// shared edge is drawn by both neighbours, the later on top), then the text.
import CoreGraphics
import Foundation
import OOXMLKit

// MARK: - Model

struct CellInsets: Sendable, Equatable {
    var left: CGFloat = 7.2, top: CGFloat = 3.6, right: CGFloat = 7.2, bottom: CGFloat = 3.6
}

struct TableCellModel: Sendable {
    let span: CellSpan
    let txBody: OOXMLNode?
    let margins: CellInsets
    let anchor: BodyProps.Anchor
    let fill: Fill
    /// By `CellEdge.rawValue`.
    let borders: [Line?]
    /// The table style's text sources for this cell, lowest precedence first.
    let textSources: [OOXMLNode]
}

struct TableModel: Sendable {
    /// Key of the table's layout in `SlideTextLayout.tables` (unique per slide model).
    let id: Int
    let origin: CGPoint
    /// Column widths and minimum row heights in points.
    let columns: [CGFloat]
    let rowHeights: [CGFloat]
    /// Anchor cells (continuation cells left out), in row-major order of their top-left slot.
    let cells: [TableCellModel]
    let background: Fill
    let layer: SlideLayer.Kind
    let part: PartContext

    /// Limits against hostile grids (the slot grid is rows × columns).
    static let maxRows = 1000, maxColumns = 1000, maxSlots = 250_000
    /// Largest column width, row height and cell margin in points.
    static let maxLength: CGFloat = 1_000_000

    /// nil when the frame's offset is unusable.
    init?(tbl: OOXMLNode, id: Int, transform: Transform2D, styles: TableStyleList, colors: ColorContext,
          layer: SlideLayer.Kind, part: PartContext) {
        let o = transform.offset
        guard o.x.isFinite, o.y.isFinite, abs(o.x) <= 1e8, abs(o.y) <= 1e8 else { return nil }
        self.id = id
        origin = o
        self.layer = layer
        self.part = part
        columns = Array((tbl.child("tblGrid")?.children("gridCol") ?? []).prefix(Self.maxColumns))
            .map { Self.length($0.attr("w")) ?? 0 }
        let maxRows = min(Self.maxRows, columns.isEmpty ? Self.maxRows : Self.maxSlots / columns.count)
        let trs = Array(tbl.children("tr").prefix(maxRows))
        rowHeights = trs.map { Self.length($0.attr("h")) ?? 0 }

        let tblPr = tbl.child("tblPr")
        let style = styles.style(for: tblPr?.child("tableStyleId")?.text)
        let flags = TableFlags(tblPr: tblPr)
        background = CellStyle.background(tblPr: tblPr, style: style, colors: colors, part: part)
        let spans = Self.anchors(trs, columns: columns.count)
        let rows = trs.count, cols = columns.count
        cells = spans.map { s, tc in
            let st = CellStyle(style: style, flags: flags, span: s, rows: rows, cols: cols, colors: colors)
            return Self.cell(tc, span: s, style: st, colors: colors, part: part)
        }
    }

    /// EMU attribute → points in 0…maxLength; nil when missing or not a finite number.
    static func length(_ s: String?) -> CGFloat? {
        TextEnvironment.points(s).map { min(max($0, 0), maxLength) }
    }

    /// A span attribute (gridSpan/rowSpan) clamped to 1…limit; missing or bad → 1.
    static func span(_ s: String?, limit: Int) -> Int {
        guard let v = TextEnvironment.number(s), v >= 1 else { return 1 }
        return Int(min(v, Double(max(limit, 1))))
    }

    /// The anchor cells with their grid areas (see the file header).
    static func anchors(_ trs: [OOXMLNode], columns cols: Int) -> [(CellSpan, OOXMLNode)] {
        let rows = trs.count
        guard rows > 0, cols > 0 else { return [] }
        var owner = [Int](repeating: -1, count: rows * cols)
        var out: [(CellSpan, OOXMLNode)] = []
        func free(_ r: Int, _ c: Int) -> Bool { owner[r * cols + c] < 0 }
        for (r, tr) in trs.enumerated() {
            for (c, tc) in tr.children("tc").prefix(cols).enumerated() where free(r, c) {
                let h = Transform2D.isTrue(tc.attr("hMerge")), v = Transform2D.isTrue(tc.attr("vMerge"))
                if h || v {
                    // Old-style merge: extend the adjacent neighbour's rectangle when every slot it gains is free
                    // (hMerge: a single-row neighbour gains (r, c); vMerge: a neighbour ending at row r gains its
                    // whole width in row r); otherwise the cell is dropped and its slot stays empty.
                    if h, c > 0, owner[r * cols + c - 1] >= 0 {
                        let o = owner[r * cols + c - 1]
                        if out[o].0.row == r, out[o].0.rowEnd == r + 1, out[o].0.colEnd == c {
                            out[o].0.colEnd = c + 1
                            owner[r * cols + c] = o
                        }
                    } else if v, r > 0, owner[(r - 1) * cols + c] >= 0 {
                        let o = owner[(r - 1) * cols + c]
                        let s = out[o].0
                        if s.col == c, s.rowEnd == r, (s.col..<s.colEnd).allSatisfy({ free(r, $0) }) {
                            for k in s.col..<s.colEnd { owner[r * cols + k] = o }
                            out[o].0.rowEnd = r + 1
                        }
                    }
                    continue
                }
                let colEnd0 = c + span(tc.attr("gridSpan"), limit: cols - c)
                let rowEnd0 = r + span(tc.attr("rowSpan"), limit: rows - r)
                let index = out.count
                // Claim free slots: the first row up to the first claimed slot, then each further row only if
                // all of its slots in c..<colEnd are free (so the cell stays a rectangle of its own slots and
                // never draws over another anchor). Linear in the grid: each row check stops at the first
                // claimed slot, and a row that passes is claimed.
                var colEnd = c
                while colEnd < colEnd0, free(r, colEnd) { owner[r * cols + colEnd] = index; colEnd += 1 }
                var rowEnd = r + 1
                while rowEnd < rowEnd0, (c..<colEnd).allSatisfy({ free(rowEnd, $0) }) {
                    for k in c..<colEnd { owner[rowEnd * cols + k] = index }
                    rowEnd += 1
                }
                out.append((CellSpan(row: r, col: c, rowEnd: rowEnd, colEnd: colEnd), tc))
            }
        }
        return out
    }

    private static func cell(_ tc: OOXMLNode, span: CellSpan, style: CellStyle, colors: ColorContext,
                             part: PartContext) -> TableCellModel {
        let tcPr = tc.child("tcPr")
        let d = CellInsets()
        func margin(_ k: String, _ v: CGFloat) -> CGFloat { length(tcPr?.attr(k)) ?? v }
        let m = CellInsets(left: margin("marL", d.left), top: margin("marT", d.top), right: margin("marR", d.right),
                           bottom: margin("marB", d.bottom))
        let anchor: BodyProps.Anchor = switch tcPr?.attr("anchor") {
        case "ctr": .center
        case "b": .bottom
        default: .top
        }
        let fill = tcPr.flatMap { FillResolver.explicitFill($0, colors: colors, part: part) } ?? style.fill ?? .none
        // The cell's own lnL… override the style when they say something about the fill.
        let own: [CellEdge: String] = [.left: "lnL", .right: "lnR", .top: "lnT", .bottom: "lnB",
                                       .diagonalDown: "lnTlToBr", .diagonalUp: "lnBlToTr"]
        var borders = style.edges.map { $0 ?? nil }
        for (edge, name) in own {
            guard let ln = tcPr?.child(name),
                  ln.children.contains(where: { ["noFill", "solidFill", "gradFill", "pattFill"].contains($0.name) })
            else { continue }
            let spPr = OOXMLNode(name: "spPr", children: [OOXMLNode(name: "ln", attributes: ln.attributes, children: ln.children)])
            borders[edge.rawValue] = CellStyle.border(LineResolver.line(spPr, style: nil, colors: colors))
        }
        return TableCellModel(span: span, txBody: tc.child("txBody"), margins: m, anchor: anchor, fill: fill,
                              borders: borders, textSources: style.textSources)
    }
}

// MARK: - Layout

struct CellLayout: Sendable {
    let span: CellSpan
    /// The cell's area in the frame's parent space.
    let rect: CGRect
    let fill: Fill
    let borders: [Line?]
    /// The cell's text (`tag` −1, never a placeholder); `toSlide` gives its word rects in slide points.
    let text: ShapeTextLayout
}

struct TableLayout: Sendable {
    let id: Int
    /// The table's area in the frame's parent space.
    let bounds: CGRect
    let background: Fill
    /// Anchor cells in row-major order (the order of the table's text).
    let cells: [CellLayout]
}

extension TextBodyLayout.Builder {
    /// Lays out `t`'s cells; `parentToSlide` maps the frame's parent space to slide points.
    func table(_ t: TableModel, parentToSlide: CGAffineTransform) -> TableLayout {
        let env = TextEnvironment(colors: model.colors, fontRef: nil)
        var body = BodyProps([])
        body.insets = (0, 0, 0, 0)
        var xs = [t.origin.x]
        for w in t.columns { xs.append((xs.last ?? 0) + w) }

        struct Cell {
            let built: (paragraphs: [Paragraph], numbers: [Int?], pictures: [Int: Fill])
            let sets: [SetParagraph]
            let pieces: [TextPiece]
            let height: CGFloat
        }
        var cells: [Cell] = []
        for c in t.cells {
            let width = max(xs[c.span.colEnd] - xs[c.span.col] - c.margins.left - c.margins.right, 0)
            guard let txBody = c.txBody else {
                cells.append(Cell(built: ([], [], [:]), sets: [], pieces: [], height: 0))
                continue
            }
            let sources: [OOXMLNode?] = [defaultTextStyle] + c.textSources + [txBody.child("lstStyle")]
            let built = paragraphs(txBody, cascade: TextStyleCascade(sources: sources), env: env, part: t.part)
            let placed = place(built.paragraphs, numbers: built.numbers, body: body, box: CGSize(width: width, height: 0))
            cells.append(Cell(built: built, sets: placed.sets, pieces: placed.pieces,
                              height: placed.height.isFinite ? placed.height : 0))
        }

        // Rows grow to fit: first single-row cells, then cells spanning rows grow their last row.
        var heights = t.rowHeights
        func needed(_ i: Int) -> CGFloat {
            min(cells[i].height + t.cells[i].margins.top + t.cells[i].margins.bottom, TableModel.maxLength)
        }
        for (i, c) in t.cells.enumerated() where c.span.rowEnd - c.span.row == 1 {
            heights[c.span.row] = max(heights[c.span.row], needed(i))
        }
        for (i, c) in t.cells.enumerated() where c.span.rowEnd - c.span.row > 1 {
            let have = heights[c.span.row..<c.span.rowEnd].reduce(0, +)
            if needed(i) > have { heights[c.span.rowEnd - 1] += needed(i) - have }
        }
        var ys = [t.origin.y]
        for h in heights { ys.append((ys.last ?? 0) + h) }

        var out: [CellLayout] = []
        for (i, c) in t.cells.enumerated() {
            let s = c.span
            let rect = CGRect(x: xs[s.col], y: ys[s.row], width: xs[s.colEnd] - xs[s.col], height: ys[s.rowEnd] - ys[s.row])
            let inner = CGRect(x: rect.minX + c.margins.left, y: rect.minY + c.margins.top,
                               width: max(rect.width - c.margins.left - c.margins.right, 0),
                               height: max(rect.height - c.margins.top - c.margins.bottom, 0))
            let dy: CGFloat = switch c.anchor {
            case .top: 0
            case .center: (inner.height - cells[i].height) / 2
            case .bottom: inner.height - cells[i].height
            }
            let toBox = CGAffineTransform(translationX: inner.minX, y: inner.minY + dy)
            let text = ShapeTextLayout(tag: -1, layer: t.layer, placeholder: nil, paragraphs: cells[i].built.paragraphs,
                                       sets: cells[i].sets, pieces: cells[i].pieces, boxSize: inner.size,
                                       toShape: toBox, toCallback: toBox, toSlide: toBox.concatenating(parentToSlide),
                                       fontScale: 1, lineSpaceReduction: 0, pictureBullets: cells[i].built.pictures)
            out.append(CellLayout(span: s, rect: rect, fill: c.fill, borders: c.borders, text: text))
        }
        let bounds = CGRect(x: t.origin.x, y: t.origin.y, width: (xs.last ?? t.origin.x) - t.origin.x,
                            height: (ys.last ?? t.origin.y) - t.origin.y)
        return TableLayout(id: t.id, bounds: bounds, background: t.background, cells: out)
    }
}

// MARK: - Drawing

enum TableRenderer {
    /// Draws into a context whose CTM maps the frame's parent space (y down).
    static func draw(_ t: TableLayout, in ctx: CGContext, renderer: DrawingRenderer, fonts: FontResolver) {
        if t.background != .none { fill(t.bounds, t.background, in: ctx, renderer: renderer) }
        for c in t.cells where c.fill != .none { fill(c.rect, c.fill, in: ctx, renderer: renderer) }
        for c in t.cells {
            let r = c.rect
            let segments: [(CellEdge, CGPoint, CGPoint)] = [
                (.left, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)),
                (.right, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
                (.top, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
                (.bottom, CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
                (.diagonalDown, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
                (.diagonalUp, CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)),
            ]
            for (edge, a, b) in segments {
                guard c.borders.indices.contains(edge.rawValue), let line = c.borders[edge.rawValue] else { continue }
                stroke(line, from: a, to: b, in: ctx, renderer: renderer)
            }
        }
        for c in t.cells { c.text.draw(in: ctx, renderer: renderer, fonts: fonts) }
    }

    private static func fill(_ r: CGRect, _ fill: Fill, in ctx: CGContext, renderer: DrawingRenderer) {
        renderer.drawShape(ShapeModel(transform: Transform2D(offset: r.origin, extent: r.size), fill: fill), in: ctx)
    }

    /// A straight line from `a` to `b` as a `line` preset shape (flipped for the rising diagonal).
    private static func stroke(_ line: Line, from a: CGPoint, to b: CGPoint, in ctx: CGContext, renderer: DrawingRenderer) {
        let t = Transform2D(offset: CGPoint(x: min(a.x, b.x), y: min(a.y, b.y)),
                            extent: CGSize(width: abs(b.x - a.x), height: abs(b.y - a.y)),
                            flipV: (b.x - a.x) * (b.y - a.y) < 0)
        renderer.drawShape(ShapeModel(transform: t, geometry: .preset("line", adjust: [:]), line: line), in: ctx)
    }
}
