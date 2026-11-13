import Foundation
import IndexKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.1 §12: an empty search field shows every PDF of every source, one row per file.
@MainActor @Suite("Browsing without a search term")
struct BrowseTests {
    let base: URL
    let eins: URL, zwei: URL
    let pdf: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        pdf = base.appendingPathComponent("einzeln.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Eins", "Zwei", "Drei"])
    }

    func entry(_ path: String, root: String, pages: Int, days: Double = 0, unreadable: Bool = false) -> DocumentHit {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return DocumentHit(url: rootURL.appendingPathComponent(path), relativePath: path,
                           modifiedAt: Date(timeIntervalSince1970: days * 86_400), pageHits: [], totalMatches: 0,
                           relevance: 0, sourceRoot: rootURL, pageCount: pages, isUnreadable: unreadable)
    }

    func model(_ indexes: [String: FakeIndex], settings: GridSettings? = nil) -> AppModel {
        AppModel(settings: settings ?? makeSettings(),
                 defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), debounce: .zero,
                 openIndex: { root in indexes[root.lastPathComponent]! })
    }

    @Test func emptyQueryShowsAllFilesOfAllSources() async {
        let a = FakeIndex(), b = FakeIndex()
        a.browseList = [entry("x.pdf", root: "/eins", pages: 4), entry("sub/y.pdf", root: "/eins", pages: 2)]
        b.browseList = [entry("z.pdf", root: "/zwei", pages: 10)]
        let m = model(["eins": a, "zwei": b])
        await m.add([eins, zwei, pdf])
        await m.waitUntilIdle()
        #expect(m.isBrowsing)
        #expect(Set(m.hits.map(\.id)) == ["/eins/x.pdf", "/eins/sub/y.pdf", "/zwei/z.pdf", pdf.path])
        #expect(m.hits.first { $0.id == pdf.path }?.pageCount == 3)
        #expect(m.summary == "4 Dateien, 19 Seiten")
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(!m.isBrowsing)
        m.queryText = ""
        await m.waitUntilIdle()
        #expect(m.isBrowsing)
        #expect(m.hits.count == 4)
    }

    @Test func browseSortsAndFallsBackToFolder() async {
        let a = FakeIndex(), b = FakeIndex()
        a.browseList = [entry("b.pdf", root: "/eins", pages: 1, days: 1), entry("sub/a.pdf", root: "/eins", pages: 1, days: 3)]
        b.browseList = [entry("c.pdf", root: "/zwei", pages: 1, days: 2)]
        let settings = makeSettings()
        let m = model(["eins": a, "zwei": b], settings: settings)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        let byFolder = ["/eins/b.pdf", "/eins/sub/a.pdf", "/zwei/c.pdf"]
        let expected: [SortMode: [String]] = [
            .matchCount: byFolder, .relevance: byFolder, .folder: byFolder,
            .fileName: ["/eins/sub/a.pdf", "/eins/b.pdf", "/zwei/c.pdf"],
            .modifiedDate: ["/eins/sub/a.pdf", "/zwei/c.pdf", "/eins/b.pdf"],
        ]
        for mode in SortMode.allCases {
            settings.sort = mode
            await m.waitUntilIdle()
            #expect(m.hits.map(\.id) == expected[mode], "\(mode)")
        }
    }

    @Test func unreadableFileShownWithoutTiles() async {
        let a = FakeIndex()
        a.browseList = [entry("kaputt.pdf", root: "/eins", pages: 0, unreadable: true), entry("gut.pdf", root: "/eins", pages: 2)]
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitUntilIdle()
        let broken = m.hits.first { $0.id == "/eins/kaputt.pdf" }
        #expect(broken?.isUnreadable == true)
        #expect(RowPages.pages(for: broken!, showAll: false).isEmpty)
        #expect(m.summary == "2 Dateien, 2 Seiten")
    }

    @Test func browseUpdatesWhileIndexing() async {
        let a = FakeIndex()
        a.holdUpdates = true
        a.browseList = [entry("x.pdf", root: "/eins", pages: 1)]
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitForSearch()
        #expect(m.hits.count == 1)
        a.browseList = [entry("x.pdf", root: "/eins", pages: 1), entry("neu.pdf", root: "/eins", pages: 5)]
        a.emitProgress(IndexProgress(done: 2, total: 3, currentFile: nil))   // the indexer found more
        #expect(await eventually(.seconds(3)) { m.hits.count == 2 })
        a.holdUpdates = false
        await m.waitUntilIdle()
    }

    @Test func neverIndexedFolderUsesScan() async throws {
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("a.pdf"), pages: ["x"])
        try FileManager.default.createDirectory(at: eins.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("sub/b.pdf"), pages: ["x", "y"])
        let index = try FolderIndex.shared(root: eins, indexURL: base.appendingPathComponent("eins.sqlite"))
        let entries = try index.browse()
        #expect(Set(entries.map(\.relativePath)) == ["a.pdf", "sub/b.pdf"])
        #expect(entries.allSatisfy { $0.pageCount == 0 && $0.pageHits.isEmpty })
        _ = try await index.update { _ in }
        let indexed = try index.browse()
        #expect(indexed.first { $0.relativePath == "sub/b.pdf" }?.pageCount == 2)
        #expect(indexed.first { $0.relativePath == "sub/b.pdf" }?.sourceRoot.path == eins.path)
    }

    @Test func selectionSurvivesBrowseAndSearch() async {
        let a = FakeIndex()
        a.browseList = [entry("x.pdf", root: "/eins", pages: 3)]
        a.hits = [doc("x.pdf", pages: [0], root: "/eins")]
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitUntilIdle()
        let ref = PageRef(url: m.hits[0].url, pageIndex: 2)
        m.selection.toggle(ref)
        let hitPage = PageRef(url: m.hits[0].url, pageIndex: 0)
        m.focusedPage = hitPage          // a hit page: stays focused in search and browse
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        m.queryText = ""
        await m.waitUntilIdle()
        #expect(m.selection.contains(ref))
        #expect(m.focusedPage == hitPage)
    }

    @Test func tenThousandFilesWithoutHang() async {
        let a = FakeIndex()
        a.browseList = (0..<10_000).map { entry(String(format: "o%03d/d%05d.pdf", $0 / 100, $0), root: "/eins", pages: 20) }
        let settings = makeSettings()
        let m = model(["eins": a], settings: settings)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await m.add([eins])
            await m.waitUntilIdle()
            settings.sort = .fileName
            await m.waitUntilIdle()
        }
        #expect(m.hits.count == 10_000)
        #expect(m.summary == "10.000 Dateien, 200.000 Seiten")
        #expect(elapsed < .seconds(3), "\(elapsed)")
        let start = clock.now
        let next = FocusNavigator.next(from: PageRef(url: m.hits[9_998].url, pageIndex: 5), direction: .down, hits: m.hits)
        #expect(next == PageRef(url: m.hits[9_999].url, pageIndex: 5))
        #expect(clock.now - start < .milliseconds(200))
    }

    // MARK: Review of Task 4

    /// Progress arrives once per file; a browse slower than that must still finish, and refreshes
    /// must not pile up.
    @Test func refreshIsThrottledWhileBrowseIsSlow() async {
        let a = FakeIndex()
        a.holdUpdates = true
        a.browseDelay = 0.3
        a.browseList = [entry("x.pdf", root: "/eins", pages: 1)]
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitForSearch()
        a.browseList = [entry("x.pdf", root: "/eins", pages: 1), entry("neu.pdf", root: "/eins", pages: 5)]
        let before = a.browseCount
        for i in 0..<100 {
            a.emitProgress(IndexProgress(done: i, total: 100, currentFile: nil))
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await eventually(.seconds(3)) { m.hits.count == 2 })
        #expect(a.browseCount - before <= 4, "\(a.browseCount - before) browses in 2 s")
        a.holdUpdates = false
        await m.waitUntilIdle()
    }

    @Test func browseShowsSearchingWhileSlow() async {
        let a = FakeIndex()
        a.browseDelay = 0.4
        let m = model(["eins": a])
        await m.add([eins])
        #expect(await eventually { m.isSearching })
        await m.waitUntilIdle()
        #expect(!m.isSearching)
    }

    /// While a folder is (re)indexed, files not stored yet stay listed from the scan.
    @Test func browseMergesScanWhileIndexing() async throws {
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("a.pdf"), pages: ["x", "y"])
        let index = try FolderIndex.shared(root: eins, indexURL: base.appendingPathComponent("eins.sqlite"))
        _ = try await index.update { _ in }
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("b.pdf"), pages: ["x"])
        #expect(try index.browse().map(\.relativePath) == ["a.pdf"])            // idle: the index only
        let merged = try index.browse(includingScan: true)
        #expect(Set(merged.map(\.relativePath)) == ["a.pdf", "b.pdf"])
        #expect(merged.first { $0.relativePath == "a.pdf" }?.pageCount == 2)
        #expect(merged.first { $0.relativePath == "b.pdf" }?.pageCount == 0)
        let seen = Locked(false)
        _ = try await index.update { _ in if index.isUpdating { seen.set(true) } }
        #expect(seen.value)
        #expect(!index.isUpdating)
    }

    // MARK: Final review (I1): browsing a large folder while it is indexed must not stutter

    /// The list is sorted off the main actor; applying 10,000 entries on the main actor stays short.
    @Test func browseAppliesSortedListQuickly() async {
        let a = FakeIndex()
        a.browseList = (0..<10_000).reversed().map { entry(String(format: "o%03d/d%05d.pdf", $0 / 100, $0), root: "/eins", pages: 20) }
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(m.hits.first?.relativePath == "o000/d00000.pdf")
        #expect(m.lastMainApply < .milliseconds(50), "\(m.lastMainApply)")
    }

    /// Background refreshes during indexing do not flash „Suche läuft…“.
    @Test func refreshDoesNotShowSearching() async {
        let a = FakeIndex()
        a.holdUpdates = true
        a.browseList = [entry("x.pdf", root: "/eins", pages: 1)]
        let m = model(["eins": a])
        await m.add([eins])
        await m.waitForSearch()
        a.browseDelay = 0.3
        let seen = Locked(false)
        let watcher = Task { @MainActor in
            while !Task.isCancelled { if m.isSearching { seen.set(true) }; try? await Task.sleep(for: .milliseconds(5)) }
        }
        a.emitProgress(IndexProgress(done: 1, total: 3, currentFile: nil))
        try? await Task.sleep(for: .milliseconds(1_600))
        watcher.cancel()
        #expect(a.browseCount >= 2)
        #expect(!seen.value)
        a.holdUpdates = false
        await m.waitUntilIdle()
    }

    /// While indexing, the folder is scanned once for browsing, not on every refresh.
    @Test func scanOncePerIndexingRun() async throws {
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("a.pdf"), pages: ["x"])
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("b.pdf"), pages: ["y"])
        let index = try FolderIndex.shared(root: eins, indexURL: base.appendingPathComponent("scan.sqlite"))
        _ = try await index.update { _ in
            _ = try? index.browse()
            _ = try? index.browse()
        }
        #expect(index.scanCount == 1)
        _ = try index.browse()                  // idle: the stored documents only
        #expect(index.scanCount == 1)
    }
}
