// SlideText.swift — Task 11 (SlideKit)
// The searchable text of a slide and its word boxes, for PDFSucher's full-text index and search highlighting.
//
// Raw text: the slide's own shapes in z-order (groups depth-first, tables row by row, cells left to right; SmartArt
// shapes in drawing order; charts: title, category labels, legend entries),
// built from the same laid-out paragraphs that are drawn (`DeckStore.textLayout`, table cells included), so
// text and word rects agree. Paragraphs (and table cells and rows) are joined with "\n", shapes with "\n\n"; master/layout text,
// hidden shapes, empty placeholders and bullets are not part of it. The raw text is normalized with
// `TextNormalizer.normalizeMapped`; word ranges go original → normalized through an inverse of its
// `originalRange(for:)` (built once per slide), boxes are normalized to 0…1 of the slide, origin top left.
import CoreGraphics
import Foundation
import IndexKit
import OOXMLKit

/// The normalized text of one slide and its word boxes (cached per slide in `DeckStore`).
struct SlideTextResult: Sendable {
    let text: String
    let words: [OCRWord]

    static let empty = SlideTextResult(text: "", words: [])
}

enum SlideTextBuilder {
    static let tableURI = "http://schemas.openxmlformats.org/drawingml/2006/table"

    static func build(model: SlideModel, layout: SlideTextLayout, slideSize: CGSize) -> SlideTextResult {
        guard let slidePart = model.slide?.path else { return .empty }
        var raw = RawText()
        collect(model.elements, model: model, layout: layout, slidePart: slidePart, into: &raw)
        let (text, map) = normalize(raw.text)
        var words: [OCRWord] = []
        for w in raw.words {
            guard let range = map.normalizedRange(for: w.range),
                  let box = normalizedBox(w.rect, slideSize: slideSize) else { continue }
            words.append(OCRWord(range: range, box: box))
        }
        return SlideTextResult(text: text, words: words)
    }

    /// `TextNormalizer.normalizeMapped(raw)` and its inverse map.
    static func normalize(_ raw: String) -> (text: String, map: InverseMap) {
        let normalized = TextNormalizer.normalizeMapped(raw)
        return (normalized.text, InverseMap(normalized))
    }

    // MARK: raw text

    /// The raw slide string under construction, with word rects (slide points) and their UTF-16 ranges in it.
    struct RawText {
        private(set) var text = ""
        private(set) var length = 0
        private(set) var words: [(range: NSRange, rect: CGRect)] = []

        /// Appends one shape: its paragraphs joined with "\n", "\n\n" before it if something came before.
        /// Returns each paragraph's UTF-16 offset in `text`; nothing is appended (and nil returned) when all
        /// paragraphs are empty.
        mutating func appendShape(_ paragraphs: [String]) -> [Int]? {
            guard paragraphs.contains(where: { !$0.isEmpty }) else { return nil }
            if length > 0 { append("\n\n") }
            var offsets: [Int] = []
            for (i, p) in paragraphs.enumerated() {
                if i > 0 { append("\n") }
                offsets.append(length)
                // U+FFFC (inline object) is a symbol to the normalizer; it separates words like a space. Same
                // UTF-16 length, so the offsets stay valid.
                append(p.replacingOccurrences(of: "\u{FFFC}", with: " "))
            }
            return offsets
        }

        mutating func addWord(_ range: NSRange, rect: CGRect) {
            words.append((range, rect))
        }

        private mutating func append(_ s: String) {
            text += s
            length += s.utf16.count
        }
    }

    private static func collect(_ elements: [SlideElement], model: SlideModel, layout: SlideTextLayout,
                                slidePart: String, into raw: inout RawText) {
        for e in elements {
            switch e {
            case .shape(let s):
                guard let tag = s.tag, model.texts.indices.contains(tag), model.texts[tag].layer == .slide,
                      let l = layout.shape(tag: tag) else { continue }
                guard let offsets = raw.appendShape(l.sets.map(\.plainText)) else { continue }
                for w in l.slideWordRects() where offsets.indices.contains(w.paragraph) {
                    raw.addWord(NSRange(location: offsets[w.paragraph] + w.range.location, length: w.range.length),
                                rect: w.rect)
                }
            case .group(_, let children):
                collect(children, model: model, layout: layout, slidePart: slidePart, into: &raw)
            case .graphicFrame(let f):
                guard f.part.part == slidePart else { continue }
                if let t = f.table, let laidOut = layout.tables[t.id] { appendTable(laidOut, into: &raw) }
                if let c = f.chart, let laidOut = layout.charts[c.id] { appendChart(laidOut, into: &raw) }
            case .picture:
                continue
            }
        }
    }

    /// A table as one block: anchor cells in row-major order (continuation cells are not in the layout), empty
    /// cells skipped, every paragraph of the other cells joined with "\n" (cells and rows alike), each cell's
    /// word rects mapped into it.
    private static func appendTable(_ t: TableLayout, into raw: inout RawText) {
        var paragraphs: [String] = []
        var first: [Int?] = []
        for c in t.cells {
            let texts = c.text.sets.map(\.plainText)
            guard texts.contains(where: { !$0.isEmpty }) else { first.append(nil); continue }
            first.append(paragraphs.count)
            paragraphs += texts
        }
        guard let offsets = raw.appendShape(paragraphs) else { return }
        for (c, start) in zip(t.cells, first) {
            guard let start else { continue }
            for w in c.text.slideWordRects() where offsets.indices.contains(start + w.paragraph) {
                raw.addWord(NSRange(location: offsets[start + w.paragraph] + w.range.location, length: w.range.length),
                            rect: w.rect)
            }
        }
    }

    /// A chart as one block: title, category labels and legend entries, one paragraph each (ChartRenderer.swift).
    private static func appendChart(_ c: ChartLayout, into raw: inout RawText) {
        guard let offsets = raw.appendShape(c.searchableTexts.map(\.set.plainText)) else { return }
        for w in c.slideWordRects() where offsets.indices.contains(w.paragraph) {
            raw.addWord(NSRange(location: offsets[w.paragraph] + w.range.location, length: w.range.length), rect: w.rect)
        }
    }

    // MARK: boxes

    /// `rect` (slide points) as a fraction of the slide, clamped to 0…1; nil if nothing of it is on the slide.
    static func normalizedBox(_ rect: CGRect, slideSize: CGSize) -> CGRect? {
        let r = rect.standardized
        guard slideSize.width > 0, slideSize.height > 0, slideSize.width.isFinite, slideSize.height.isFinite,
              [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) else { return nil }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let x0 = clamp(r.minX / slideSize.width), x1 = clamp(r.maxX / slideSize.width)
        let y0 = clamp(r.minY / slideSize.height), y1 = clamp(r.maxY / slideSize.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: original → normalized

    /// For every normalized UTF-16 unit k, the original UTF-16 span it came from (`originalRange` of k..<k+1),
    /// made non-decreasing so binary search applies (the normalizer emits in source order).
    struct InverseMap {
        private var starts: [Int] = []
        private var ends: [Int] = []
        /// The normalized text's UTF-16 units.
        private let units: [UInt16]

        init(_ n: NormalizedText) {
            units = Array(n.text.utf16)
            let count = units.count
            starts.reserveCapacity(count)
            ends.reserveCapacity(count)
            for k in 0..<count {
                let r = n.originalRange(for: NSRange(location: k, length: 1))
                starts.append(max(r.location, starts.last ?? 0))
                ends.append(max(NSMaxRange(r), ends.last ?? 0))
            }
        }

        /// The smallest normalized range whose units' original spans intersect `original`; nil if none does
        /// (the normalizer dropped the whole word) or if it is only collapsed whitespace (a word made of
        /// characters the normalizer treats as space, e.g. private-use symbols).
        func normalizedRange(for original: NSRange) -> NSRange? {
            let a = original.location, b = NSMaxRange(original)
            guard a >= 0, b > a else { return nil }
            let lo = firstIndex(in: ends) { $0 > a }       // first unit ending after a
            let hi = firstIndex(in: starts) { $0 >= b } - 1 // last unit starting before b
            guard lo <= hi, lo < starts.count, starts[lo] < b,
                  units[lo...hi].contains(where: { $0 != 0x20 }) else { return nil }
            return NSRange(location: lo, length: hi - lo + 1)
        }

        /// First index whose value satisfies `pred` (monotonic false…true), or `values.count`.
        private func firstIndex(in values: [Int], where pred: (Int) -> Bool) -> Int {
            var lo = 0, hi = values.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pred(values[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
    }
}
