// TextNormalizer.swift — Task 1.2
import Foundation
import os

/// Normalized text plus, for every UTF-16 unit of it, the UTF-16 range in the original string
/// it came from. Use it to turn a match found in normalized text (e.g. by the PageMatcher on
/// `normalizeMapped(page.string).text`) into an `NSRange` of `PDFPage.string` for highlighting.
public struct NormalizedText: Sendable, Equatable {
    /// Identical to `TextNormalizer.normalize(original)`.
    public let text: String
    private let starts: [Int]
    private let ends: [Int]

    init(text: String, starts: [Int], ends: [Int]) {
        self.text = text
        self.starts = starts
        self.ends = ends
    }

    /// The UTF-16 range of the original string that produced `range` (UTF-16, in `text`).
    /// It runs from the start of the first unit's source to the end of the last one's, so it
    /// also covers characters the normalizer dropped in between: a match on `Vertrag` from
    /// `Ver-\ntrag` maps to `Ver-\ntrag` (both line parts). Part of a ligature maps to the whole
    /// ligature. Out-of-bounds ranges are clamped; an empty range maps to an empty range.
    public func originalRange(for range: NSRange) -> NSRange {
        let count = starts.count
        let lower = min(max(range.location, 0), count)
        // Clamp the length before adding, so huge locations/lengths cannot overflow.
        let upper = lower + min(max(range.length, 0), count - lower)
        guard upper > lower else {
            let at = lower < count ? starts[lower] : (ends.last ?? 0)
            return NSRange(location: at, length: 0)
        }
        return NSRange(location: starts[lower], length: ends[upper - 1] - starts[lower])
    }

    /// The inverse direction: the UTF-16 range of `text` produced by `originalRange` (UTF-16, in
    /// the original string), i.e. from the first to the last normalized unit whose source
    /// overlaps it. Used to place OCR word ranges (found in the raw recognized text) in the
    /// stored text. A range whose characters were all dropped (spaces, format characters), an
    /// empty range and an out-of-bounds range give an empty range.
    public func normalizedRange(forOriginal originalRange: NSRange) -> NSRange {
        let lower = originalRange.location
        let upper = lower + max(originalRange.length, 0)
        guard originalRange.length > 0, lower >= 0 else { return NSRange(location: 0, length: 0) }
        var first = -1
        var last = -1
        // `starts` never decreases (units are emitted in source order): binary-search the first
        // unit that could overlap, then walk until the units start after the range.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= lower && starts[mid] < lower { lo = mid + 1 } else { hi = mid }
        }
        var k = max(lo - 1, 0)
        while k < starts.count, starts[k] < upper {
            if ends[k] > lower {
                if first < 0 { first = k }
                last = k
            }
            k += 1
        }
        guard first >= 0 else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first, length: last - first + 1)
    }
}

/// Cleans text extracted from a PDF page before it is stored and indexed.
///
/// 1. Hyphen (`-`, U+2010) followed by one line break (spaces/tabs around it ignored):
///    - after a letter, before a lowercase letter: the word is joined (`Ver-\ntrag` → `Vertrag`),
///      except before a conjunction (`Kranken-\nund` → `Kranken- und`, German suspended hyphen);
///    - after a letter, before anything else: the hyphen stays, the break goes
///      (`Nord-\nSüd` → `Nord-Süd`);
///    - not after a letter, or across a blank line: the hyphen stays and the break becomes a
///      space (`3-\nfach` → `3- fach`).
///    A soft hyphen (U+00AD) always disappears; at a single break after a letter it joins.
///    Other dashes (en dash, U+2011 non-breaking hyphen) are not hyphenation marks.
/// 2. Latin typographic ligatures (U+FB00…U+FB06) are expanded (`ﬁ` → `fi`).
///    Nothing else is compatibility-folded, so `²`, `½`, `ß`, `Æ` stay as they are.
/// 3. Invisible format characters (Unicode category Cf, e.g. U+200B, U+FEFF) are removed,
///    except ZWNJ/ZWJ (U+200C/U+200D); control and private-use characters (e.g. the Word
///    bullet U+F0B7) count as whitespace, so FTS5 and the PageMatcher see the same words.
/// 4. Every run of whitespace (incl. line breaks, NBSP) becomes one space; leading and
///    trailing whitespace is removed.
/// 5. The result is NFC.
///
/// Character offsets in the result do NOT correspond to offsets in `PDFPage.string`. For
/// highlighting, use `normalizeMapped(page.string)`: its `text` equals the stored page text,
/// and `originalRange(for:)` maps a match back onto `PDFPage.string`.
public enum TextNormalizer {
    private static let log = Logger(subsystem: "local.pdfsearch.ipad", category: "TextNormalizer")

    public static func normalize(_ s: String) -> String {
        String(core(s, record: false).scalars).precomposedStringWithCanonicalMapping
    }

    /// `normalize` plus the offset mapping back to `s` (slower; for highlighting one page).
    public static func normalizeMapped(_ s: String) -> NormalizedText {
        let (scalars, spans) = core(s, record: true)
        // NFC per grapheme cluster (composition never crosses a cluster boundary); each output
        // scalar takes the union of its cluster's source spans.
        var text = String.UnicodeScalarView()
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(scalars.count)
        ends.reserveCapacity(scalars.count)
        var index = 0
        for character in String(scalars) {
            let count = character.unicodeScalars.count
            let lo = spans[index].lowerBound
            let hi = spans[index + count - 1].upperBound
            index += count
            // Fast path: a lone scalar below U+0300 (Latin, digits, punctuation) is already NFC.
            if count == 1, let only = character.unicodeScalars.first, only.value < 0x300 {
                text.append(only)
                starts.append(lo)
                ends.append(hi)
                continue
            }
            for scalar in String(character).precomposedStringWithCanonicalMapping.unicodeScalars {
                text.append(scalar)
                for _ in 0..<scalar.utf16.count {
                    starts.append(lo)
                    ends.append(hi)
                }
            }
        }
        let result = String(text)
        // Guard the contract with `normalize` (stdlib grapheme rules vs Foundation NFC tables).
        let whole = String(scalars).precomposedStringWithCanonicalMapping
        if !result.utf16.elementsEqual(whole.utf16) {
            log.fault("normalizeMapped differs from normalize; highlights on this page may be offset")
            assertionFailure("normalizeMapped/normalize mismatch")
        }
        return NormalizedText(text: result, starts: starts, ends: ends)
    }

    /// The normalization steps before NFC. With `record`, `spans[k]` is the UTF-16 range in `s`
    /// of the source of output scalar k.
    private static func core(_ s: String, record: Bool) -> (scalars: String.UnicodeScalarView, spans: [Range<Int>]) {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        var offsets: [Int] = []
        if record {
            offsets.reserveCapacity(n + 1)
            var o = 0
            for c in scalars { offsets.append(o); o += c.utf16.count }
            offsets.append(o)
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(n)
        var spans: [Range<Int>] = []
        var pendingSpace = false
        var pendingSpan = 0..<0

        func span(_ from: Int, _ to: Int) -> Range<Int> { record ? offsets[from]..<offsets[to] : 0..<0 }

        func markSpace(_ from: Int, _ to: Int) {
            guard record else { pendingSpace = true; return }
            let r = span(from, to)
            pendingSpan = pendingSpace ? pendingSpan.lowerBound..<max(pendingSpan.upperBound, r.upperBound) : r
            pendingSpace = true
        }

        func emit(_ c: Unicode.Scalar, _ source: Range<Int>) {
            if pendingSpace {
                if !out.isEmpty {
                    out.append(" ")
                    if record { spans.append(pendingSpan) }
                }
                pendingSpace = false
            }
            out.append(c)
            if record { spans.append(source) }
        }

        var i = 0
        while i < n {
            let c = scalars[i]
            if isHyphen(c) {
                // Look for: [spaces] line break(s) [spaces] after the hyphen.
                var j = i + 1
                while j < n, isHorizontalSpace(scalars[j]) { j += 1 }
                if j < n, isLineBreak(scalars[j]) {
                    var breaks = 0
                    while j < n, isLineBreak(scalars[j]) || isHorizontalSpace(scalars[j]) {
                        if isLineBreak(scalars[j]), !(scalars[j] == "\n" && j > 0 && scalars[j - 1] == "\r") {
                            breaks += 1
                        }
                        j += 1
                    }
                    let afterLetter = !pendingSpace && (out.last?.properties.isAlphabetic ?? false)
                    if c == softHyphen {
                        if !(afterLetter && breaks == 1) { markSpace(i + 1, j) }
                    } else if !afterLetter || breaks > 1 || startsConjunction(scalars, at: j) {
                        emit(c, span(i, i + 1))
                        markSpace(i + 1, j)
                    } else if !(j < n && startsLowercase(scalars[j])) {
                        emit(c, span(i, i + 1))
                    }
                    i = j
                    continue
                }
                if c != softHyphen { emit(c, span(i, i + 1)) }
                i += 1
                continue
            }
            if c.properties.generalCategory == .format, c != "\u{200C}", c != "\u{200D}" {
                i += 1
                continue
            }
            if c.properties.generalCategory == .control || c.properties.generalCategory == .privateUse {
                markSpace(i, i + 1)
                i += 1
                continue
            }
            if let expansion = ligatures[c] {
                for e in expansion.unicodeScalars { emit(e, span(i, i + 1)) }
            } else if c.properties.isWhitespace {
                markSpace(i, i + 1)
            } else {
                emit(c, span(i, i + 1))
            }
            i += 1
        }
        return (out, spans)
    }

    private static let softHyphen: Unicode.Scalar = "\u{00AD}"

    private static func isHyphen(_ c: Unicode.Scalar) -> Bool {
        c == "-" || c == "\u{2010}" || c == softHyphen
    }

    private static func isHorizontalSpace(_ c: Unicode.Scalar) -> Bool {
        c.properties.isWhitespace && !isLineBreak(c)
    }

    private static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}": true
        default: false
        }
    }

    private static func startsLowercase(_ c: Unicode.Scalar) -> Bool {
        c.properties.isLowercase
    }

    /// Words after which a line-end hyphen is a German suspended hyphen (`Vor- und Nachteile`).
    private static let conjunctions: Set<String> = ["und", "oder", "bzw", "sowie", "bis", "als", "noch", "wie", "sondern"]

    private static func startsConjunction(_ scalars: [Unicode.Scalar], at start: Int) -> Bool {
        var end = start
        while end < scalars.count, scalars[end].properties.isAlphabetic, end - start <= 8 { end += 1 }
        guard end > start, end - start <= 7 else { return false }
        var word = String.UnicodeScalarView()
        word.append(contentsOf: scalars[start..<end])
        return conjunctions.contains(String(word))
    }

    private static let ligatures: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
        "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]
}
