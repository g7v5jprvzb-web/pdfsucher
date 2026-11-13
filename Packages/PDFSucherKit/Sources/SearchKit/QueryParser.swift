// QueryParser.swift — Task 2.1
import Foundation

/// Turns user input into a `ParsedQuery` (spec §4.2).
///
/// - Whitespace outside quotes separates tokens; text in quotes is a `.phrase`
///   (an unterminated quote runs to the end of the input).
/// - `x*` → prefix, `*x` → suffix, `*x*` → infix, plain → word
///   (or infix when `partialWords` is on).
/// - Term text is case- and diacritic-folded (`SearchFolding`), and only letters,
///   combining marks and digits survive. Any other character inside a token
///   (`-`, `(`, `^`, `*`, …) separates word parts; a `*` in a separator is a wildcard
///   on the part(s) it touches, so `(Vertrag*)` is still a prefix and `Ver*trag`
///   becomes prefix `ver` AND suffix `trag` (the closest the term types can express).
/// - A multi-part token without any `*` becomes a phrase (`E-Mail` → `["e","mail"]`,
///   which is how the FTS5 word tokenizer sees it too). With `*`, or with
///   `partialWords` on (token treated as `*token*`), each part becomes its own term
///   and the parts are ANDed independently: their order and adjacency are not kept.
/// - Terms that end up empty are dropped, so FTS5 syntax can never reach the index.
public enum QueryParser {
    public static func parse(_ input: String, partialWords: Bool) -> ParsedQuery {
        var terms: [QueryTerm] = []
        for token in tokenize(input) {
            switch token {
            case .quoted(let text):
                let words = SearchFolding.wordParts(of: text)
                if !words.isEmpty { terms.append(.phrase(words)) }
            case .bare(let text):
                terms.append(contentsOf: bareTerms(text, partialWords: partialWords))
            }
        }
        return ParsedQuery(terms: terms)
    }

    private enum Token { case bare(String), quoted(String) }

    /// ASCII and typographic double quotes (macOS smart quotes, German „…“ and »…«).
    /// Any of them opens or closes a phrase. Single quotes are left out: they double as apostrophes.
    private static let quoteCharacters: Set<Character> = ["\"", "„", "“", "”", "«", "»"]

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuote = false
        func flush() {
            if inQuote {
                tokens.append(.quoted(current))
            } else if !current.isEmpty {
                tokens.append(.bare(current))
            }
            current = ""
        }
        for ch in input {
            if quoteCharacters.contains(ch) {
                flush()
                inQuote.toggle()
            } else if !inQuote && ch.isWhitespace {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()  // an unterminated quote is a phrase to the end
        return tokens
    }

    private static func bareTerms(_ token: String, partialWords: Bool) -> [QueryTerm] {
        let parts = SearchFolding.parts(of: token)
        guard !parts.isEmpty else { return [] }
        let hasStar = parts.contains { $0.starBefore || $0.starAfter }

        if parts.count == 1 && !hasStar {
            return [partialWords ? .infix(parts[0].text) : .word(parts[0].text)]
        }
        if !hasStar && !partialWords {
            return [.phrase(parts.map(\.text))]
        }
        // "Wortteile finden" on and no `*` of its own: the token is treated as `*token*`.
        let openOuter = !hasStar && partialWords
        return parts.enumerated().map { i, part in
            let lead = part.starBefore || (openOuter && i == 0)
            let trail = part.starAfter || (openOuter && i == parts.count - 1)
            switch (lead, trail) {
            case (true, true): return .infix(part.text)
            case (true, false): return .suffix(part.text)
            case (false, true): return .prefix(part.text)
            case (false, false): return .word(part.text)
            }
        }
    }
}

/// Folding and word-character rules shared by the parser and the matcher, so that
/// query terms and page text are compared in the same form.
enum SearchFolding {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Letters, marks and digits — the regex class `[\p{L}\p{M}\p{N}]`.
    static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    struct Part: Equatable {
        var text: String
        /// The separator run directly before / after this part contains a `*`.
        var starBefore = false
        var starAfter = false
    }

    /// Folds `s` and splits it into maximal runs of word characters, noting which
    /// runs touch a `*`. A run made only of marks (e.g. a stray combining accent) is not a word.
    static func parts(of s: String) -> [Part] {
        var parts: [Part] = []
        var current = String.UnicodeScalarView()
        var starInSeparator = false
        func flush() {
            guard !current.isEmpty else { return }
            if current.contains(where: { !isMark($0) }) {
                parts.append(Part(text: String(current), starBefore: starInSeparator))
                starInSeparator = false
            }
            current = String.UnicodeScalarView()
        }
        for u in fold(s).unicodeScalars {
            if isWordScalar(u) {
                current.append(u)
            } else {
                flush()
                if u == "*" {
                    starInSeparator = true
                    if !parts.isEmpty && current.isEmpty { parts[parts.count - 1].starAfter = true }
                }
            }
        }
        flush()
        return parts
    }

    static func wordParts(of s: String) -> [String] {
        parts(of: s).map(\.text)
    }

    private static func isMark(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}
