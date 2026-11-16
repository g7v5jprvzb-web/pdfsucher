import Foundation
import IndexKit
import SearchKit
import Testing
@testable import ViewerUI

/// 1.4.0 P5: a Word hit on its provisional page (page count still 0) shows that page only, also with „Alle Seiten“.
@Suite("Vorläufige Word-Seite im Raster")
struct ProvisionalWordRowTests {
    @Test func aHitOnAProvisionalPageShowsThatPageOnly() {
        let hit = DocumentHit(url: URL(fileURLWithPath: "/x/brief.docx"), relativePath: "brief.docx", modifiedAt: .distantPast,
                              pageHits: [PageHit(pageIndex: 0, matchCount: 2)], totalMatches: 2, relevance: 1,
                              sourceRoot: URL(fileURLWithPath: "/x"), pageCount: 0, kind: .word)
        for showAll in [false, true] {
            #expect(RowPages.pages(for: hit, showAll: showAll).map(\.pageIndex) == [0])
            #expect(RowPages.count(for: hit, showAll: showAll) == 1)
            #expect(RowPages.position(of: 0, in: hit, showAll: showAll) == 0)
            #expect(RowPages.position(of: 3, in: hit, showAll: showAll) == nil)
        }
        #expect(ViewerText.rowHeader(hit) == "brief.docx (2 Treffer)")
    }
}
