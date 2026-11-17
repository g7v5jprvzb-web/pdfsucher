import Testing
import Foundation
import IndexKit

/// Exact code-unit comparison: Swift `==` treats canonically equivalent strings as equal,
/// which would hide exactly the NFC differences these tests guard against.
private func sameUnits(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }

/// SplitMix64, so a failing random input reproduces.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("TextNormalizer offset mapping")
struct TextNormalizerMappingTests {
    /// The original text covered by the normalized range of `needle`.
    private func original(of needle: String, in source: String) throws -> String {
        let mapped = TextNormalizer.normalizeMapped(source)
        let range = (mapped.text as NSString).range(of: needle)
        try #require(range.location != NSNotFound, "\(needle) not in \(mapped.text)")
        return (source as NSString).substring(with: mapped.originalRange(for: range))
    }

    @Test func textEqualsNormalize() {
        for s in ["", " a ", "Ver-\ntrag", "Kranken-\nund", "ﬁnden  ﬂach", "Mu\u{0308}ller", "a\u{200B}b\u{F0B7}c",
                  "3-\nfach", "Ver\u{00AD}\nTrag", "x\r\n\r\ny", "👨\u{200D}👩\u{200D}👧 e\u{301}\u{200B}\u{301}",
                  "\u{1100}\u{1161}\u{11A8}", "\u{1100}\u{200B}\u{1161}", "\u{0B47}\u{200B}\u{0B3E}", "\u{0B47}\u{0B3E}",
                  "e\u{0301}\u{0327}", "A\u{030A}", "\u{212B}", "\u{0344}", "\u{0F73}", "🇩🇪🇫🇷"] {
            #expect(sameUnits(TextNormalizer.normalizeMapped(s).text, TextNormalizer.normalize(s)), "\(s.debugDescription)")
        }
    }

    @Test func textEqualsNormalizeOnRandomInput() {
        var rng = Seeded(state: 42)
        let pool: [String] = ["\u{1100}", "\u{1161}", "\u{11A8}", "\u{0B47}", "\u{0B3E}", "\u{0327}", "\u{1F1E9}", "\u{1F1EA}",
                              "a", "B", "ü", "u\u{0308}", "-", "\u{2010}", "\u{00AD}", "\n", "\r\n", " ", "\t", "ﬁ", "ﬃ",
                              "\u{200B}", "\u{FEFF}", "\u{F0B7}", "\u{0301}", "ß", "Æ", "und", "x", "😀", "\u{0007}", "\u{2028}", "\u{00A0}"]
        for _ in 0..<2_000 {
            let s = (0..<Int.random(in: 0...20, using: &rng)).map { _ in pool.randomElement(using: &rng)! }.joined()
            #expect(sameUnits(TextNormalizer.normalizeMapped(s).text, TextNormalizer.normalize(s)), "\(s.debugDescription)")
        }
    }

    @Test func plainWordMapsToItself() throws {
        #expect(try original(of: "Vertrag", in: "Der Vertrag endet") == "Vertrag")
    }

    @Test func rangeAfterCollapsedWhitespaceLandsOnTheWord() throws {
        let source = "ﬁnden  Ver-\ntrag\nEnde Schluss"
        #expect(try original(of: "Ende", in: source) == "Ende")
        #expect(try original(of: "Schluss", in: source) == "Schluss")
    }

    @Test func joinedWordCoversBothLineParts() throws {
        #expect(try original(of: "Vertrag", in: "Der Ver-\ntrag endet") == "Ver-\ntrag")
        #expect(try original(of: "Vertrag", in: "Der Ver- \r\n trag endet") == "Ver- \r\n trag")
        #expect(try original(of: "trag", in: "Ver-\ntrag") == "trag")
    }

    @Test func ligatureMapsToTheLigature() throws {
        #expect(try original(of: "finden", in: "Wir ﬁnden es") == "ﬁnden")
        #expect(try original(of: "i", in: "ﬁ") == "ﬁ") // part of a ligature: the whole glyph
    }

    @Test func composedCharactersMapToTheirDecomposedSource() throws {
        #expect(try original(of: "Müller", in: "Herr Mu\u{0308}ller") == "Mu\u{0308}ller")
        #expect(try original(of: "ller", in: "Mu\u{0308}ller") == "ller")
    }

    @Test func droppedCharactersInsideAWordAreCovered() throws {
        #expect(try original(of: "Vertrag", in: "Ver\u{200B}trag") == "Ver\u{200B}trag")
        #expect(try original(of: "Vertrag", in: "Ver\u{00AD}trag") == "Ver\u{00AD}trag")
    }

    @Test func surrogatePairsAndEmptyRanges() throws {
        #expect(try original(of: "Haus", in: "😀 Haus") == "Haus")
        let mapped = TextNormalizer.normalizeMapped("ab")
        #expect(mapped.originalRange(for: NSRange(location: 1, length: 0)) == NSRange(location: 1, length: 0))
        #expect(mapped.originalRange(for: NSRange(location: 2, length: 0)) == NSRange(location: 2, length: 0))
    }

    @Test func outOfBoundsRangeIsClamped() {
        let mapped = TextNormalizer.normalizeMapped("  ab  ")
        #expect(mapped.originalRange(for: NSRange(location: 0, length: 99)) == NSRange(location: 2, length: 2))
        #expect(mapped.originalRange(for: NSRange(location: Int.max - 1, length: 5)).length == 0)
        #expect(mapped.originalRange(for: NSRange(location: NSNotFound, length: 0)).length == 0)
        #expect(mapped.originalRange(for: NSRange(location: -3, length: Int.max)) == NSRange(location: 2, length: 2))
    }

    @Test func normalizedRangeForOriginal() {
        let mapped = TextNormalizer.normalizeMapped("Ver-\ntrag x")
        #expect(mapped.text == "Vertrag x")
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 0, length: 4)) == NSRange(location: 0, length: 3))
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 5, length: 4)) == NSRange(location: 3, length: 4))
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 10, length: 1)) == NSRange(location: 8, length: 1))
    }

    @Test func normalizedRangeForDroppedOrOutOfBoundsIsEmpty() {
        let mapped = TextNormalizer.normalizeMapped("  a\u{200B}b")
        #expect(mapped.text == "ab")
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 0, length: 2)).length == 0) // leading spaces
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 3, length: 1)).length == 0) // ZWSP
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 50, length: 3)).length == 0)
        #expect(mapped.normalizedRange(forOriginal: NSRange(location: 0, length: 0)).length == 0)
    }

    @Test func normalizedRangeRoundTripsWords() {
        let source = "Die Prüfungs-\nergebnisse ﬁnden  sich\nhier."
        let mapped = TextNormalizer.normalizeMapped(source)
        let ns = source as NSString
        for word in ["Die", "ﬁnden", "sich", "hier."] {
            let original = ns.range(of: word)
            let normalized = mapped.normalizedRange(forOriginal: original)
            let expected = TextNormalizer.normalize(word)
            #expect((mapped.text as NSString).substring(with: normalized) == expected, "\(word)")
        }
    }

    /// The binary search in `normalizedRange(forOriginal:)` against a brute-force scan built
    /// from `originalRange` of every single unit.
    @Test func normalizedRangeMatchesBruteForceOnRandomInput() {
        var rng = Seeded(state: 7)
        let pool: [String] = ["a", "B", "ü", "u\u{0308}", "-", "\u{00AD}", "\n", " ", "  ", "\t", "ﬁ", "\u{200B}",
                              "\u{F0B7}", "\u{0301}", "ß", "und", "😀", "\u{0007}", "\u{00A0}", "Ver-\ntrag"]
        for _ in 0..<1_000 {
            let s = (0..<Int.random(in: 0...16, using: &rng)).map { _ in pool.randomElement(using: &rng)! }.joined()
            let mapped = TextNormalizer.normalizeMapped(s)
            let count = (mapped.text as NSString).length
            let sourceLength = (s as NSString).length
            let units = (0..<count).map { mapped.originalRange(for: NSRange(location: $0, length: 1)) }
            for _ in 0..<8 {
                let lower = Int.random(in: 0...max(sourceLength, 0), using: &rng)
                let length = Int.random(in: 0...max(sourceLength - lower, 0), using: &rng)
                let upper = lower + length
                let hits = length == 0 ? [] : units.indices.filter { units[$0].location < upper && units[$0].location + units[$0].length > lower }
                let expected = hits.isEmpty ? NSRange(location: 0, length: 0)
                    : NSRange(location: hits.first!, length: hits.last! - hits.first! + 1)
                #expect(mapped.normalizedRange(forOriginal: NSRange(location: lower, length: length)) == expected,
                        "\(s.debugDescription) \(lower)+\(length)")
            }
        }
    }
}
