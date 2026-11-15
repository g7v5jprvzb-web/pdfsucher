import Foundation
import IndexKit
import OfficeKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Lays out Word/PowerPoint for a real `FolderIndex`: `x.pptx` cannot be read, every other file gets one
/// page with its name as text — `y.docx` only once `open` is set (until then it waits, cancellably).
private final class GatedLayout: PageLayoutSource {
    private let state = Mutex((open: false, attempts: [String: Int]()))
    var open: Bool {
        get { state.withLock { $0.open } }
        set { state.withLock { $0.open = newValue } }
    }
    func attempts(_ name: String) -> Int { state.withLock { $0.attempts[name] ?? 0 } }

    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let name = url.lastPathComponent
        state.withLock { $0.attempts[name, default: 0] += 1 }
        if name == "x.pptx" { throw LayoutSourceError.unreadable(url, reason: "kaputt") }
        if name == "y.docx" || name == "c.docx" {
            while !open {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        return LayoutResult(pages: [LaidOutPage(text: "Angebot \(name)", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: "fake", layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("fake", 1) }
}

/// 1.3 Part B Task 4: the layout phase in the AppModel queue (text → layout → OCR) and its status line.
@MainActor @Suite("Layout phase in the queue")
struct LayoutQueueTests {
    let base: URL
    let eins: URL, zwei: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func indexes(_ names: [String], log: StringLog) -> [String: FakeIndex] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            index.layoutLog = log
            return (name, index)
        })
    }

    func model(_ open: @escaping @Sendable (URL) throws -> any FolderIndexing) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "LayoutQ-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: open, officeRendering: PowerPointDisplaySetting())
    }

    func model(_ indexes: [String: FakeIndex]) -> AppModel {
        model { root in indexes[root.lastPathComponent]! }
    }

    @Test(.timeLimit(.minutes(1))) func phasesRunTextThenLayoutThenOCR() async {
        let log = StringLog()
        let m = model(indexes(["eins", "zwei"], log: log))
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "zwei:update-start", "zwei:update-end",
                                "eins:layout-start", "eins:layout-end", "zwei:layout-start", "zwei:layout-end",
                                "eins:ocr-start", "eins:ocr-end", "zwei:ocr-start", "zwei:ocr-end"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test(.timeLimit(.minutes(1))) func statusShowsLayoutProgress() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { m.indexStatus == .layingOut(folder: 1, folders: 1, done: 0, total: 2) })
        idx["eins"]!.emitProgress(IndexProgress(done: 12, total: 340, currentFile: "a.pptx", phase: .layout))
        #expect(await eventually { m.indexStatus == .layingOut(folder: 1, folders: 1, done: 12, total: 340) })
        #expect(ViewerText.indexStatus(m.indexStatus) == "Word/PowerPoint 12/340")
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(m.indexStatus == .upToDate)

        // Two folders: the layout of the second one shows its position.
        idx["zwei"]!.holdLayout = true
        await m.add([zwei])
        #expect(await eventually { log.entries.last == "zwei:layout-start" })
        idx["zwei"]!.emitProgress(IndexProgress(done: 12, total: 340, currentFile: nil, phase: .layout))
        #expect(await eventually { m.indexStatus == .layingOut(folder: 2, folders: 2, done: 12, total: 340) })
        #expect(ViewerText.indexStatus(.layingOut(folder: 1, folders: 2, done: 12, total: 340)) == "Word/PowerPoint Ordner 1/2: 12/340")
        idx["zwei"]!.holdLayout = false
        await m.waitUntilIdle()
    }

    @Test(.timeLimit(.minutes(1))) func newFolderPreemptsLayout() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        await m.add([zwei])
        #expect(await eventually { log.entries.contains("zwei:update-end") })
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "eins:layout-start", "eins:layout-cancelled",
                                "zwei:update-start", "zwei:update-end", "eins:layout-start", "eins:layout-end",
                                "zwei:layout-start", "zwei:layout-end",
                                "eins:ocr-start", "eins:ocr-end", "zwei:ocr-start", "zwei:ocr-end"])
    }

    @Test(.timeLimit(.minutes(1))) func layoutFailuresInProblemList() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.layoutReport = LayoutReport(laidOut: 3, failed: ["x.pptx"], noText: ["y.docx"])
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: ["x.pptx"], noText: ["y.docx"]))
    }

    /// The problem lists of a layout run come from the whole index: a deck stored as unreadable by a run that
    /// was then interrupted stays in the list after the next run (which does not lay it out again).
    @Test(.timeLimit(.minutes(1))) func layoutProblemsSurviveInterruptedRun() async throws {
        try OfficeFixtures.pptx(slides: ["Folie"], name: "x.pptx", in: eins)
        try OfficeFixtures.docx(paragraphs: ["Angebot"], name: "y.docx", in: eins)
        let layout = GatedLayout()
        let real = try FolderIndex(root: eins, indexURL: base.appendingPathComponent("eins.sqlite"), makeLayout: { layout })
        let log = StringLog()
        let fake = indexes(["zwei"], log: log)["zwei"]!
        let m = model { root -> any FolderIndexing in root.lastPathComponent == "eins" ? real : fake }
        await m.add([eins])
        #expect(await eventually { m.indexStatus == .layingOut(folder: 1, folders: 1, done: 1, total: 2) },
                "x.pptx is stored as unreadable while y.docx is still being laid out")
        await m.add([zwei])
        #expect(await eventually { log.entries.contains("zwei:update-end") })
        layout.open = true
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: ["eins/x.pptx"], noText: []))
        #expect(layout.attempts("x.pptx") == 1)
        #expect(layout.attempts("y.docx") == 2)
    }

    @Test(.timeLimit(.minutes(1))) func layoutCompletionRefreshesSearch() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let index = idx["eins"]!
        index.holdLayout = true
        index.layoutReport = LayoutReport(laidOut: 1)    // new pages: worth a new search
        let m = model(idx)
        m.ocrPreferences.recognizeText = false           // only the layout run refreshes
        await m.waitUntilIdle()
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        m.queryText = "Angebot"
        await m.waitForSearch()
        let searches = index.searchCount
        index.holdLayout = false
        await m.waitUntilIdle()
        #expect(index.searchCount == searches + 1)

        // Browsing (no search term): the list is refreshed quietly.
        index.holdLayout = true
        m.queryText = ""
        await m.waitForSearch()
        m.officePreferences.includeOffice = false        // a rescan without layout …
        await m.waitUntilIdle()
        m.officePreferences.includeOffice = true         // … and on again: phase 1, then the layout
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        await m.waitForSearch()
        let browses = index.browseCount
        index.holdLayout = false
        await m.waitUntilIdle()
        #expect(index.browseCount > browses)
        #expect(m.isBrowsing)
        #expect(!m.isSearching)
    }

    @Test(.timeLimit(.minutes(1))) func layoutRevisionBumpsOnProgress() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        let before = m.layoutRevision
        idx["eins"]!.emitProgress(IndexProgress(done: 1, total: 2, currentFile: "a.pptx", phase: .layout))
        #expect(await eventually { m.layoutRevision > before }, "finished pages show while the run goes on")
        let during = m.layoutRevision
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(m.layoutRevision > during, "the end of every run bumps it")
    }

    @Test(.timeLimit(.minutes(1))) func noLayoutWhenOfficeOff() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        m.officePreferences.includeOffice = false
        await m.waitUntilIdle()
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 0)
        #expect(log.entries == ["eins:update-start", "eins:update-end", "eins:ocr-start", "eins:ocr-end"])
    }

    /// Review focus 5: „Word/PowerPoint“ off while a layout runs: the layout stops, the folder is listed again
    /// without Office files, and no layout follows.
    @Test(.timeLimit(.minutes(1))) func officeOffDuringLayoutStopsAndRemovesOfficeDocuments() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true                  // a layout started again would never end
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        m.officePreferences.includeOffice = false
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "eins:layout-start", "eins:layout-cancelled",
                                "eins:update-start", "eins:update-end", "eins:ocr-start", "eins:ocr-end"])
        #expect(idx["eins"]!.configuredOffice.last == false)
        #expect(idx["eins"]!.layoutCount == 1)
        #expect(m.indexStatus == .upToDate)
    }

    @Test(.timeLimit(.minutes(1))) func officeOffDuringLayoutRemovesOfficeDocumentsFromRealIndex() async throws {
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("a.pdf"), pages: ["Vertrag"])
        try OfficeFixtures.docx(paragraphs: ["Angebot"], name: "c.docx", in: eins)
        let layout = GatedLayout()
        let real = try FolderIndex(root: eins, indexURL: base.appendingPathComponent("eins.sqlite"), makeLayout: { layout })
        let m = model { _ in real }
        await m.add([eins])
        // The status shows `.layingOut` a moment before the layout source is called: wait for the call itself.
        #expect(await eventually { layout.attempts("c.docx") == 1 })
        #expect({ if case .layingOut = m.indexStatus { true } else { false } }())
        m.officePreferences.includeOffice = false
        await m.waitUntilIdle()
        #expect(layout.attempts("c.docx") == 1)
        #expect(try real.browse().map(\.relativePath) == ["a.pdf"])
        #expect(m.hits.map(\.relativePath) == ["a.pdf"])
    }

    /// Review fix: a folder with nothing laid out (e.g. PDFs only) gets no extra search per index pass.
    @Test(.timeLimit(.minutes(1))) func nothingLaidOutNoExtraSearch() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let index = idx["eins"]!
        index.holdLayout = true                          // `layoutReport.laidOut` is 0
        let m = model(idx)
        m.ocrPreferences.recognizeText = false
        await m.waitUntilIdle()
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        m.queryText = "Angebot"
        await m.waitForSearch()
        let searches = index.searchCount
        index.holdLayout = false
        await m.waitUntilIdle()
        #expect(index.searchCount == searches)
    }

    /// Review fix: a layout run that still ends successfully after „Word/PowerPoint“ was switched off stores no
    /// report (its problems would come back).
    @Test(.timeLimit(.minutes(1))) func lateLayoutSuccessAfterOfficeOffStoresNoReport() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let index = idx["eins"]!
        index.layoutReport = LayoutReport(laidOut: 1, failed: ["x.pptx"])
        index.holdLayout = true
        index.finishLayoutDespiteCancel = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        index.holdUpdates = true                         // the rescan's phase 1 stays open
        m.officePreferences.includeOffice = false
        #expect(await eventually { index.configuredOffice.last == false })
        index.holdLayout = false
        #expect(await eventually { log.entries.filter { $0 == "eins:update-start" }.count == 2 })
        #expect(log.entries.contains("eins:layout-end"))
        #expect(m.layoutReportsForTesting.isEmpty)
        index.holdUpdates = false
        await m.waitUntilIdle()
        #expect(m.layoutReportsForTesting.isEmpty)
        #expect(m.indexStatus == .upToDate)
    }

    /// Review: removing the source stops its layout; nothing of it runs again.
    @Test(.timeLimit(.minutes(1))) func removingSourceDuringLayoutCancelsIt() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true                  // a layout started again would not end
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        m.removeSource(eins)
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "eins:layout-start", "eins:layout-cancelled"])
        #expect(idx["eins"]!.layoutCount == 1)
        #expect(m.indexStatus == IndexStatus.none)
    }
}
