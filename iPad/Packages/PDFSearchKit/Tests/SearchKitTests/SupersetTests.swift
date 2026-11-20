import Testing
import Foundation
import IndexKit
import SearchKit

/// The plan's core rule: FTS5 only narrows candidate pages, `PageMatcher` decides.
/// So the service must find exactly the pages a matcher-only scan finds.
@Suite("FTS candidates are a superset of matcher hits")
struct SupersetTests {
    let root = URL(fileURLWithPath: "/r", isDirectory: true)

    private func servicePages(_ q: ParsedQuery, _ index: TestIndex) throws -> Set<Int> {
        Set(try SearchService(index: index, root: root).search(q, sort: .fileName).flatMap { $0.pageHits.map(\.pageIndex) })
    }

    private func matcherPages(_ q: ParsedQuery, _ pages: [String]) -> Set<Int> {
        Set(pages.indices.filter { PageMatcher(q).matchCount(in: pages[$0]) != nil })
    }

    @Test(arguments: [
        ("Чайковский", "Чайковский"), ("Ёлка", "ёлка"), ("ΆΣΤΡΑ", "άστρα"), ("λόγος", "*όγος"),
        ("Москва́", "москва"), ("Ἀθῆναι", "αθηναι*"),
    ])
    func greekAndCyrillicWithDiacritics(_ page: String, _ input: String) throws {
        let index = try TestIndex()
        try index.add("a.pdf", pages: [page])
        let q = QueryParser.parse(input, partialWords: false)
        #expect(matcherPages(q, [page]) == [0])
        #expect(try servicePages(q, index) == [0])
    }

    @Test func manySharpSSpellingsAtAnOpenEdge() throws {
        let page = "ASS.ſrßssẞ ø"
        let index = try TestIndex()
        try index.add("a.pdf", pages: [page])
        let q = QueryParser.parse("*ßssẞ ø", partialWords: false)
        #expect(try servicePages(q, index) == matcherPages(q, [page]))
    }

    /// Final review (Task 5.6): letters that Swift folds differently than FTS5's unicode61 (ǿ → ø,
    /// ǣ → æ) and combining marks that unicode61 treats as word breaks must still be found.
    @Test(arguments: [("Die Ǿresund-Brücke", "Ǿresund"), ("Die Ǿresund-Brücke", "øresund"),
                      ("König Ǣthelred", "Ǣthelred"), ("Die Øresund-Brücke", "øresund")])
    func lettersFoldedDifferentlyByFTS(page: String, input: String) throws {
        let index = try TestIndex()
        try index.add("a.pdf", pages: [page])
        let q = QueryParser.parse(input, partialWords: false)
        #expect(!matcherPages(q, [page]).isEmpty)
        #expect(try servicePages(q, index) == matcherPages(q, [page]), "query \(input)")
    }

    /// Known limitation (docs/decisions.md): folding removes a combining mark such as U+0305 from the
    /// query term before the FTS query is built, while unicode61 splits the indexed word at it.
    @Test func combiningMarkInsideWordKnownLimitation() throws {
        let page = "Wert x\u{0305}y gilt"
        let index = try TestIndex()
        try index.add("a.pdf", pages: [page])
        let q = QueryParser.parse("x\u{0305}y", partialWords: false)
        let found = try servicePages(q, index)
        withKnownIssue("combining mark removed by folding, word split by unicode61") {
            #expect(found == matcherPages(q, [page]))
        }
    }

    @Test func randomTextsAndQueries() throws {
        var rng = SplitMix64(seed: 0x5EA2C4)
        // no ligatures: index text is normalized by Phase 1 (ﬁ → fi) before FTS5 sees it
        let alphabet = Array("aAbsSßẞeEéÉüÜoöÖ  -.,ÆæИиЙйЁёΑάΆσςΣ1ǾǿǢǣøʒ") 
        func word(_ n: Int) -> String { String((0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }) }
        var pages: [String] = []
        for _ in 0..<300 { pages.append((0..<6).map { _ in word(Int(1 + rng.next() % 6)) }.joined(separator: " ")) }
        let index = try TestIndex()
        for (i, chunk) in stride(from: 0, to: pages.count, by: 20).enumerated() {
            try index.add("d\(i).pdf", pages: Array(pages[chunk..<min(chunk + 20, pages.count)]))
        }
        for _ in 0..<300 {
            // take a slice of a random page as query, decorate with wildcards
            let source = pages[Int(rng.next() % UInt64(pages.count))]
            let chars = Array(source)
            let a = Int(rng.next() % UInt64(chars.count)), b = min(chars.count, a + 1 + Int(rng.next() % 6))
            var input = String(chars[a..<b])
            switch rng.next() % 4 { case 0: input = "*" + input + "*"; case 1: input += "*"; case 2: input = "*" + input; default: break }
            let q = QueryParser.parse(input, partialWords: rng.next() % 2 == 0)
            guard !q.isEmpty else { continue }
            let expected = Set(pages.indices.filter { PageMatcher(q).matchCount(in: pages[$0]) != nil })
            let hits = try SearchService(index: index, root: root).search(q, sort: .fileName)
            let got = Set(hits.flatMap { hit in
                hit.pageHits.map { Int(hit.relativePath.dropFirst().dropLast(4))! * 20 + $0.pageIndex }
            })
            #expect(got == expected, "query \(input.debugDescription)")
        }
    }
}

/// Small deterministic generator so failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
