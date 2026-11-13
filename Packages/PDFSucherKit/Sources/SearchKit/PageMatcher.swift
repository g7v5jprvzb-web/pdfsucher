// PageMatcher.swift — Task 2.2
import Foundation

/// The single source of truth for whether a page matches a query, how often,
/// and which characters to highlight. Works on folded text (`FoldedText`); FTS5 only
/// narrows the candidate pages.
///
/// With word characters `W = [\p{L}\p{M}\p{N}]` (the parser's), a term `t` matches
/// like these regular expressions, leftmost first, without overlaps:
/// - word:   `(?<!W)t(?!W)`        prefix: `(?<!W)tW*`
/// - suffix: `(?<!W)W*t(?!W)`      infix:  `t`
/// - phrase: words separated by one or more non-word characters, word boundaries at
///   both ends (the FTS5 word tokenizer also ignores punctuation between words)
///
/// It is implemented as a literal search on UTF-16 units with explicit boundary checks:
/// several times faster than `NSRegularExpression`, and this runs on every candidate page.
public struct PageMatcher: Sendable {
    private enum Kind: Sendable { case word, prefix, suffix, infix, phrase }
    private struct Pattern: Sendable {
        let kind: Kind
        let words: [[UInt16]]  // one entry, or the phrase's words
    }
    private let patterns: [Pattern]?  // nil: query can never match

    public init(_ query: ParsedQuery) {
        guard !query.isEmpty else { patterns = nil; return }
        var result: [Pattern] = []
        for term in query.terms {
            let p: Pattern
            switch term {
            case .word(let t): p = Pattern(kind: .word, words: [Array(t.utf16)])
            case .prefix(let t): p = Pattern(kind: .prefix, words: [Array(t.utf16)])
            case .suffix(let t): p = Pattern(kind: .suffix, words: [Array(t.utf16)])
            case .infix(let t): p = Pattern(kind: .infix, words: [Array(t.utf16)])
            case .phrase(let ws): p = Pattern(kind: .phrase, words: ws.map { Array($0.utf16) }.filter { !$0.isEmpty })
            }
            guard !p.words.isEmpty, p.words.allSatisfy({ !$0.isEmpty }) else { patterns = nil; return }
            result.append(p)
        }
        patterns = result
    }

    /// nil when any term/phrase is absent; else all match ranges in `text` (original indices), sorted.
    /// Overlapping ranges (several terms hitting the same characters) are merged, so a
    /// character is highlighted and counted once.
    public func ranges(in text: String) -> [Range<String.Index>]? {
        let folded = FoldedText(text)
        guard let offsets = mergedOffsets(in: folded) else { return nil }
        return offsets.map { folded.index($0.lowerBound)..<folded.index($0.upperBound) }
    }

    public func matchCount(in text: String) -> Int? {
        mergedOffsets(in: FoldedText(text))?.count
    }

    /// Merged original UTF-16 ranges of all matches, or nil when a term is absent.
    private func mergedOffsets(in folded: FoldedText) -> [Range<Int>]? {
        guard let patterns else { return nil }
        var found: [Range<Int>] = []
        let complete: Bool = folded.units.withUnsafeBufferPointer { text in
            for p in patterns {
                let before = found.count
                Self.matches(p, in: text) { lo, hi in
                    found.append(folded.originalOffsets(utf16Lower: lo, utf16Upper: hi))
                }
                if found.count == before { return false }
            }
            return true
        }
        guard complete else { return nil }
        found.sort { $0.lowerBound < $1.lowerBound || ($0.lowerBound == $1.lowerBound && $0.upperBound < $1.upperBound) }
        var out: [Range<Int>] = []
        out.reserveCapacity(found.count)
        for r in found {
            if let last = out.last, r.lowerBound < last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: matching on UTF-16 units

    private static func matches(_ p: Pattern, in text: UnsafeBufferPointer<UInt16>, _ emit: (Int, Int) -> Void) {
        let first = p.words[0]
        var from = 0
        while let at = find(first, in: text, from: from) {
            var end = at + first.count
            var start = at
            var ok: Bool
            switch p.kind {
            case .word:
                ok = !isWord(before: start, text) && !isWord(at: end, text)
            case .prefix:
                ok = !isWord(before: start, text)
                if ok { end = skip(from: end, text, word: true) }
            case .suffix:
                ok = !isWord(at: end, text)
                if ok { start = skipBack(from: start, text) }
            case .infix:
                ok = true
            case .phrase:
                ok = !isWord(before: start, text)
                for w in p.words.dropFirst() where ok {
                    let next = skip(from: end, text, word: false)
                    if next == end || !hasPrefix(w, in: text, at: next) { ok = false } else { end = next + w.count }
                }
                ok = ok && !isWord(at: end, text)
            }
            if ok {
                emit(start, end)
                from = end
            } else {
                from = at + 1
            }
        }
    }

    private static func find(_ needle: [UInt16], in text: UnsafeBufferPointer<UInt16>, from: Int) -> Int? {
        guard needle.count <= text.count else { return nil }
        let head = needle[0]
        var i = from
        let last = text.count - needle.count
        while i <= last {
            if text[i] == head && hasPrefix(needle, in: text, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func hasPrefix(_ needle: [UInt16], in text: UnsafeBufferPointer<UInt16>, at i: Int) -> Bool {
        guard i + needle.count <= text.count else { return false }
        for k in 1..<needle.count where text[i + k] != needle[k] { return false }
        return text[i] == needle[0]
    }

    /// Advances over word (or non-word) characters starting at `i`.
    private static func skip(from i: Int, _ text: UnsafeBufferPointer<UInt16>, word: Bool) -> Int {
        var j = i
        while j < text.count, isWord(at: j, text) == word {
            j += isHighSurrogate(text[j]) && j + 1 < text.count ? 2 : 1
        }
        return j
    }

    /// Moves back over word characters ending just before `i`.
    private static func skipBack(from i: Int, _ text: UnsafeBufferPointer<UInt16>) -> Int {
        var j = i
        while j > 0, isWord(before: j, text) {
            j -= j >= 2 && isLowSurrogate(text[j - 1]) && isHighSurrogate(text[j - 2]) ? 2 : 1
        }
        return j
    }

    private static func isWord(at i: Int, _ text: UnsafeBufferPointer<UInt16>) -> Bool {
        guard i < text.count else { return false }
        let u = text[i]
        if isHighSurrogate(u), i + 1 < text.count, isLowSurrogate(text[i + 1]) {
            return isWordScalar(0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(text[i + 1] - 0xDC00))
        }
        return isWordScalar(UInt32(u))
    }

    private static func isWord(before i: Int, _ text: UnsafeBufferPointer<UInt16>) -> Bool {
        guard i > 0 else { return false }
        let u = text[i - 1]
        if isLowSurrogate(u), i >= 2, isHighSurrogate(text[i - 2]) {
            return isWordScalar(0x10000 + (UInt32(text[i - 2] - 0xD800) << 10) + UInt32(u - 0xDC00))
        }
        return isWordScalar(UInt32(u))
    }

    private static func isWordScalar(_ v: UInt32) -> Bool {
        if v < 0x80 {
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        }
        guard let s = Unicode.Scalar(v) else { return false }  // lone surrogate
        return SearchFolding.isWordScalar(s)
    }

    private static func isHighSurrogate(_ u: UInt16) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    private static func isLowSurrogate(_ u: UInt16) -> Bool { u >= 0xDC00 && u <= 0xDFFF }
}
