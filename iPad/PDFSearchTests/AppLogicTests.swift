import Foundation
import IndexKit
import SearchKit
import Testing
@testable import PDFSearch

private func hit(_ path: String, kind: DocumentKind = .pdf, matches: Int = 1, date: TimeInterval = 0,
                 root: URL = URL(fileURLWithPath: "/tmp/ort")) -> DocumentHit {
    DocumentHit(url: root.appendingPathComponent(path), relativePath: path, modifiedAt: Date(timeIntervalSince1970: date),
                pageHits: [PageHit(pageIndex: 0, matchCount: matches)], totalMatches: matches, relevance: 1,
                sourceRoot: root, pageCount: 1, kind: kind)
}

@Suite("Suchbereich („Ganzes iPad“, Ordnerauswahl, Typ)")
struct SearchScopeTests {
    let placeA = UUID(), placeB = UUID()
    let hits = [hit("Rechnungen/a.pdf"), hit("Rechnungen/Alt/b.pdf"), hit("Fotos/c.jpg", kind: .image), hit("d.pdf"),
                hit("Rechnungen2/e.pdf")]

    @Test func wholeIPadIgnoresTheTreeSelection() {
        let selection = FolderSelection(placeID: placeA, relativePath: "Rechnungen")
        #expect(SearchScope.effectiveSelection(selection, wholeIPad: true) == nil)
        #expect(SearchScope.effectiveSelection(selection, wholeIPad: false) == selection)
    }

    @Test func noSelectionCoversEveryPlace() {
        #expect(SearchScope.includes(place: placeA, selection: nil))
        #expect(SearchScope.includes(place: placeB, selection: nil))
    }

    @Test func selectionKeepsItsOwnPlaceOnly() {
        let selection = FolderSelection(placeID: placeA, relativePath: "")
        #expect(SearchScope.includes(place: placeA, selection: selection))
        #expect(!SearchScope.includes(place: placeB, selection: selection))
        #expect(SearchScope.filter(hits, kind: .all, selection: selection).count == hits.count)
    }

    @Test func folderSelectionKeepsFilesBelowIt() {
        let selection = FolderSelection(placeID: placeA, relativePath: "Rechnungen")
        let paths = SearchScope.filter(hits, kind: .all, selection: selection).map(\.relativePath)
        // „Rechnungen2“ only shares the prefix and stays out.
        #expect(paths == ["Rechnungen/a.pdf", "Rechnungen/Alt/b.pdf"])
    }

    @Test func kindFilter() {
        #expect(SearchScope.filter(hits, kind: .jpeg, selection: nil).map(\.relativePath) == ["Fotos/c.jpg"])
        #expect(SearchScope.filter(hits, kind: .pdf, selection: nil).count == 4)
        #expect(SearchScope.filter(hits, kind: .all, selection: nil).count == 5)
    }
}

@Suite("Sortierung")
struct SortTests {
    @Test func modesMapToTheSearchSort() {
        #expect(ResultSort.matchCount.mode == .matchCount)
        #expect(ResultSort.name.mode == .fileName)
        #expect(ResultSort.date.mode == .modifiedDate)
        #expect(ResultSort.allCases.map(\.title) == ["Trefferanzahl", "Name", "Datum"])
    }

    @Test func sortsAsShown() {
        let hits = [hit("b.pdf", matches: 2, date: 300), hit("a.pdf", matches: 5, date: 100), hit("c.jpg", kind: .image, matches: 1, date: 200)]
        #expect(sortHits(hits, by: ResultSort.matchCount.mode).map(\.relativePath) == ["a.pdf", "b.pdf", "c.jpg"])
        #expect(sortHits(hits, by: ResultSort.name.mode).map(\.relativePath) == ["a.pdf", "b.pdf", "c.jpg"])
        #expect(sortHits(hits, by: ResultSort.date.mode).map(\.relativePath) == ["b.pdf", "c.jpg", "a.pdf"])
    }
}

@Suite("Freigegebene Orte (Bookmarks)")
struct PlaceStorageTests {
    private func defaults() -> UserDefaults {
        let name = "PDFSearchTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func bookmarkRoundTripResolvesTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let place = try PlaceStorage.makePlace(from: folder)
        #expect(place.bookmark != nil)
        #expect(place.name == folder.lastPathComponent)

        let store = defaults()
        PlaceStorage.save([place], to: store)
        let loaded = PlaceStorage.load(from: store)
        #expect(loaded == [place])

        let resolved = PlaceStorage.resolve(try #require(loaded.first))
        let runtime = try #require(resolved.runtime)
        #expect(runtime.url.standardizedFileURL.resolvingSymlinksInPath() == folder.standardizedFileURL.resolvingSymlinksInPath())
        #expect(runtime.store != nil)
        try? runtime.store?.deleteIndex()
    }

    @Test func builtInPlaceIsNotSaved() {
        let store = defaults()
        PlaceStorage.save([SharedPlace(id: SharedPlace.builtInID, name: "Auf diesem iPad", bookmark: nil)], to: store)
        #expect(PlaceStorage.load(from: store).isEmpty)
    }

    @Test func damagedBookmarkReportsAnError() {
        let broken = SharedPlace(id: UUID(), name: "Kaputt", bookmark: Data("kein Bookmark".utf8))
        let resolved = PlaceStorage.resolve(broken)
        #expect(resolved.runtime == nil)
        #expect(resolved.error != nil)
    }

    @Test func emptyDefaultsHaveNoPlaces() {
        #expect(PlaceStorage.load(from: defaults()).isEmpty)
    }
}

@Suite("Einstellungen")
struct SettingsTests {
    @Test func keysAndTileRange() {
        #expect(SettingsKey.tileSizeRange == 40...120)
        #expect(Set([SettingsKey.showFolderTree, SettingsKey.previewOnLeft, SettingsKey.tileSize]).count == 3)
    }

    @Test func tilePagesFallBackToTheFirstPageForNameHits() {
        let byName = DocumentHit(url: URL(fileURLWithPath: "/tmp/x.pdf"), relativePath: "x.pdf", modifiedAt: .now, pageHits: [],
                                 totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/tmp"), pageCount: 3, nameMatch: true)
        #expect(byName.tilePages == [0])
        #expect(hit("a/b.pdf").displayName == "b.pdf")
    }
}

@Suite("Kachelzeilen")
struct RowPackingTests {
    private func hits(_ n: Int, pages: Int = 1) -> [DocumentHit] {
        (0..<n).map { i in
            DocumentHit(url: URL(fileURLWithPath: "/tmp/\(i).pdf"), relativePath: "\(i).pdf", modifiedAt: .now,
                        pageHits: (0..<pages).map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: pages, relevance: 1,
                        sourceRoot: URL(fileURLWithPath: "/tmp"), pageCount: pages)
        }
    }

    @Test func everyHitOnceInOrder() {
        let all = hits(37, pages: 3)
        let rows = ResultsView.rows(all, tileSize: 60, width: 700, spacing: 10)
        #expect(rows.flatMap(\.hits).map(\.id) == all.map(\.id))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func rowsFitTheWidthAndSmallTilesFitMore() {
        let all = hits(20)
        for size in [40.0, 80, 120] {
            for row in ResultsView.rows(all, tileSize: size, width: 600, spacing: 10) where row.hits.count > 1 {
                let width = row.hits.reduce(0) { $0 + FileCard.width(tiles: $1.tilePages.count, tileSize: size) } + CGFloat(row.hits.count - 1) * 10
                #expect(width <= 600)
            }
        }
        let small = ResultsView.rows(hits(20, pages: 4), tileSize: 40, width: 900, spacing: 10).count
        let big = ResultsView.rows(hits(20, pages: 4), tileSize: 120, width: 900, spacing: 10).count
        #expect(small < big)
    }

    @Test func tooWideCardGetsItsOwnRow() {
        let rows = ResultsView.rows(hits(3, pages: 8), tileSize: 120, width: 300, spacing: 10)
        #expect(rows.map(\.hits.count) == [1, 1, 1])
    }
}
