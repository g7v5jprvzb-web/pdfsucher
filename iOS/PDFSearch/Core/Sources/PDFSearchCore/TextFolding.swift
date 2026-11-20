import Foundation

/// Folds text for storing and matching: compatibility forms (ligatures), case and accents are
/// folded, words split at a line-end hyphen are joined, and every run of whitespace becomes one
/// space. The same folding is applied to the stored page text and to the search terms, so
/// "Vertrag", "VERTRAG" and "Ver-\ntrag" all match the term "vertrag".
public enum TextFolding {
    private static let locale = Locale(identifier: "de_DE")

    public static func fold(_ text: String) -> String {
        let joined = joinHyphenatedLineBreaks(text.precomposedStringWithCompatibilityMapping)
            .replacingOccurrences(of: "\u{00AD}", with: "")
        let folded = joined.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        return folded.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Splits a query into folded terms (whitespace-separated, quotes removed, duplicates dropped).
    public static func terms(of query: String) -> [String] {
        let cleaned = query.replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "„", with: " ")
            .replacingOccurrences(of: "“", with: " ")
        var seen = Set<String>()
        var result: [String] = []
        for word in fold(cleaned).split(separator: " ") {
            let term = String(word)
            if !term.isEmpty, seen.insert(term).inserted { result.append(term) }
        }
        return result
    }

    /// Non-overlapping occurrences of `term` in `text` (both already folded).
    public static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: [.literal], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// "Ver-\ntrag" → "Vertrag" (letter, hyphen, line break, lowercase letter).
    static func joinHyphenatedLineBreaks(_ text: String) -> String {
        guard text.contains("-") || text.contains("\u{00AD}") else { return text }
        return text.replacingOccurrences(
            of: "(\\p{L})[-\\u00AD\\u2010][ \\t]*\\r?\\n[ \\t]*(\\p{Ll})",
            with: "$1$2",
            options: .regularExpression
        )
    }
}
