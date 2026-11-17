// FTSQueryBuilder.swift — Task 2.3
import Foundation
import IndexKit

public enum FTSPlan: Equatable {
    case fts(String, FTSTable), scanAll
}

/// Turns a parsed query into the FTS5 query that narrows the candidate pages.
/// The result only has to be a superset: `PageMatcher` decides every page, so a term
/// that cannot be expressed safely is simply left out of the FTS query.
///
/// - A suffix/infix term usable on the trigram table → trigram table, with every
///   term's usable strings ANDed (phrases contribute their words separately, because
///   the matcher allows punctuation between phrase words).
/// - Otherwise → word table: `"t"`, `"t"*`, `"a b"`, joined by ` AND `
///   (short suffix/infix terms are left to the matcher).
/// - No usable clause at all → `.scanAll`.
///
/// `ß`: Swift folding turns it into `ss`, FTS5 keeps it. So every `ss` is also tried as
/// `ß`, a prefix ending in `s` also as `…ß`, and an `s` at an open end of a partial term
/// may be half of a `ß` in the text, so the term is also tried without it. A string the
/// trigram table cannot match (< 3 code points) makes the whole term unusable there.
///
/// Term text contains only letters, marks and digits (parser) and is quoted anyway,
/// so no input can inject FTS5 syntax.
public enum FTSQueryBuilder {
    /// nil for an empty query.
    public static func plan(for q: ParsedQuery) -> FTSPlan? {
        guard !q.isEmpty else { return nil }

        let trigramUsable = q.terms.contains { term in
            switch term {
            case .suffix, .infix: return !trigramClauses(for: term).isEmpty
            default: return false
            }
        }
        if trigramUsable {
            return .fts(q.terms.flatMap(trigramClauses).joined(separator: " AND "), .trigram)
        }
        let clauses = q.terms.compactMap(wordClause)
        return clauses.isEmpty ? .scanAll : .fts(clauses.joined(separator: " AND "), .words)
    }

    private static let maxVariants = 8

    // MARK: word table

    private static func wordClause(for term: QueryTerm) -> String? {
        guard isIndexSafe(term) else { return nil }
        switch term {
        case .word(let t):
            return group(sharpSVariants(t), star: false)
        case .prefix(let t):
            var variants = sharpSVariants(t)
            if t.hasSuffix("s") { variants += sharpSVariants(String(t.dropLast()) + "ß") }
            return group(variants, star: true)
        case .phrase(let ws):
            return group(sharpSVariants(ws.joined(separator: " ")), star: false)
        case .suffix, .infix:
            return nil
        }
    }

    // MARK: trigram table

    /// AND-clauses this term contributes on the trigram table (empty: leave it to the matcher).
    private static func trigramClauses(for term: QueryTerm) -> [String] {
        guard isIndexSafe(term) else { return [] }
        switch term {
        case .word(let t): return trigramClause(t, openStart: false, openEnd: false).map { [$0] } ?? []
        case .prefix(let t): return trigramClause(t, openStart: false, openEnd: true).map { [$0] } ?? []
        case .suffix(let t): return trigramClause(t, openStart: true, openEnd: false).map { [$0] } ?? []
        case .infix(let t): return trigramClause(t, openStart: true, openEnd: true).map { [$0] } ?? []
        case .phrase(let ws): return ws.compactMap { trigramClause($0, openStart: false, openEnd: false) }
        }
    }

    private static func trigramClause(_ t: String, openStart: Bool, openEnd: Bool) -> String? {
        var forms = [t]
        if openStart && t.hasPrefix("s") { forms += forms.map { String($0.dropFirst()) } }
        if openEnd && t.hasSuffix("s") { forms += forms.map { String($0.dropLast()) } }
        let perForm = forms.map(sharpSVariants)
        guard perForm.allSatisfy({ $0.count <= maxVariants }) else { return nil }
        var variants = perForm.flatMap { $0 }
        guard variants.allSatisfy({ $0.unicodeScalars.count >= 3 }) else { return nil }
        // "x" OR "yxz" finds the same substrings as "x" alone.
        variants = variants.filter { v in !variants.contains { $0 != v && v.contains($0) } }
        return group(variants, star: false)
    }

    // MARK: helpers

    /// Swift folding also strips Greek and Cyrillic diacritics (й → и, ά → α), FTS5's
    /// `remove_diacritics` only Latin ones, so a folded Greek/Cyrillic term may not
    /// match the indexed token. The same holds for a few Latin letters and for combining marks.
    /// Such terms are left to the matcher.
    private static func isIndexSafe(_ term: QueryTerm) -> Bool {
        let text: String
        switch term {
        case .word(let t), .prefix(let t), .suffix(let t), .infix(let t): text = t
        case .phrase(let ws): text = ws.joined()
        }
        return !text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x370...0x52F).contains(v) || (0x1F00...0x1FFF).contains(v)
                // Swift folds ǽ/ǣ → æ, ǿ → ø, ǯ → ʒ, unicode61 keeps them as they are (final review, 5.6).
                || "æøʒʼ".unicodeScalars.contains(scalar)
                // Cherokee: case folding differs as well.
                || (0x13A0...0x13FF).contains(v) || (0xAB70...0xABBF).contains(v)
                // Combining marks that did not compose with their letter split words in unicode61.
                || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
                || scalar.properties.generalCategory == .enclosingMark
        }
    }

    /// `"v"` (or `"v"*`), or `("v1" OR "v2" …)`; nil when there are too many variants.
    private static func group(_ variants: [String], star: Bool) -> String? {
        var unique: [String] = []
        for v in variants where !unique.contains(v) { unique.append(v) }
        guard !unique.isEmpty, unique.count <= maxVariants else { return nil }
        let quoted = unique.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (star ? "*" : "") }
        return quoted.count == 1 ? quoted[0] : "(" + quoted.joined(separator: " OR ") + ")"
    }

    /// Every spelling where any set of non-overlapping `ss` is written `ß`, original first.
    /// Stops early (returning more than `maxVariants`) when there are too many.
    private static func sharpSVariants(_ text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        func walk(_ i: Int, _ built: String) {
            if results.count > maxVariants { return }
            guard i < chars.count else { results.append(built); return }
            walk(i + 1, built + String(chars[i]))
            if chars[i] == "s", i + 1 < chars.count, chars[i + 1] == "s" {
                walk(i + 2, built + "ß")
            }
        }
        walk(0, "")
        return results
    }
}
