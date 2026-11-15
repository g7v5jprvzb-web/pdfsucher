import Foundation
import IndexKit
import OfficeKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// The real Word/PowerPoint layout behind a counter, a gate (`hold`, with the 20 s safety deadline; it honours
/// cancellation unless `ignoreCancel`) and scripted answers: a fixed `answer`, „unreadable“, one other error,
/// or one „unreadable“ after the file changed on disk (a file still being copied).
private final class GatedOfficeLayout: PageLayoutSource {
    private struct State {
        var count = 0, cancelled = 0, hold = false, unreadable = false, ignoreCancel = false
        var failOtherOnce = false, changeFileThenUnreadableOnce = false, answer: LayoutResult?
    }
    struct OtherError: Error {}
    private let state = Mutex(State())
    private let inner = OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: testSlideCache))

    var count: Int { state.withLock { $0.count } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var hold: Bool {
        get { state.withLock { $0.hold } }
        set { state.withLock { $0.hold = newValue } }
    }
    var unreadable: Bool {
        get { state.withLock { $0.unreadable } }
        set { state.withLock { $0.unreadable = newValue } }
    }
    var ignoreCancel: Bool {
        get { state.withLock { $0.ignoreCancel } }
        set { state.withLock { $0.ignoreCancel = newValue } }
    }
    var failOtherOnce: Bool {
        get { state.withLock { $0.failOtherOnce } }
        set { state.withLock { $0.failOtherOnce = newValue } }
    }
    var changeFileThenUnreadableOnce: Bool {
        get { state.withLock { $0.changeFileThenUnreadableOnce } }
        set { state.withLock { $0.changeFileThenUnreadableOnce = newValue } }
    }
    var answer: LayoutResult? {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }

    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        state.withLock { $0.count += 1 }
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while hold {
            if Task.isCancelled, !ignoreCancel {
                state.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
            try checkFakeHold("office layout", deadline: deadline)
            usleep(2_000)                               // not a cancellable sleep (ignoreCancel)
        }
        if state.withLock({ s in defer { s.failOtherOnce = false }; return s.failOtherOnce }) { throw OtherError() }
        if state.withLock({ s in defer { s.changeFileThenUnreadableOnce = false }; return s.changeFileThenUnreadableOnce }) {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
            throw LayoutSourceError.unreadable(url, reason: "abgeschnitten")
        }
        if unreadable { throw LayoutSourceError.unreadable(url, reason: "kaputt") }
        if let answer { return answer }
        return try await inner.layout(of: url, kind: kind)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { inner.renderer(for: kind) }
}

/// 1.3 Part B Task 5: Word/PowerPoint as single-file sources (⌘O, drop), laid out in memory.
@MainActor @Suite("Word/PowerPoint single files", .serialized)
struct SingleFileLayoutTests {
    let base: URL

    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    private func model(_ layout: GatedOfficeLayout, openIndex: @escaping @Sendable (URL) throws -> any FolderIndexing = { _ in FakeIndex() }) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "SFL-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: openIndex, officeLayout: layout, officeRendering: PowerPointDisplaySetting())
    }

    private func vertrag(_ text: String = "Die Kündigungsfrist beträgt drei Monate") throws -> URL {
        try OfficeFixtures.docx(paragraphs: [text], name: "Vertrag.docx", in: base)
    }

    @Test(.timeLimit(.minutes(1))) func singleDocxIsLaidOutAndSearchable() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageCount == 1)                       // browsing
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Vertrag.docx"])
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [0])
        #expect(m.hits.first?.kind == .word)
        #expect(m.hits.first?.isSimplified == true)
        #expect(m.notice == nil)                                    // no „PDF kann nicht gelesen werden“ (Task 3 → 5)
        #expect(m.notice != AppModel.Text.unreadable)
        let text = await m.ocrText(for: PageRefLike(url: docx, pageIndex: 0))
        #expect(text?.text.contains("Kündigungsfrist") == true)
        #expect(text?.words.isEmpty == false)
        #expect(layout.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func singleOfficeFileNeverQueuedForOCR() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        #expect(!m.recognitionQueueForTesting.contains(docx.path))
        #expect(await eventually { layout.count == 1 })
        #expect(!m.recognitionQueueForTesting.contains(docx.path))
        layout.hold = false
        await m.waitUntilIdle()
        #expect(!m.recognitionQueueForTesting.contains(docx.path))
    }

    @Test(.timeLimit(.minutes(1))) func singleOfficeFilePreemptsFolderOCROnlyOnce() async throws {
        let folder = base.appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = StringLog()
        let index = FakeIndex()
        index.name = "eins"
        index.ocrLog = log
        index.holdRecognition = true
        let layout = GatedOfficeLayout()
        let m = model(layout, openIndex: { _ in index })
        await m.add([folder])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        let docx = try vertrag()
        await m.add([docx])
        #expect(await eventually { layout.count == 1 && log.entries.filter { $0 == "eins:ocr-start" }.count == 2 })
        #expect(log.entries.filter { $0 == "eins:ocr-cancelled" }.count == 1)
        // The folder's recognition goes on; a text PDF added now lays out nothing again.
        let pdf = base.appendingPathComponent("text.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Ein Vertrag mit genug Text auf der Seite"])
        await m.add([pdf])
        index.holdRecognition = false
        await m.waitUntilIdle()
        #expect(layout.count == 1)
        #expect(log.entries.last == "eins:ocr-end")
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Vertrag.docx"])
    }

    @Test(.timeLimit(.minutes(1))) func singleOfficeFilePreemptsFolderLayout() async throws {
        let folder = base.appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = StringLog()
        let index = FakeIndex()
        index.name = "eins"
        index.layoutLog = log
        index.holdLayout = true
        let layout = GatedOfficeLayout()
        let m = model(layout, openIndex: { _ in index })
        await m.add([folder])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        await m.add([try vertrag()])
        #expect(await eventually { layout.count == 1 && log.entries.filter { $0 == "eins:layout-start" }.count == 2 })
        #expect(log.entries == ["eins:layout-start", "eins:layout-cancelled", "eins:layout-start"])
        index.holdLayout = false
        await m.waitUntilIdle()
        #expect(layout.count == 1)
        #expect(log.entries.last == "eins:layout-end")
    }

    /// Review Focus 2: a file changed after its layout shows none of its old words and is laid out again.
    @Test(.timeLimit(.minutes(1))) func changedSingleFileIsLaidOutAgainAndOldWordsDropped() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(await m.ocrText(for: PageRefLike(url: docx, pageIndex: 0)) != nil)
        try FileManager.default.removeItem(at: docx)
        _ = try vertrag("Das Zahlungsziel sind dreißig Tage")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: docx.path)
        #expect(await m.ocrText(for: PageRefLike(url: docx, pageIndex: 0)) == nil)
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
        #expect(m.notice == nil)
        #expect(layout.count == 2)
        m.queryText = "Zahlungsziel"
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [0])
        #expect(await m.ocrText(for: PageRefLike(url: docx, pageIndex: 0))?.text.contains("Zahlungsziel") == true)
    }

    @Test(.timeLimit(.minutes(1))) func unreadableSingleFileShowsOfficeNotice() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.unreadable = true
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(m.hits.first?.isUnreadable == true)
        #expect(m.hits.first?.kind == .word)
        m.queryText = "Zahlungsziel"
        await m.waitUntilIdle()
        #expect(m.notice == "Word- oder PowerPoint-Datei kann nicht gelesen werden")
        // Found by its name (Chris, 2026-11-14): the unreadable row instead of the notice.
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.count == 1 && m.hits.first?.isUnreadable == true && m.hits.first?.nameMatch == true)
        #expect(m.notice == nil)
        #expect(layout.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func timedOutLayoutCountsAsUnreadable() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        m.fileLayoutTimeout = .milliseconds(50)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(await eventually { layout.cancelled == 1 })   // the race returns at once, the source stops after
        #expect(m.hits.first?.isUnreadable == true)
    }

    @Test(.timeLimit(.minutes(1))) func pendingSingleFileShowsNoNotice() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        #expect(await eventually { layout.count == 1 })
        #expect(m.indexStatus == .layingOut(folder: 1, folders: 1, done: 0, total: 1))
        m.queryText = "Kündigungsfrist"
        await m.waitForSearch()
        #expect(m.hits.isEmpty)
        #expect(m.notice == nil)
        layout.hold = false
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Vertrag.docx"])
        #expect(m.notice == nil)
    }

    @Test(.timeLimit(.minutes(1))) func browseListsPendingThenPages() async throws {
        let docx = try OfficeFixtures.docx(paragraphs: ["Erste Seite", "Zweite Seite"], pageBreakAfter: [0], name: "Brief.docx", in: base)
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        await m.waitForSearch()
        #expect(m.isBrowsing)
        #expect(m.hits.first?.pageCount == 0)
        #expect(m.hits.first?.isUnreadable == false)
        #expect(m.hits.first?.kind == .word)
        layout.hold = false
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageCount == 2)
        #expect(m.hits.first?.isSimplified == true)
    }

    @Test(.timeLimit(.minutes(1))) func removingSourceCancelsLayout() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        #expect(await eventually { layout.count == 1 })
        m.removeSource(docx)
        #expect(await eventually { layout.cancelled == 1 })
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
        #expect(m.indexStatus == IndexStatus.none)
        #expect(layout.count == 1)
    }

    // MARK: Review fixes

    /// Review (Important): an unreadable file that changes (it was still being copied) is laid out again.
    @Test(.timeLimit(.minutes(1))) func unreadableFileThatChangesIsLaidOutAgain() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.unreadable = true
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(m.hits.first?.isUnreadable == true)
        try FileManager.default.removeItem(at: docx)
        _ = try vertrag()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: docx.path)
        layout.unreadable = false
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [0])
        #expect(m.notice == nil)
        #expect(layout.count == 2)
    }

    /// Review (Important): „unreadable“ for a file that changed during its layout is not final.
    @Test(.timeLimit(.minutes(1))) func fileChangedDuringFailedLayoutIsNotUnreadable() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.changeFileThenUnreadableOnce = true
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(layout.count == 2)
        #expect(m.hits.first?.isUnreadable == false)
        #expect(m.hits.first?.pageCount == 1)
    }

    /// Review minor 1: the stamp is checked when the pages are read; a change throws `StaleFileLayout`.
    @Test func laidOutTextSourceThrowsStaleForAChangedFile() throws {
        let docx = try vertrag()
        let old = FileStamp(modifiedAt: Date(timeIntervalSince1970: 1), size: 1)
        let result = LayoutResult(pages: [LaidOutPage(text: "alt", words: [], size: CGSize(width: 1, height: 1))],
                                  renderer: "textkit", layoutVersion: 1)
        #expect(throws: StaleFileLayout.self) { try LaidOutTextSource(state: .laidOut(result, old)).pages(of: docx) }
        #expect(throws: StaleFileLayout.self) { try LaidOutTextSource(state: .failed("kaputt", old)).pages(of: docx) }
        let now = FileStamp.of(docx)
        #expect(try LaidOutTextSource(state: .laidOut(result, now)).pages(of: docx).map(\.text) == ["alt"])
        #expect(throws: TextSourceError.self) { try LaidOutTextSource(state: .failed("kaputt", now)).pages(of: docx) }
        #expect(try LaidOutTextSource(state: .pending).pages(of: docx).isEmpty)
    }

    /// Review minor 2: a source that ignores cancellation does not hold the queue past the time limit; its
    /// late answer is dropped.
    @Test(.timeLimit(.minutes(1))) func timeLimitDoesNotWaitForUncooperativeSource() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        layout.ignoreCancel = true
        let m = model(layout)
        m.fileLayoutTimeout = .milliseconds(50)
        await m.add([docx])
        await m.waitUntilIdle()                          // returns while the source is still held
        #expect(layout.hold)
        #expect(m.hits.first?.isUnreadable == true)
        layout.hold = false
        try await Task.sleep(for: .milliseconds(100))   // the late answer arrives and is dropped
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
        #expect(m.notice == "Word- oder PowerPoint-Datei kann nicht gelesen werden")
    }

    /// Review minor 3: switching a setting during a single file's layout keeps its status.
    @Test(.timeLimit(.minutes(1))) func settingChangeKeepsSingleFileStatus() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        #expect(await eventually { layout.count == 1 })
        m.ocrPreferences.recognizeText = false
        #expect(await eventually { m.ocrPreferences.recognizeText == false })
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.indexStatus == .layingOut(folder: 1, folders: 1, done: 0, total: 1))
        layout.hold = false
        await m.waitUntilIdle()
        #expect(m.indexStatus == IndexStatus.none)
    }

    @Test(.timeLimit(.minutes(1))) func singlePowerPointIsLaidOut() async throws {
        let pptx = try OfficeFixtures.pptx(slides: ["Umsatzplanung"], name: "Folien.pptx", in: base)
        let layout = GatedOfficeLayout()
        layout.answer = LayoutResult(pages: [LaidOutPage(text: "Umsatzplanung", words: [], size: CGSize(width: 720, height: 540))],
                                     renderer: "quicklook", layoutVersion: 1)
        let m = model(layout)
        await m.add([pptx])
        await m.waitUntilIdle()
        m.queryText = "Umsatzplanung"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Folien.pptx"])
        #expect(m.hits.first?.kind == .powerpoint)
        #expect(m.hits.first?.isSimplified == false)
        #expect(m.notice == nil)
    }

    @Test(.timeLimit(.minutes(1))) func officeOffDuringSingleFileLayoutFinishes() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.hold = true
        let m = model(layout)
        await m.add([docx])
        #expect(await eventually { layout.count == 1 })
        m.officePreferences.includeOffice = false
        try await Task.sleep(for: .milliseconds(50))
        layout.hold = false
        await m.waitUntilIdle()
        #expect(layout.cancelled == 0)
        #expect(layout.count == 1)
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Vertrag.docx"])
    }

    /// „Index löschen“ stops the queue: a running single file goes back to the front and is laid out again.
    @Test(.timeLimit(.minutes(1))) func stoppedQueueRequeuesRunningSingleFile() async throws {
        let folder = base.appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = FakeIndex()
        let layout = GatedOfficeLayout()
        let m = model(layout, openIndex: { _ in index })
        await m.add([folder])
        await m.waitUntilIdle()
        layout.hold = true
        await m.add([try vertrag()])
        #expect(await eventually { layout.count == 1 })
        let delete = Task { await m.deleteIndex() }
        #expect(await eventually { layout.cancelled == 1 })
        layout.hold = false
        await delete.value
        await m.waitUntilIdle()
        #expect(layout.count == 2)
        m.queryText = "Kündigungsfrist"
        index.hits = []
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["Vertrag.docx"])
    }

    @Test(.timeLimit(.minutes(1))) func reAddingRetriesFileLeftWaitingAfterOtherError() async throws {
        let docx = try vertrag()
        let layout = GatedOfficeLayout()
        layout.failOtherOnce = true
        let m = model(layout)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(layout.count == 1)
        #expect(m.hits.first?.pageCount == 0)
        #expect(m.hits.first?.isUnreadable == false)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(layout.count == 2)
        #expect(m.hits.first?.pageCount == 1)
    }
}
