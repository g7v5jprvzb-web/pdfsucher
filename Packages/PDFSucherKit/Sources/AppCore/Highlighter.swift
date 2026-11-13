// Highlighter.swift — Task 5.3
import Foundation
import IndexKit
import SearchKit
import ViewerUI

/// Highlight ranges for tiles and the large page view, exactly where the search matched.
///
/// The search ran on normalized text (hyphenated words joined, ligatures expanded, whitespace
/// collapsed), so the matcher runs on `TextNormalizer.normalizeMapped(page.string).text` too and
/// every match is mapped back onto `page.string`. A word split across a line break
/// (`Ver-\ntrag`) maps to both line parts; it is returned as one range per line (`Ver-`, `trag`),
/// so each part is marked on its own line.
public enum Highlighter {
    /// nil for an empty query (nothing to mark).
    public static func make(_ query: ParsedQuery) -> HighlightRanges? {
        guard !query.isEmpty else { return nil }
        let matcher = PageMatcher(query)
        return { text in ranges(in: text, matcher: matcher) }
    }

    static func ranges(in text: String, matcher: PageMatcher) -> [Range<String.Index>] {
        let normalized = TextNormalizer.normalizeMapped(text)
        guard let found = matcher.ranges(in: normalized.text) else { return [] }
        let original = text as NSString
        let parts = found.flatMap { match in
            lineParts(of: normalized.originalRange(for: NSRange(match, in: normalized.text)), in: original)
        }
        return merged(parts).compactMap { Range($0, in: text) }
    }

    /// Sorted, with overlapping ranges joined: several matches inside one ligature (`Kaﬀee`, `*f*`)
    /// map to the same original range and must be drawn once.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location < NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `range` split at line breaks, each part without surrounding whitespace; empty parts dropped.
    static func lineParts(of range: NSRange, in text: NSString) -> [NSRange] {
        var parts: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        while start < end {
            let rest = NSRange(location: start, length: end - start)
            let lineBreak = text.rangeOfCharacter(from: .newlines, options: [], range: rest)
            let partEnd = lineBreak.location == NSNotFound ? end : lineBreak.location
            if let trimmed = trimmed(NSRange(location: start, length: partEnd - start), in: text) {
                parts.append(trimmed)
            }
            start = lineBreak.location == NSNotFound ? end : NSMaxRange(lineBreak)
        }
        return parts
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange? {
        var lower = range.location, upper = NSMaxRange(range)
        let space = CharacterSet.whitespacesAndNewlines
        while lower < upper, let s = Unicode.Scalar(text.character(at: lower)), space.contains(s) { lower += 1 }
        while upper > lower, let s = Unicode.Scalar(text.character(at: upper - 1)), space.contains(s) { upper -= 1 }
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }
}
