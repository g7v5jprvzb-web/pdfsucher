import Testing
import Foundation
import OutputKit
import SearchKit
@testable import ViewerUI

private func doc(_ name: String, pages: [Int]) -> DocumentHit {
    DocumentHit(url: URL(fileURLWithPath: "/docs/\(name)"), relativePath: name, modifiedAt: .distantPast,
                pageHits: pages.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: pages.count, relevance: 0,
                sourceRoot: URL(fileURLWithPath: "/docs"), pageCount: 0)
}

private func ref(_ hit: DocumentHit, _ page: Int) -> PageRef { PageRef(url: hit.url, pageIndex: page) }

@Suite("Copy")
struct CopyTests {
    @Test func summaryText() {
        let hits = (0..<3).map { doc("d\($0).pdf", pages: Array(0..<7)) }
        #expect(ViewerText.summary(hits: hits) == "Gefunden in 3 Dokumenten, 21 Seiten")
        #expect(ViewerText.summary(hits: [doc("a.pdf", pages: [4])]) == "Gefunden in 1 Dokument, 1 Seite")
        #expect(ViewerText.summary(hits: []) == "Keine Treffer")
    }

    @Test func summaryUsesGermanGrouping() {
        let hits = (0..<1200).map { doc("d\($0).pdf", pages: [0]) }
        #expect(ViewerText.summary(hits: hits) == "Gefunden in 1.200 Dokumenten, 1.200 Seiten")
    }

    @Test func indexStatusText() {
        #expect(ViewerText.indexStatus(.none) == nil)
        #expect(ViewerText.indexStatus(.building(folder: 1, folders: 1, done: 412, total: 3180)) == "Index: wird aufgebaut (412/3.180)")
        #expect(ViewerText.indexStatus(.upToDate) == "Index: aktuell")
        #expect(ViewerText.indexStatus(.problems(failed: ["a.pdf"], noText: [])) == "Index: aktuell · 1 Datei nicht lesbar")
        #expect(ViewerText.indexStatus(.problems(failed: ["a.pdf"], noText: ["b.pdf", "c.pdf"])) == "Index: aktuell · 1 Datei nicht lesbar · 2 Dateien ohne erkannten Text")   // 1.2 §8
        #expect(ViewerText.indexStatus(.unreachable) == "Ordner nicht erreichbar · Suche im gespeicherten Index")
        // 1.3 Part B: the layout phase of Word/PowerPoint documents.
        #expect(ViewerText.indexStatus(.layingOut(folder: 1, folders: 1, done: 12, total: 340)) == "Word/PowerPoint 12/340")
        #expect(ViewerText.indexStatus(.layingOut(folder: 1, folders: 2, done: 12, total: 340)) == "Word/PowerPoint Ordner 1/2: 12/340")
        #expect(ViewerText.indexStatus(.layingOut(folder: 1, folders: 1, done: 1200, total: 3400)) == "Word/PowerPoint 1.200/3.400")
    }

    @Test func selectionText() {
        #expect(ViewerText.selection(count: 0) == "Keine Seiten ausgewählt")
        #expect(ViewerText.selection(count: 1) == "1 Seite ausgewählt")
        #expect(ViewerText.selection(count: 6) == "6 Seiten ausgewählt")
    }

    @Test func rowHeaderText() {
        #expect(ViewerText.rowHeader(DocumentHit(url: URL(fileURLWithPath: "/x/vertrag_2024.pdf"), relativePath: "sub/vertrag_2024.pdf",
                                                 modifiedAt: .distantPast, pageHits: [PageHit(pageIndex: 0, matchCount: 12)], totalMatches: 12, relevance: 0,
                                                 sourceRoot: URL(fileURLWithPath: "/x"), pageCount: 0))
                == "vertrag_2024.pdf (12 Treffer)")
    }

    @Test func tilePlaceholderText() {
        #expect(ViewerText.tilePlaceholder(fileExists: false, folderUnreachable: false) == "Datei nicht mehr vorhanden")
        #expect(ViewerText.tilePlaceholder(fileExists: false, folderUnreachable: true) == "Ordner nicht erreichbar")
        #expect(ViewerText.tilePlaceholder(fileExists: true, folderUnreachable: false) == "Vorschau nicht verfügbar")
    }

    @Test func noResultsText() {
        #expect(ViewerText.noResults(query: "Vertrag") == "Keine Seite enthält „Vertrag“.")
    }

    @Test func sortLabelsAreGermanAndComplete() {
        #expect(SortMode.allCases.map(ViewerText.sortLabel) == ["Trefferanzahl", "Relevanz", "Änderungsdatum", "Dateiname", "Ordner"])
    }
}

@Suite("FocusNavigator")
struct FocusNavigatorTests {
    let a = doc("a.pdf", pages: [0, 2, 5, 9])
    let b = doc("b.pdf", pages: [1, 3])
    let c = doc("c.pdf", pages: [7, 8, 11])
    var hits: [DocumentHit] { [a, b, c] }

    @Test func keyboardFocusMoves() {
        // right moves along the row, stays at the row end
        #expect(FocusNavigator.next(from: ref(a, 0), direction: .right, hits: hits) == ref(a, 2))
        #expect(FocusNavigator.next(from: ref(a, 9), direction: .right, hits: hits) == ref(a, 9))
        // left stays at the row start
        #expect(FocusNavigator.next(from: ref(b, 1), direction: .left, hits: hits) == ref(b, 1))
        #expect(FocusNavigator.next(from: ref(b, 3), direction: .left, hits: hits) == ref(b, 1))
        // down keeps the column, clamped to the shorter row
        #expect(FocusNavigator.next(from: ref(a, 9), direction: .down, hits: hits) == ref(b, 3))
        #expect(FocusNavigator.next(from: ref(a, 2), direction: .down, hits: hits) == ref(b, 3))
        #expect(FocusNavigator.next(from: ref(a, 0), direction: .down, hits: hits) == ref(b, 1))
        // up from the clamped row lands on the same column above
        #expect(FocusNavigator.next(from: ref(c, 11), direction: .up, hits: hits) == ref(b, 3))
        // top and bottom rows stay
        #expect(FocusNavigator.next(from: ref(a, 5), direction: .up, hits: hits) == ref(a, 5))
        #expect(FocusNavigator.next(from: ref(c, 8), direction: .down, hits: hits) == ref(c, 8))
    }

    @Test func startsAtFirstTileWhenNothingOrUnknownFocused() {
        #expect(FocusNavigator.next(from: nil, direction: .right, hits: hits) == ref(a, 0))
        let stranger = PageRef(url: URL(fileURLWithPath: "/elsewhere.pdf"), pageIndex: 3)
        #expect(FocusNavigator.next(from: stranger, direction: .down, hits: hits) == ref(a, 0))
        #expect(FocusNavigator.next(from: PageRef(url: a.url, pageIndex: 1), direction: .down, hits: hits) == ref(a, 0))
    }

    @Test func emptyHitsGiveNil() {
        #expect(FocusNavigator.next(from: nil, direction: .down, hits: []) == nil)
        #expect(FocusNavigator.step(from: nil, by: 1, hits: []) == nil)
        #expect(FocusNavigator.next(from: nil, direction: .down, hits: [doc("e.pdf", pages: [])]) == nil)
    }

    @Test func stepWalksAllHitPagesInGridOrder() {
        #expect(FocusNavigator.step(from: ref(a, 9), by: 1, hits: hits) == ref(b, 1))
        #expect(FocusNavigator.step(from: ref(b, 1), by: -1, hits: hits) == ref(a, 9))
        #expect(FocusNavigator.step(from: ref(c, 11), by: 1, hits: hits) == ref(c, 11))
        #expect(FocusNavigator.step(from: ref(a, 0), by: -1, hits: hits) == ref(a, 0))
        #expect(FocusNavigator.step(from: nil, by: 1, hits: hits) == ref(a, 0))
    }

    @Test func canStepReportsEnds() {
        #expect(!FocusNavigator.canStep(from: ref(a, 0), by: -1, hits: hits))
        #expect(FocusNavigator.canStep(from: ref(a, 0), by: 1, hits: hits))
        #expect(!FocusNavigator.canStep(from: ref(c, 11), by: 1, hits: hits))
        #expect(!FocusNavigator.canStep(from: nil, by: 1, hits: []))
    }

    @Test func containsOnlyCurrentHitPages() {
        #expect(FocusNavigator.contains(ref(b, 3), in: hits))
        #expect(!FocusNavigator.contains(PageRef(url: b.url, pageIndex: 2), in: hits))
        #expect(!FocusNavigator.contains(nil, in: hits))
    }

    @Test func tileIDIsUniquePerDocumentAndPage() {
        #expect(FocusNavigator.tileID(ref(a, 2)) != FocusNavigator.tileID(ref(b, 2)))
        #expect(FocusNavigator.tileID(ref(a, 2)) == FocusNavigator.tileID(PageRef(url: a.url, pageIndex: 2)))
    }
}
