import Testing
import Foundation
import IndexKit
import SearchKit

@Suite("FTSQueryBuilder")
struct FTSQueryBuilderTests {
    private func plan(_ terms: [QueryTerm]) -> FTSPlan? {
        FTSQueryBuilder.plan(for: ParsedQuery(terms: terms))
    }

    @Test func planCasesFromThePlan() {
        #expect(plan([.word("a")]) == .fts("\"a\"", .words))
        #expect(plan([.prefix("ver"), .word("x")]) == .fts("\"ver\"* AND \"x\"", .words))
        #expect(plan([.infix("trag")]) == .fts("\"trag\"", .trigram))
        #expect(plan([.suffix("de")]) == .scanAll)
        #expect(plan([]) == nil)
    }

    @Test func phraseInWordTable() {
        #expect(plan([.phrase(["neuer", "vertrag"])]) == .fts("\"neuer vertrag\"", .words))
    }

    @Test func trigramUsesEveryLongEnoughWord() {
        #expect(plan([.infix("trag"), .word("ende"), .phrase(["neuer", "vertrag"])])
                == .fts("\"trag\" AND \"ende\" AND \"neuer\" AND \"vertrag\"", .trigram))
        // words under 3 characters cannot be trigram-matched; the matcher checks them
        #expect(plan([.suffix("ende"), .word("ab")]) == .fts("\"ende\"", .trigram))
    }

    @Test func shortPartialFallsBackToWordTableWhenPossible() {
        #expect(plan([.infix("ab"), .word("vertrag")]) == .fts("\"vertrag\"", .words))
        #expect(plan([.infix("ab"), .suffix("x")]) == .scanAll)
    }

    @Test func sharpSIsExpandedBecauseFTSDoesNotFoldIt() {
        #expect(plan([.word("strasse")]) == .fts("(\"strasse\" OR \"straße\")", .words))
        // a prefix ending in "s" may stop inside a "ß"
        #expect(plan([.prefix("gross"), .word("x")]) == .fts("(\"gross\"* OR \"groß\"* OR \"grosß\"*) AND \"x\"", .words))
        // the leading "s" of an infix may be the second half of a "ß"; superstrings are dropped
        #expect(plan([.infix("strasse")]) == .fts("(\"trasse\" OR \"traße\")", .trigram))
        #expect(plan([.suffix("sse")]) == .scanAll)
        #expect(plan([.word("sss")]) == .fts("(\"sss\" OR \"sß\" OR \"ßs\")", .words))
    }
}

@Suite("SearchService")
struct SearchServiceTests {
    let root = URL(fileURLWithPath: "/Volumes/Archiv/PDFs", isDirectory: true)

    private func makeIndex() throws -> TestIndex {
        let index = try TestIndex()
        try index.add("a.pdf", pages: ["Der Vertrag gilt.", "nichts", "Vertragsende heute, Vertragsende morgen"])
        try index.add("sub/b.pdf", pages: ["Vertragsende", "Mietvertrag"])
        try index.add("c.pdf", pages: ["Auftrag erteilt", "Abend", "Wir haben Zeit"])
        try index.add("kaputt.pdf", pages: ["Vertrag Vertragsende Auftrag"], status: .error)
        return index
    }

    private func search(_ input: String, partial: Bool = false, in index: TestIndex) throws -> [DocumentHit] {
        try SearchService(index: index, root: root)
            .search(QueryParser.parse(input, partialWords: partial), sort: .fileName)
    }

    @Test func searchEndToEnd() throws {
        let index = try makeIndex()

        let prefix = try search("Vertrag*", in: index)
        #expect(prefix.map(\.relativePath) == ["a.pdf", "sub/b.pdf"])
        #expect(prefix[0].pageHits == [PageHit(pageIndex: 0, matchCount: 1), PageHit(pageIndex: 2, matchCount: 2)])
        #expect(prefix[0].totalMatches == 3)
        #expect(prefix[1].pageHits == [PageHit(pageIndex: 0, matchCount: 1)])
        #expect(prefix[1].url == root.appendingPathComponent("sub/b.pdf"))
        #expect(prefix[0].relevance > 0)

        let infix = try search("*trag*", in: index)
        #expect(Set(infix.map(\.relativePath)) == ["a.pdf", "sub/b.pdf", "c.pdf"])
        #expect(infix.first { $0.relativePath == "sub/b.pdf" }?.pageHits.map(\.pageIndex) == [0, 1])

        let word = try search("Vertrag", in: index)
        #expect(word.map(\.relativePath) == ["a.pdf"])
        #expect(word[0].pageHits == [PageHit(pageIndex: 0, matchCount: 1)])
    }

    @Test func suffixIsCheckedAtWordEnd() throws {
        let index = try TestIndex()
        try index.add("x.pdf", pages: ["Endergebnis", "Vertragsende", "Ende."])
        #expect(try search("*ende", in: index).first?.pageHits.map(\.pageIndex) == [1, 2])
    }

    @Test func partialWordsSwitch() throws {
        let index = try makeIndex()
        #expect(try search("trag", in: index).isEmpty)
        #expect(try search("trag", partial: true, in: index).count == 3)
    }

    @Test func shortPartialUsesScan() throws {
        let index = try makeIndex()
        let hits = try search("*ab*", in: index)
        #expect(hits.map(\.relativePath) == ["c.pdf"])
        #expect(hits[0].pageHits.map(\.pageIndex) == [1, 2])
        #expect(hits[0].relevance == 0)
    }

    @Test func documentsWithErrorStatusAreSkipped() throws {
        let index = try makeIndex()
        #expect(try search("Auftrag", in: index).map(\.relativePath) == ["c.pdf"])
    }

    @Test func diacriticsAndSharpS() throws {
        let index = try TestIndex()
        try index.add("m.pdf", pages: ["Herr Müller", "Straße 5", "STRASSE", "Hauptstraße"])
        #expect(try search("Muller", in: index).first?.pageHits.map(\.pageIndex) == [0])
        #expect(try search("Straße", in: index).first?.pageHits.map(\.pageIndex) == [1, 2])
        #expect(try search("strasse", in: index).first?.pageHits.map(\.pageIndex) == [1, 2])
        #expect(try search("*strasse", in: index).first?.pageHits.map(\.pageIndex) == [1, 2, 3])
        #expect(try search("Haupt*", in: index).first?.pageHits.map(\.pageIndex) == [3])
    }

    @Test func phraseAndHyphenatedWords() throws {
        let index = try TestIndex()
        try index.add("p.pdf", pages: ["ein neuer Vertrag", "Vertrag neuer", "Ihre E-Mail an uns"])
        #expect(try search("\"neuer Vertrag\"", in: index).first?.pageHits.map(\.pageIndex) == [0])
        #expect(try search("E-Mail", in: index).first?.pageHits.map(\.pageIndex) == [2])
        #expect(try search("*e-mail*", in: index).first?.pageHits.map(\.pageIndex) == [2])
    }

    @Test func emptyQueryFindsNothing() throws {
        #expect(try search("   ", in: makeIndex()).isEmpty)
    }

    @Test(arguments: [
        "(a) -b NEAR \"c", "*", "***", "   ", "\"", "\"\"", "AND", "OR NOT", "NEAR(a b)", "a:b", "^x",
        "*a*", "a*b*c", "{x y}", "'", "\u{0}", "a\" OR \"b", "„", "-", "x -", "***a", "a***",
    ])
    func searchNeverThrowsOnHostileInput(_ input: String) throws {
        let index = try makeIndex()
        for partial in [false, true] {
            _ = try search(input, partial: partial, in: index)
        }
    }

    @Test func resultsAreSortedWithTheRequestedMode() throws {
        let hits = try SearchService(index: makeIndex(), root: root)
            .search(QueryParser.parse("*trag*", partialWords: false), sort: .matchCount)
        #expect(hits.map(\.totalMatches) == hits.map(\.totalMatches).sorted(by: >))
    }
}

@Suite("Sorting")
struct SortingTests {
    private func hit(_ path: String, matches: Int, relevance: Double, modified: TimeInterval) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/r/" + path), relativePath: path,
                    modifiedAt: Date(timeIntervalSince1970: modified),
                    pageHits: [PageHit(pageIndex: 0, matchCount: matches)],
                    totalMatches: matches, relevance: relevance,
                    sourceRoot: URL(fileURLWithPath: "/r"), pageCount: 1)
    }

    private var hits: [DocumentHit] {
        [
            hit("z/file10.pdf", matches: 3, relevance: 1.0, modified: 300),
            hit("a/file2.pdf", matches: 3, relevance: 5.0, modified: 100),
            hit("b/Alpha.pdf", matches: 7, relevance: 2.0, modified: 500),
            hit("a/beta.pdf", matches: 1, relevance: 9.0, modified: 200),
            hit("file2.pdf", matches: 3, relevance: 3.0, modified: 400),
        ]
    }

    private func order(_ mode: SortMode) -> [String] { sortHits(hits, by: mode).map(\.relativePath) }

    @Test func matchCount() {
        // count desc, then file name (natural), then relative path
        #expect(order(.matchCount) == ["b/Alpha.pdf", "a/file2.pdf", "file2.pdf", "z/file10.pdf", "a/beta.pdf"])
    }

    @Test func relevance() {
        #expect(order(.relevance) == ["a/beta.pdf", "a/file2.pdf", "file2.pdf", "b/Alpha.pdf", "z/file10.pdf"])
    }

    @Test func modifiedDate() {
        #expect(order(.modifiedDate) == ["b/Alpha.pdf", "file2.pdf", "z/file10.pdf", "a/beta.pdf", "a/file2.pdf"])
    }

    @Test func fileName() {
        #expect(order(.fileName) == ["b/Alpha.pdf", "a/beta.pdf", "a/file2.pdf", "file2.pdf", "z/file10.pdf"])
    }

    @Test func folder() {
        // root folder ("") first, then a, b, z; within a folder by file name
        #expect(order(.folder) == ["file2.pdf", "a/beta.pdf", "a/file2.pdf", "b/Alpha.pdf", "z/file10.pdf"])
    }

    @Test func tiesFallBackToRelativePath() {
        let same = [hit("b.pdf", matches: 1, relevance: 1, modified: 1), hit("a.pdf", matches: 1, relevance: 1, modified: 1)]
        for mode in SortMode.allCases {
            #expect(sortHits(same, by: mode).map(\.relativePath) == ["a.pdf", "b.pdf"])
        }
    }
}

@Suite("SearchService review cases")
struct SearchServiceReviewTests {
    let root = URL(fileURLWithPath: "/r", isDirectory: true)

    private func pages(_ input: String, _ index: TestIndex) throws -> [String: [Int]] {
        let hits = try SearchService(index: index, root: root)
            .search(QueryParser.parse(input, partialWords: false), sort: .fileName)
        return Dictionary(uniqueKeysWithValues: hits.map { ($0.relativePath, $0.pageHits.map(\.pageIndex)) })
    }

    @Test func sharpSInsidePartialTermsIsFound() throws {
        let index = try TestIndex()
        try index.add("a.pdf", pages: ["Straße", "Größe", "Klasse", "Wir aßen den Vertrag", "draußen", "Großartig", "Er aß den Vertrag"])
        #expect(try pages("*ße", index) == ["a.pdf": [0, 1, 2]])  // "Klasse" folds to the same letters
        #expect(try pages("aß *trag*", index) == ["a.pdf": [6]])
        #expect(try pages("Stras*", index) == ["a.pdf": [0]])
        #expect(try pages("gros*", index) == ["a.pdf": [1, 5]])
        #expect(try pages("*sen", index) == ["a.pdf": [3, 4]])
        #expect(try pages("*rasse*", index) == ["a.pdf": [0]])
    }

    @Test func termWithTooManyVariantsIsLeftToTheMatcher() {
        let many = String(repeating: "ss", count: 5)
        #expect(FTSQueryBuilder.plan(for: ParsedQuery(terms: [.word(many), .word("vertrag")])) == .fts("\"vertrag\"", .words))
    }

    @Test func noTextAndErrorDocumentsAreSkipped() throws {
        let index = try TestIndex()
        try index.add("ok.pdf", pages: ["Vertrag"])
        try index.add("scan.pdf", pages: ["Vertrag"], status: .noText)
        try index.add("bad.pdf", pages: ["Vertrag"], status: .error)
        #expect(try pages("Vertrag", index) == ["ok.pdf": [0]])
    }

    @Test func relevanceIsTheNegatedSumOfBm25() throws {
        struct Fixed: IndexReading {
            func documents() throws -> [StoredDocument] {
                [StoredDocument(id: 1, relativePath: "a.pdf", fileSize: 1, modifiedAt: .distantPast, pageCount: 2, status: .ok)]
            }
            func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] {
                [RawPageMatch(docId: 1, pageIndex: 1, bm25: -2.5, text: "Vertrag"),
                 RawPageMatch(docId: 1, pageIndex: 0, bm25: -1.0, text: "Vertrag Vertrag")]
            }
            func allPages() throws -> [RawPageMatch] { [] }
        }
        let hit = try #require(try SearchService(index: Fixed(), root: root)
            .search(QueryParser.parse("Vertrag", partialWords: false), sort: .relevance).first)
        #expect(hit.relevance == 3.5)
        #expect(hit.pageHits == [PageHit(pageIndex: 0, matchCount: 2), PageHit(pageIndex: 1, matchCount: 1)])
        #expect(hit.totalMatches == 3)
    }

    @Test func folderSortKeepsSubfoldersAfterTheirParent() {
        func hit(_ p: String) -> DocumentHit {
            DocumentHit(url: URL(fileURLWithPath: "/r/" + p), relativePath: p, modifiedAt: .distantPast,
                        pageHits: [], totalMatches: 0, relevance: 0,
                        sourceRoot: URL(fileURLWithPath: "/r"), pageCount: 0)
        }
        let paths = ["a b/x.pdf", "a/sub/x.pdf", "a-b/x.pdf", "a/x.pdf", "x.pdf"]
        #expect(sortHits(paths.map(hit), by: .folder).map(\.relativePath)
                == ["x.pdf", "a/x.pdf", "a/sub/x.pdf", "a b/x.pdf", "a-b/x.pdf"])
    }

    @Test func ftsErrorFallsBackToScanningAllPages() throws {
        struct Failing: IndexReading {
            func documents() throws -> [StoredDocument] {
                [StoredDocument(id: 1, relativePath: "a.pdf", fileSize: 1, modifiedAt: .distantPast, pageCount: 1, status: .ok)]
            }
            func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] {
                throw SQLiteError(code: 1, message: "fts5: syntax error")
            }
            func allPages() throws -> [RawPageMatch] {
                [RawPageMatch(docId: 1, pageIndex: 0, bm25: 0, text: "Der Vertrag")]
            }
        }
        let hits = try SearchService(index: Failing(), root: root)
            .search(QueryParser.parse("Vertrag", partialWords: false), sort: .matchCount)
        #expect(hits.map(\.relativePath) == ["a.pdf"])
    }

    @Test func otherIndexErrorsAreReported() {
        struct Broken: IndexReading {
            struct Gone: Error {}
            func documents() throws -> [StoredDocument] { throw Gone() }
            func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] { throw Gone() }
            func allPages() throws -> [RawPageMatch] { throw Gone() }
        }
        #expect(throws: Broken.Gone.self) {
            try SearchService(index: Broken(), root: root)
                .search(QueryParser.parse("Vertrag", partialWords: false), sort: .matchCount)
        }
    }

    /// Many candidate pages must still be verified quickly (spec §9: < 200 ms for
    /// 20,000 pages, measured in release builds; this debug-build bound only catches
    /// regressions such as losing the parallel check).
    @Test func checkingManyCandidatePagesIsFast() throws {
        struct Many: IndexReading {
            let page = String(repeating: "Die Vertragsparteien vereinbaren über die Lieferung abc. ", count: 50)
            func documents() throws -> [StoredDocument] {
                (0..<200).map { StoredDocument(id: Int64($0), relativePath: "d\($0).pdf", fileSize: 1,
                                               modifiedAt: .distantPast, pageCount: 20, status: .ok) }
            }
            func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] {
                (0..<4_000).map { RawPageMatch(docId: Int64($0 / 20), pageIndex: $0 % 20, bm25: -1, text: page) }
            }
            func allPages() throws -> [RawPageMatch] { try match("", in: .words) }
        }
        let service = SearchService(index: Many(), root: root)
        let clock = ContinuousClock()
        var hits: [DocumentHit] = []
        let elapsed = try clock.measure {
            hits = try service.search(QueryParser.parse("ver*", partialWords: false), sort: .matchCount)
        }
        #expect(hits.count == 200)
        #expect(hits[0].totalMatches == 20 * 100)
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}

/// 1.1 §5: a search over very many pages reports the documents of its first batch early.
@Suite("Search in batches")
struct SearchBatchTests {
    struct Corpus: IndexReading {
        let pages: [RawPageMatch]
        let documentCount: Int
        init(docs: Int, pagesPerDoc: Int) {
            pages = (0..<docs * pagesPerDoc).map { i in
                RawPageMatch(docId: Int64(i / pagesPerDoc), pageIndex: i % pagesPerDoc, bm25: -1,
                             text: i % 3 == 0 ? "Der Vertrag gilt" : "Die Vertragsdauer endet")
            }
            documentCount = docs
        }
        init(pages: [RawPageMatch], documentCount: Int) {
            self.pages = pages
            self.documentCount = documentCount
        }
        func documents() throws -> [StoredDocument] {
            (0..<documentCount).map { StoredDocument(id: Int64($0), relativePath: "d\($0).pdf", fileSize: 1,
                                                       modifiedAt: .distantPast, pageCount: 10, status: .ok) }
        }
        func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] { pages }
        func allPages() throws -> [RawPageMatch] { pages }
    }

    @Test func firstBatchIsReportedAndIsASubsetOfTheFinalResult() throws {
        let service = SearchService(index: Corpus(docs: 100, pagesPerDoc: 10), root: URL(fileURLWithPath: "/r"))
        let q = QueryParser.parse("vertrag*", partialWords: false)
        let partials = Locked([[DocumentHit]]())
        let final = try service.search(q, sort: .matchCount, batchSize: 95) { partial in partials.mutate { $0.append(partial) } }
        let first = try #require(partials.value.first)
        #expect(partials.value.count == 1)
        // Only complete documents (95 pages = 9 full documents of 10 pages).
        #expect(first.count == 9)
        let finalByID = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
        for hit in first { #expect(finalByID[hit.id] == hit) }
        #expect(final.count == 100)
        #expect(final == (try service.search(q, sort: .matchCount)))
    }

    /// Review: one large document filling the first batch must not cost the early result.
    @Test func earlyResultRetriedWhenFirstBatchIsOneDocument() throws {
        let big = (0..<150).map { RawPageMatch(docId: 0, pageIndex: $0, bm25: -1, text: "Der Vertrag gilt") }
        let rest = (1..<20).flatMap { d in (0..<10).map { RawPageMatch(docId: Int64(d), pageIndex: $0, bm25: -1, text: "Der Vertrag gilt") } }
        let corpus = Corpus(pages: big + rest, documentCount: 20)
        let service = SearchService(index: corpus, root: URL(fileURLWithPath: "/r"))
        let partials = Locked([[DocumentHit]]())
        let final = try service.search(QueryParser.parse("vertrag", partialWords: false), sort: .fileName, batchSize: 95) { p in partials.mutate { $0.append(p) } }
        #expect(partials.value.count == 1)
        #expect(partials.value.first?.map(\.relativePath).contains("d0.pdf") == true)
        #expect(final.count == 20)
    }

    /// Review: short infix terms read every page; they report early documents too.
    @Test func fullScanReportsEarlyToo() throws {
        let service = SearchService(index: Corpus(docs: 100, pagesPerDoc: 10), root: URL(fileURLWithPath: "/r"))
        let partials = Locked(0)
        let final = try service.search(QueryParser.parse("*er*", partialWords: false), sort: .matchCount, batchSize: 95) { _ in partials.mutate { $0 += 1 } }
        #expect(partials.value == 1)
        #expect(final.count == 100)
    }

    /// Audit 2026-11-15: after the early result (and without `onPartial`) each batch is checked as it comes
    /// instead of being kept until the end. Tiny batches, documents spanning batches and both modes must
    /// still give exactly the result of one big batch.
    @Test(arguments: ["vertrag*", "*er*", "vertrag"])
    func batchByBatchCheckingGivesTheSameResult(_ query: String) throws {
        let service = SearchService(index: Corpus(docs: 40, pagesPerDoc: 7), root: URL(fileURLWithPath: "/r"))
        let q = QueryParser.parse(query, partialWords: false)
        let reference = try service.search(q, sort: .matchCount, batchSize: 100_000)
        #expect(!reference.isEmpty)
        let partials = Locked(0)
        let withEarly = try service.search(q, sort: .matchCount, batchSize: 5) { _ in partials.mutate { $0 += 1 } }
        let withoutEarly = try service.search(q, sort: .matchCount, batchSize: 5)
        #expect(partials.value == 1)
        #expect(withEarly == reference)
        #expect(withoutEarly == reference)
    }

    @Test func smallResultsReportNoPartial() throws {
        let service = SearchService(index: Corpus(docs: 3, pagesPerDoc: 10), root: URL(fileURLWithPath: "/r"))
        let partials = Locked(0)
        _ = try service.search(QueryParser.parse("vertrag", partialWords: false), sort: .matchCount, batchSize: 95) { _ in partials.mutate { $0 += 1 } }
        #expect(partials.value == 0)
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
