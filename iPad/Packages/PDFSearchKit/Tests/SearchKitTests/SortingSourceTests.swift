import Foundation
import Testing
@testable import SearchKit

/// Spec 1.1 §4: hits from several sources are merged and sorted together; `id` is the full path.
@Suite("Sorting over several sources")
struct SortingSourceTests {
    private func hit(_ root: String, _ path: String, matches: Int = 1, relevance: Double = 0,
                     days: Double = 0) -> DocumentHit {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return DocumentHit(url: rootURL.appendingPathComponent(path), relativePath: path,
                           modifiedAt: Date(timeIntervalSince1970: days * 86_400),
                           pageHits: [PageHit(pageIndex: 0, matchCount: matches)], totalMatches: matches,
                           relevance: relevance, sourceRoot: rootURL, pageCount: 3)
    }

    @Test func sameNameInTwoFoldersAreTwoRows() {
        let a = hit("/a", "x.pdf"), b = hit("/b", "x.pdf")
        #expect(a.id == "/a/x.pdf")
        #expect(b.id == "/b/x.pdf")
        #expect(a.id != b.id)
        for mode in SortMode.allCases {
            #expect(sortHits([b, a], by: mode).map(\.id) == ["/a/x.pdf", "/b/x.pdf"], "\(mode)")
            #expect(sortHits([a, b], by: mode).map(\.id) == ["/a/x.pdf", "/b/x.pdf"], "\(mode)")
        }
    }

    @Test func folderSortGroupsBySource() {
        let hits = [hit("/b", "a.pdf"), hit("/a", "z/z.pdf"), hit("/b", "sub/c.pdf"), hit("/a", "b.pdf")]
        #expect(sortHits(hits, by: .folder).map(\.id) == ["/a/b.pdf", "/a/z/z.pdf", "/b/a.pdf", "/b/sub/c.pdf"])
    }

    @Test func allFiveSortsOverMergedHits() {
        let hits = [
            hit("/a", "eins.pdf", matches: 3, relevance: 1, days: 5),
            hit("/b", "zwei.pdf", matches: 9, relevance: 2, days: 1),
            hit("/a", "sub/drei.pdf", matches: 1, relevance: 9, days: 3),
            hit("/b", "vier.pdf", matches: 3, relevance: 4, days: 9),
            hit("/c/datei.pdf", "datei.pdf", matches: 5, relevance: 3, days: 7),
            hit("/b", "sub/fünf.pdf", matches: 2, relevance: 5, days: 2),
        ]
        let ids = { (m: SortMode) in sortHits(hits, by: m).map { $0.url.lastPathComponent } }
        #expect(ids(.matchCount) == ["zwei.pdf", "datei.pdf", "eins.pdf", "vier.pdf", "fünf.pdf", "drei.pdf"])
        #expect(ids(.relevance) == ["drei.pdf", "fünf.pdf", "vier.pdf", "datei.pdf", "zwei.pdf", "eins.pdf"])
        #expect(ids(.modifiedDate) == ["vier.pdf", "datei.pdf", "eins.pdf", "drei.pdf", "fünf.pdf", "zwei.pdf"])
        #expect(ids(.fileName) == ["datei.pdf", "drei.pdf", "eins.pdf", "fünf.pdf", "vier.pdf", "zwei.pdf"])
        #expect(ids(.folder) == ["eins.pdf", "drei.pdf", "vier.pdf", "zwei.pdf", "fünf.pdf", "datei.pdf"])
    }
}
