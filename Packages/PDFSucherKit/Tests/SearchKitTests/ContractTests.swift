import Testing
import Foundation
import SearchKit // deliberately not @testable: proves the public inits (R6) are visible cross-module

@Suite("SearchKit public contract")
struct SearchKitContractTests {
    @Test func publicInitsAreVisible() {
        let hit = DocumentHit(
            url: URL(fileURLWithPath: "/root/sub/a.pdf"),
            relativePath: "sub/a.pdf",
            modifiedAt: Date(timeIntervalSince1970: 0),
            pageHits: [PageHit(pageIndex: 0, matchCount: 2)],
            totalMatches: 2,
            relevance: 1.5,
            sourceRoot: URL(fileURLWithPath: "/root"),
            pageCount: 4
        )
        #expect(hit.id == "/root/sub/a.pdf")
    }

    @Test func sortModeOrderAndRawValues() {
        #expect(SortMode.allCases == [.matchCount, .relevance, .modifiedDate, .fileName, .folder])
        #expect(SortMode.allCases.map(\.rawValue) == ["matchCount", "relevance", "modifiedDate", "fileName", "folder"])
    }

    @Test func parsedQueryIsEmpty() {
        #expect(ParsedQuery(terms: []).isEmpty)
        let q = ParsedQuery(terms: [.word("a"), .prefix("b"), .suffix("c"), .infix("d"), .phrase(["e", "f"])])
        #expect(!q.isEmpty)
    }
}
