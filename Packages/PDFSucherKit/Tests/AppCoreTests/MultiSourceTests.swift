import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

private struct SearchBroke: Error {}

/// Spec 1.1 §4: several sources, one indexing queue, search over all of them.
@MainActor @Suite("AppModel with several sources")
struct MultiSourceTests {
    let base: URL
    let eins: URL, zwei: URL, drei: URL
    let pdf: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        drei = base.appendingPathComponent("drei", isDirectory: true)
        for dir in [eins, zwei, drei, eins.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        pdf = base.appendingPathComponent("einzeln.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Kein Treffer", "Der Vertrag"])
    }

    /// Indexes by folder name; `log` records "<name>:<event>" across all of them.
    func indexes(_ names: [String], log: StringLog = StringLog()) -> [String: FakeIndex] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            let index = FakeIndex()
            index.name = name
            index.sharedLog = log
            return (name, index)
        })
    }

    func model(_ indexes: [String: FakeIndex], defaults: UserDefaults? = nil,
               environment: FakeEnvironment = FakeEnvironment(), settings: GridSettings? = nil) -> AppModel {
        AppModel(settings: settings ?? makeSettings(),
                 defaults: defaults ?? UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                 environment: environment, slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in indexes[root.lastPathComponent]! }, officeRendering: PowerPointDisplaySetting())
    }

    @Test func twoFoldersSearchMergesAndSorts() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.hits = [doc("b.pdf", pages: [0], matches: 1, root: "/eins", modified: .init(timeIntervalSince1970: 3), relevance: 5),
                             doc("x/a.pdf", pages: [0], matches: 7, root: "/eins", modified: .init(timeIntervalSince1970: 1), relevance: 1)]
        idx["zwei"]!.hits = [doc("c.pdf", pages: [0], matches: 3, root: "/zwei", modified: .init(timeIntervalSince1970: 2), relevance: 9)]
        let settings = makeSettings()
        let m = model(idx, settings: settings)
        await m.add([eins, zwei])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        let expected: [SortMode: [String]] = [
            .matchCount: ["/eins/x/a.pdf", "/zwei/c.pdf", "/eins/b.pdf"],
            .relevance: ["/zwei/c.pdf", "/eins/b.pdf", "/eins/x/a.pdf"],
            .modifiedDate: ["/eins/b.pdf", "/zwei/c.pdf", "/eins/x/a.pdf"],
            .fileName: ["/eins/x/a.pdf", "/eins/b.pdf", "/zwei/c.pdf"],
            .folder: ["/eins/b.pdf", "/eins/x/a.pdf", "/zwei/c.pdf"],
        ]
        for mode in SortMode.allCases {
            settings.sort = mode
            await m.waitUntilIdle()
            #expect(m.hits.map(\.id) == expected[mode], "\(mode)")
        }
        #expect(m.summary == "Gefunden in 3 Dokumenten, 3 Seiten")
    }

    @Test func addFolderAndPdfTogether() async {
        let idx = indexes(["eins"])
        idx["eins"]!.hits = [doc("a.pdf", pages: [0], root: "/eins")]
        let m = model(idx)
        await m.add([eins, pdf])
        #expect(m.sources == [LoadedSourceRef(url: eins, isFolder: true), LoadedSourceRef(url: pdf, isFolder: false)])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(Set(m.hits.map(\.id)) == ["/eins/a.pdf", pdf.path])
        #expect(m.hits.first { $0.id == pdf.path }?.pageHits.map(\.pageIndex) == [1])
    }

    @Test func indexesOneFolderAfterAnother() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdUpdates = true
        let m = model(idx)
        await m.add([eins, zwei])
        #expect(await eventually { m.indexStatus == .building(folder: 1, folders: 2, done: 0, total: 3) })
        #expect(log.entries == ["eins:update-start"])
        idx["eins"]!.holdUpdates = false
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "zwei:update-start", "zwei:update-end"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test func secondFolderShowsItsPosition() async {
        let idx = indexes(["eins", "zwei"])
        idx["zwei"]!.holdUpdates = true
        let m = model(idx)
        await m.add([eins, zwei])
        #expect(await eventually { m.indexStatus == .building(folder: 2, folders: 2, done: 0, total: 3) })
        idx["zwei"]!.holdUpdates = false
        await m.waitUntilIdle()
    }

    @Test func searchIsPossibleWhileQueueRuns() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.hits = [doc("a.pdf", pages: [0], root: "/eins")]
        idx["zwei"]!.hits = [doc("b.pdf", pages: [0], root: "/zwei")]
        let m = model(idx)
        await m.add([eins, zwei])
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(Set(m.hits.map(\.id)) == ["/eins/a.pdf", "/zwei/b.pdf"])
        idx["eins"]!.holdUpdates = false
        await m.waitUntilIdle()
    }

    @Test func removingIndexingSourceContinuesQueue() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.hits = [doc("a.pdf", pages: [0], root: "/eins")]
        idx["zwei"]!.hits = [doc("b.pdf", pages: [0], root: "/zwei")]
        let m = model(idx)
        await m.add([eins, zwei])
        m.queryText = "Vertrag"
        #expect(await eventually { log.entries == ["eins:update-start"] })
        m.removeSource(eins)
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-cancelled", "zwei:update-start", "zwei:update-end"])
        #expect(m.sources == [LoadedSourceRef(url: zwei, isFolder: true)])
        #expect(m.hits.map(\.id) == ["/zwei/b.pdf"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test func removeAllCancelsAndClears() async {
        let idx = indexes(["eins"])
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.hits = [doc("a.pdf", pages: [0], root: "/eins")]
        let m = model(idx)
        await m.add([eins, pdf])
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(!m.hits.isEmpty)
        m.removeAllSources()
        await m.waitUntilIdle()
        #expect(m.sources.isEmpty)
        #expect(m.hits.isEmpty)
        #expect(m.indexStatus == .none)
        #expect(idx["eins"]!.events == ["update-start", "update-cancelled"])
        #expect(!m.canDeleteIndex)
    }

    @Test func parentReplacesChildIndex() async {
        let idx = indexes(["sub", "eins"])
        idx["sub"]!.hits = [doc("s.pdf", pages: [0], root: "/sub")]
        idx["eins"]!.hits = [doc("e.pdf", pages: [0], root: "/eins")]
        let m = model(idx)
        await m.add([eins.appendingPathComponent("sub")])
        await m.waitUntilIdle()
        await m.add([eins])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.sources == [LoadedSourceRef(url: eins, isFolder: true)])
        #expect(m.hits.map(\.id) == ["/eins/e.pdf"])
        let searches = idx["sub"]!.searchCount
        m.queryText = "Miete"
        await m.waitUntilIdle()
        #expect(idx["sub"]!.searchCount == searches)
    }

    @Test func alreadyContainedNotice() async {
        let m = model(indexes(["eins"]))
        await m.add([eins])
        await m.add([eins.appendingPathComponent("sub")])
        #expect(m.notice == "„sub“ ist bereits enthalten in „eins“")
        #expect(m.sources.count == 1)
    }

    @Test func ignoredDropsNotice() async throws {
        let text = base.appendingPathComponent("notiz.txt")
        try Data("x".utf8).write(to: text)
        let m = model(indexes(["eins"]))
        await m.add([eins, text])
        #expect(m.notice == "1 Datei ignoriert (nur Ordner und PDFs)")
        await m.add([text, text])
        #expect(m.notice == "2 Dateien ignoriert (nur Ordner und PDFs)")
        #expect(m.sources.count == 1)
    }

    @Test func sourcesPersistAndRestore() async throws {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        let idx = indexes(["eins", "zwei"])
        let first = model(idx, defaults: defaults)
        await first.add([eins, pdf, zwei])
        await first.waitUntilIdle()
        #expect(defaults.stringArray(forKey: "sources") == [eins.path, pdf.path, zwei.path])
        try FileManager.default.removeItem(at: zwei)

        let next = model(idx, defaults: defaults)
        await next.restoreSources()
        await next.waitUntilIdle()
        #expect(next.sources.map(\.url.path) == [eins.path, pdf.path])
        #expect(next.notice == "Nicht gefunden, übersprungen: zwei")
        await next.restoreSources()      // only once per model
        #expect(next.sources.count == 2)
        // A missing source stays remembered (e.g. an unplugged disk) until „Alle entfernen“.
        #expect(defaults.stringArray(forKey: "sources") == [eins.path, pdf.path, zwei.path])
        next.removeAllSources()
        #expect(defaults.stringArray(forKey: "sources") == [])
    }

    @Test func migratesLastFolderPath() async {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        defaults.set(eins.path, forKey: "lastFolderPath")
        let m = model(indexes(["eins"]), defaults: defaults)
        await m.restoreSources()
        #expect(m.sources == [LoadedSourceRef(url: eins, isFolder: true)])
        #expect(defaults.stringArray(forKey: "sources") == [eins.path])
    }

    @Test func deleteIndexOfOneSourceOnly() async {
        let idx = indexes(["eins", "zwei"])
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        await m.deleteIndex(for: zwei)
        await m.waitUntilIdle()
        #expect(!idx["eins"]!.events.contains("delete"))
        #expect(idx["zwei"]!.events == ["update-start", "update-end", "delete", "update-start", "update-end"])
        #expect(m.folderSources == [eins, zwei])
    }

    @Test func deleteIndexOfAll() async {
        let idx = indexes(["eins", "zwei"])
        let m = model(idx)
        await m.add([eins, pdf, zwei])
        await m.waitUntilIdle()
        await m.deleteIndex(for: nil)
        await m.waitUntilIdle()
        #expect(idx["eins"]!.events.filter { $0 == "delete" }.count == 1)
        #expect(idx["zwei"]!.events.filter { $0 == "delete" }.count == 1)
        #expect(m.indexStatus == .upToDate)
    }

    @Test func oneFailingSourceKeepsOtherHits() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.hits = [doc("a.pdf", pages: [0], root: "/eins")]
        idx["zwei"]!.failNextSearch(with: SearchBroke())
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.id) == ["/eins/a.pdf"])
        #expect(m.notice?.hasPrefix("Suche fehlgeschlagen") == true)
    }

    @Test func problemsArePrefixedWithFolderWhenSeveral() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.report = IndexReport(failed: ["kaputt.pdf"])
        idx["zwei"]!.report = IndexReport(noText: ["scan.pdf"])
        idx["zwei"]!.ocrReport = OCRReport(noText: ["scan.pdf"])   // 1.2: recognition found no text either
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: ["eins/kaputt.pdf"], noText: ["zwei/scan.pdf"]))
    }

    @Test func openSourcesUsesPanel() async {
        let env = FakeEnvironment()
        env.sources = [eins, pdf]
        let m = model(indexes(["eins"]), environment: env)
        m.openSources()
        #expect(await eventually { m.sources.count == 2 })
        await m.waitUntilIdle()
    }

    @Test func statusTexts() {
        #expect(ViewerText.indexStatus(.building(folder: 1, folders: 1, done: 412, total: 3180)) == "Index: wird aufgebaut (412/3.180)")
        #expect(ViewerText.indexStatus(.building(folder: 2, folders: 3, done: 412, total: 3180)) == "Index Ordner 2/3: 412/3.180")
    }

    // MARK: Review of Task 2

    private struct OpenFailed: Error {}

    func failingModel(_ indexes: [String: FakeIndex], failing: String, defaults: UserDefaults? = nil) -> AppModel {
        AppModel(settings: makeSettings(), defaults: defaults ?? UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in
                     if root.lastPathComponent == failing { throw OpenFailed() }
                     return indexes[root.lastPathComponent]!
                 }, officeRendering: PowerPointDisplaySetting())
    }

    @Test func failedIndexOpenInMiddleKeepsTheRest() async {
        let idx = indexes(["eins", "drei"])
        let m = failingModel(idx, failing: "zwei")
        await m.add([eins, zwei, drei, pdf])
        await m.waitUntilIdle()
        #expect(m.sources.map(\.url.lastPathComponent) == ["eins", "drei", "einzeln.pdf"])
        #expect(idx["eins"]!.events == ["update-start", "update-end"])
        #expect(idx["drei"]!.events == ["update-start", "update-end"])
        #expect(m.alertMessage?.hasPrefix("Index für „zwei“ kann nicht geöffnet werden") == true)
    }

    @Test func restoreKeepsFoldersWhoseIndexFails() async {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        defaults.set([eins.path, zwei.path, pdf.path], forKey: "sources")
        let m = failingModel(indexes(["eins"]), failing: "zwei", defaults: defaults)
        await m.restoreSources()
        await m.waitUntilIdle()
        #expect(m.sources.map(\.url.lastPathComponent) == ["eins", "einzeln.pdf"])
        #expect(Set(defaults.stringArray(forKey: "sources") ?? []) == [eins.path, zwei.path, pdf.path])
    }

    @Test func failureOfOneFolderSurvivesOtherSuccess() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.failNextUpdate(with: CocoaError(.fileReadUnknown))
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(m.notice?.hasPrefix("Indexieren fehlgeschlagen") == true)
        m.removeSource(eins)
        #expect(m.notice == nil)
    }

    @Test func statusRightAfterRemovingCurrentFolder() async {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.lingerOnCancel = true      // the cancelled run takes a while to end
        let m = model(idx)
        await m.add([eins, zwei])
        #expect(await eventually { m.indexStatus == .building(folder: 1, folders: 2, done: 0, total: 3) })
        m.removeSource(eins)
        #expect(m.indexStatus == .building(folder: 1, folders: 1, done: 0, total: 0))
        idx["eins"]!.lingerOnCancel = false
        await m.waitUntilIdle()
        #expect(m.indexStatus == .upToDate)
    }

    @Test func statusRightAfterRemovingOnlyFolder() async {
        let idx = indexes(["eins"])
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.lingerOnCancel = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { idx["eins"]!.events == ["update-start"] })
        m.removeSource(eins)
        #expect(m.indexStatus == .none)
        idx["eins"]!.lingerOnCancel = false
        await m.waitUntilIdle()
        #expect(m.indexStatus == .none)
    }

    @Test func addWhileQueueRunsAppends() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdUpdates = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries == ["eins:update-start"] })
        await m.add([zwei])
        #expect(m.indexStatus == .building(folder: 1, folders: 2, done: 0, total: 3))
        idx["eins"]!.holdUpdates = false
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "zwei:update-start", "zwei:update-end"])
    }

    @Test func transientHintsClearOnNextChange() async throws {
        let text = base.appendingPathComponent("notiz.txt")
        try Data("x".utf8).write(to: text)
        let m = model(indexes(["eins", "zwei"]))
        await m.add([eins, text])
        #expect(m.notice != nil)
        await m.add([zwei])
        #expect(m.notice == nil)
    }

    // MARK: Review of Task 3

    @Test func requestDeleteNamesTheTarget() async {
        let env = FakeEnvironment()
        let idx = indexes(["eins", "zwei"])
        let m = model(idx, environment: env)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        env.confirmAnswer = false
        m.requestDeleteIndex(for: zwei)
        m.requestDeleteIndex(for: nil)
        #expect(env.confirmations == ["Index von „zwei“ löschen?", "Index aller 2 Ordner löschen?"])
    }

    /// A folder removed after it was picked in Settings must not turn into „all folders“.
    @Test func deleteOfRemovedFolderDoesNothing() async {
        let env = FakeEnvironment()
        let idx = indexes(["eins", "zwei"])
        let m = model(idx, environment: env)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        m.removeSource(zwei)
        m.requestDeleteIndex(for: zwei)
        await m.waitUntilIdle()
        #expect(env.confirmations.isEmpty)
        #expect(!idx["eins"]!.events.contains("delete"))
    }

    /// Final review: a transient hint must not hide a lasting index problem for good.
    @Test func indexProblemHintComesBackAfterTransientHint() async throws {
        let idx = indexes(["eins", "zwei"])
        idx["eins"]!.failNextUpdate(with: CocoaError(.fileReadUnknown))
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        let problem = m.notice
        #expect(problem?.hasPrefix("Indexieren fehlgeschlagen") == true)
        let text = base.appendingPathComponent("notiz.txt")
        try Data("x".utf8).write(to: text)
        await m.add([text])
        #expect(m.notice == "1 Datei ignoriert (nur Ordner und PDFs)")
        await m.add([zwei])
        await m.waitUntilIdle()
        #expect(m.notice == problem)
    }
}
