import CoreGraphics
import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// A gate an async fake waits on; opened by the test. Never blocks a thread.
final class AsyncGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s in s.open = true; defer { s.waiters = [] }; return s.waiters }
        for waiter in waiters { waiter.resume() }
    }
}

/// Scriptable `PageLayoutSource`: answers by file name, records calls and concurrency.
final class FakeLayout: PageLayoutSource {
    enum Answer: Sendable {
        case pages([String])
        case unreadable
        case transientError
        /// Ignores cancellation: waits for the gate, then answers `pages`.
        case uncooperative(AsyncGate, [String])
        /// Honours cancellation: sleeps (Task.sleep) for the duration, then answers `pages`.
        case slow(Duration, [String])
        /// Waits for the gate (ignores cancellation, like `uncooperative`), then answers `pages`.
        case wait(AsyncGate, [String])
        /// Runs `body` (side effects such as deleting the file or touching the index), returns its pages.
        case run(@Sendable (URL) throws -> [String])
        /// Touches the file (new modification date) during layout, then answers `pages`.
        case touchFile([String])
    }
    private struct State { var calls: [String] = []; var finished: [String] = []; var cancelled: [String] = []; var running = 0; var maxRunning = 0 }
    private let state = Mutex(State())
    private let answers: @Sendable (URL) -> Answer
    private let versions: [DocumentKind: Int]
    private let names: [DocumentKind: String]
    let delay: Duration

    struct Transient: Error {}

    init(delay: Duration = .zero, versions: [DocumentKind: Int] = [:], names: [DocumentKind: String] = [:],
         answers: @escaping @Sendable (URL) -> Answer = { url in .pages(["gesetzt \(url.deletingPathExtension().lastPathComponent)"]) }) {
        self.delay = delay
        self.versions = versions
        self.names = names
        self.answers = answers
    }

    var calls: [String] { state.withLock { $0.calls } }
    var finished: [String] { state.withLock { $0.finished } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (names[kind] ?? "quicklook", versions[kind] ?? 1) }

    private let stale = Mutex<[DocumentKind: [String]]>([:])
    /// Renderer names this source reports as stale (1.3.2: Word laid out with substitute fonts, once the fonts are there).
    func setStale(_ names: [String], for kind: DocumentKind) { stale.withLock { $0[kind] = names } }
    func staleRenderers(for kind: DocumentKind) -> [String] { stale.withLock { $0[kind] ?? [] } }

    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let name = url.lastPathComponent
        state.withLock { $0.calls.append(name); $0.running += 1; $0.maxRunning = max($0.maxRunning, $0.running) }
        defer { state.withLock { $0.running -= 1; $0.finished.append(name) } }
        if delay > .zero { try await Task.sleep(for: delay) }
        let texts: [String]
        switch answers(url) {
        case .pages(let t): texts = t
        case .unreadable: throw LayoutSourceError.unreadable(url, reason: "kaputt")
        case .transientError: throw Transient()
        case .uncooperative(let gate, let t):
            await gate.wait()
            texts = t
        case .slow(let duration, let t):
            do { try await Task.sleep(for: duration) } catch {
                state.withLock { $0.cancelled.append(name) }
                throw error
            }
            texts = t
        case .wait(let gate, let t):
            await gate.wait()
            texts = t
        case .run(let body):
            texts = try body(url)
        case .touchFile(let t):
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
            texts = t
        }
        return LayoutResult(pages: texts.map { LaidOutPage(text: $0, words: [], size: CGSize(width: 595, height: 842)) },
                            renderer: names[kind] ?? "quicklook", layoutVersion: versions[kind] ?? 1)
    }
}

/// Fails the test if asked to read anything but a PDF.
private struct PDFOnlyTextSource: TextSource {
    let inner = PDFKitTextSource()
    func pages(of url: URL) throws -> [PageText] {
        #expect(url.pathExtension.lowercased() == "pdf", "TextSource called for \(url.lastPathComponent)")
        return try inner.pages(of: url)
    }
}

@Suite("Indexer layout phase")
struct IndexerLayoutTests {
    struct Env {
        let root: URL
        let store: IndexStore
        func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory()
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Env(root: root, store: try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root))
    }

    /// The fake never reads the file; any bytes do.
    func addOffice(_ env: Env, _ name: String, content: String = "office") throws {
        try Data(content.utf8).write(to: env.url(name))
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func doc(_ env: Env, _ path: String) throws -> StoredDocument {
        try #require(try env.store.documents().first { $0.relativePath == path })
    }

    @Test func officeFilesLaidOutAfterTextPhase() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        try PDFFixtures.makePDF(at: env.url("vertrag.pdf"), pages: ["Dieser Vertrag hat genug Text für die Seite"])
        try OCRFixtures.write(try OCRFixtures.textImage(["Bild"], size: CGSize(width: 200, height: 100), fontSize: 20).image,
                              to: env.url("foto.png"), type: .png)
        let fake = FakeLayout()
        let ocr = StubOCR()
        let log = Mutex<[IndexProgress]>([])
        let report = try await Indexer(root: env.root, store: env.store, source: PDFOnlyTextSource(), ocr: ocr, layout: fake)
            .update { p in log.withLock { $0.append(p) } }

        #expect(Set(fake.calls) == ["brief.docx", "folien.pptx"])
        #expect(ocr.calls == ["foto.png#0"]) // office pages never go through OCR
        #expect(report.added == 4 && report.noText.isEmpty && report.failed.isEmpty)
        #expect(report.layout == LayoutReport(laidOut: 2))
        #expect(try env.store.match("gesetzt", in: .words).count == 2)
        let brief = try doc(env, "brief.docx")
        #expect(brief.status == .ok && brief.pageCount == 1 && brief.renderer == "quicklook" && brief.layoutVersion == 1)
        #expect(try env.store.pendingLayoutJobs().isEmpty)

        let all = log.withLock { $0 }
        let phases = all.map(\.phase).reduce(into: [IndexPhase]()) { if $0.last != $1 { $0.append($1) } }
        #expect(phases == [.text, .layout, .ocr])
        let layout = all.filter { $0.phase == .layout }
        #expect(layout.first == IndexProgress(done: 0, total: 2, currentFile: nil, phase: .layout))
        #expect(layout.count == 3 && layout.last?.done == 2)
        #expect(Set(layout.compactMap(\.currentFile)) == ["brief.docx", "folien.pptx"])
    }

    /// Merge 1.2.1 (Task 12): a queue over several sources runs phase 1 of all, then the layouts, then
    /// recognition — `update` without layout, then `layOutPending`, then `recognizePending`.
    @Test func layoutSplitFromUpdateForQueueOrder() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try PDFFixtures.makePDF(at: env.url("vertrag.pdf"), pages: ["Dieser Vertrag hat genug Text für die Seite"])
        try OCRFixtures.write(try OCRFixtures.textImage(["Bild"], size: CGSize(width: 200, height: 100), fontSize: 20).image,
                              to: env.url("foto.png"), type: .png)
        let fake = FakeLayout()
        let ocr = StubOCR()
        let indexer = Indexer(root: env.root, store: env.store, source: PDFOnlyTextSource(), ocr: ocr,
                              ocrSettings: OCRSettings(recognizeText: false, includeImages: true),
                              layout: fake, layoutDuringUpdate: false)
        let log = Mutex<[IndexPhase]>([])
        let report = try await indexer.update { p in log.withLock { $0.append(p.phase) } }
        #expect(report.added == 3 && report.layout == LayoutReport())
        #expect(fake.calls.isEmpty && ocr.calls.isEmpty)
        #expect(Set(log.withLock { $0 }) == [.text])
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["brief.docx"])
        #expect(try env.store.match("gesetzt", in: .words).isEmpty)

        let layout = try await indexer.layOutPending { p in #expect(p.phase == .layout) }
        #expect(layout == LayoutReport(laidOut: 1))
        #expect(fake.calls == ["brief.docx"] && ocr.calls.isEmpty)
        #expect(try env.store.match("gesetzt", in: .words).count == 1)

        _ = try await indexer.recognizePending { p in #expect(p.phase == .ocr) }
        #expect(ocr.calls == ["foto.png#0"])  // office pages never go through OCR
        #expect(try await Indexer(root: env.root, store: env.store).layOutPending { _ in } == LayoutReport())
    }

    /// 1.2.1 reports every document without text after recognition; Office documents (waiting for layout,
    /// or laid out without text) belong to the layout report, never to the OCR report.
    @Test func ocrReportLeavesOfficeOut() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "wartet.docx")
        try addOffice(env, "leer.pptx")
        let fake = FakeLayout { url in url.pathExtension == "pptx" ? .pages([""]) : .pages(["Text"]) }
        let ocr = StubOCR()
        let first = try await Indexer(root: env.root, store: env.store, ocr: ocr, layout: fake).update { _ in }
        #expect(first.layout.noText == ["leer.pptx"])
        #expect(first.ocr.noText.isEmpty && first.ocr.failed.isEmpty)
        try addOffice(env, "neu.docx")
        _ = try await Indexer(root: env.root, store: env.store, ocr: ocr, layout: fake, layoutDuringUpdate: false).update { _ in }
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["neu.docx"])
        let report = try await Indexer(root: env.root, store: env.store, ocr: ocr, layout: fake).recognizePending { _ in }
        #expect(report.noText.isEmpty && report.failed.isEmpty)
        #expect(ocr.calls.isEmpty)
    }

    @Test func secondRunDoesNotLayoutAgain() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        _ = try await Indexer(root: env.root, store: env.store, layout: FakeLayout()).update { _ in }
        let second = FakeLayout()
        let report = try await Indexer(root: env.root, store: env.store, layout: second).update { _ in }
        #expect(second.calls.isEmpty)
        #expect(report.unchanged == 2 && report.layout == LayoutReport())
        #expect(try doc(env, "brief.docx").renderer == "quicklook") // layout kept, not cleared by an upsert
        #expect(try env.store.match("gesetzt", in: .words).count == 2)
    }

    @Test func changedFileIsLaidOutAgain() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "anderer.docx")
        _ = try await Indexer(root: env.root, store: env.store, layout: FakeLayout()).update { _ in }
        try addOffice(env, "brief.docx", content: "neue Fassung")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: env.url("brief.docx").path)
        let second = FakeLayout { _ in .pages(["zweite Fassung"]) }
        let report = try await Indexer(root: env.root, store: env.store, layout: second).update { _ in }
        #expect(second.calls == ["brief.docx"])
        #expect(report.updated == 1 && report.layout.laidOut == 1)
        #expect(try env.store.match("Fassung", in: .words).count == 1)
    }

    /// 1.3.2 (fonts-start e): documents stored by a renderer the source now calls stale (Word laid out with substitute
    /// fonts, after a successful font registration) are laid out again at the next run – and only while it says so.
    @Test func staleRendererDocumentsAreLaidOutAgain() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "ersatz.docx")
        try addOffice(env, "gut.docx")
        try addOffice(env, "folien.pptx")
        let first = FakeLayout(names: [.word: "textkit"]) { url in
            .pages(["gesetzt \(url.deletingPathExtension().lastPathComponent)"])
        }
        _ = try await Indexer(root: env.root, store: env.store, layout: first).update { _ in }
        // Mark one Word document as laid out with substitute fonts (as TextKitWordSource stores it).
        let marked = FakeSubstituteLayout()
        try env.store.requestLayout(relativePath: "ersatz.docx")
        _ = try await Indexer(root: env.root, store: env.store, layout: marked).update { _ in }
        #expect(try doc(env, "ersatz.docx").renderer == FakeSubstituteLayout.substitute)
        #expect(try doc(env, "gut.docx").renderer == "textkit")

        // Fonts not there yet: nothing is stale, nothing laid out again.
        let notYet = FakeLayout(names: [.word: "textkit"])
        _ = try await Indexer(root: env.root, store: env.store, layout: notYet).update { _ in }
        #expect(notYet.calls.isEmpty)

        // Fonts registered: only the substitute document again.
        let ready = FakeLayout(names: [.word: "textkit"])
        ready.setStale([FakeSubstituteLayout.substitute], for: .word)
        let report = try await Indexer(root: env.root, store: env.store, layout: ready).update { _ in }
        #expect(ready.calls == ["ersatz.docx"])
        #expect(report.layout.laidOut == 1)
        #expect(try doc(env, "ersatz.docx").renderer == "textkit")
        // And it settles.
        let again = FakeLayout(names: [.word: "textkit"])
        again.setStale([FakeSubstituteLayout.substitute], for: .word)
        _ = try await Indexer(root: env.root, store: env.store, layout: again).update { _ in }
        #expect(again.calls.isEmpty)
    }

    @Test func newerRendererVersionTriggersRelayout() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        _ = try await Indexer(root: env.root, store: env.store, layout: FakeLayout()).update { _ in }
        // Same renderer name for both kinds, but only the Word renderer was upgraded.
        let upgraded = FakeLayout(versions: [.word: 2, .powerpoint: 1])
        let report = try await Indexer(root: env.root, store: env.store, layout: upgraded).update { _ in }
        #expect(upgraded.calls == ["brief.docx"])
        #expect(report.unchanged == 2 && report.layout.laidOut == 1)
        #expect(try doc(env, "brief.docx").layoutVersion == 2)
        #expect(try doc(env, "folien.pptx").layoutVersion == 1)
        // And it settles: a third run does nothing.
        let third = FakeLayout(versions: [.word: 2, .powerpoint: 1])
        _ = try await Indexer(root: env.root, store: env.store, layout: third).update { _ in }
        #expect(third.calls.isEmpty)
    }

    @Test func rendererChangeRelaysOutEveryDocumentOfThatKind() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "kaputt.docx")
        try addOffice(env, "folien.pptx")
        let first = FakeLayout(names: [.word: "textkit"]) { url in
            url.lastPathComponent == "kaputt.docx" ? .unreadable : .pages(["gesetzt"])
        }
        _ = try await Indexer(root: env.root, store: env.store, layout: first).update { _ in }
        #expect(try doc(env, "kaputt.docx").status == .error)
        // Another Word renderer (same version): all Word documents again, the failed one too.
        let wordkit = FakeLayout(names: [.word: "wordkit"])
        let report = try await Indexer(root: env.root, store: env.store, layout: wordkit).update { _ in }
        #expect(Set(wordkit.calls) == ["brief.docx", "kaputt.docx"])
        #expect(report.layout.laidOut == 2 && report.unchanged == 3)
        #expect(try doc(env, "kaputt.docx").status == .ok && doc(env, "kaputt.docx").renderer == "wordkit")
        #expect(try doc(env, "folien.pptx").renderer == "quicklook")
        #expect(try env.store.layoutRenderer(for: .word) == "wordkit:1")
        // Settles: same renderers again → nothing.
        let again = FakeLayout(names: [.word: "wordkit"])
        _ = try await Indexer(root: env.root, store: env.store, layout: again).update { _ in }
        #expect(again.calls.isEmpty)
    }

    /// 1.3 Teil B Task 12: another PowerPoint renderer (e.g. own viewer ↔ Quick Look) must not leave words of the old
    /// layout searchable while the decks wait (their tiles and highlights already follow the new renderer).
    @Test func powerPointRendererChangeClearsOldText() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        _ = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .pages(["Altfassung"]) }).update { _ in }
        #expect(try env.store.match("Altfassung", in: .words).count == 2)
        // New PowerPoint renderer; this run cannot lay the deck out (passing error): it waits, without its old text.
        let other = FakeLayout(names: [.powerpoint: "slidekit"]) { url in url.pathExtension == "pptx" ? .transientError : .pages(["neu"]) }
        _ = try await Indexer(root: env.root, store: env.store, layout: other).update { _ in }
        #expect(other.calls == ["folien.pptx"])
        let deck = try doc(env, "folien.pptx")
        #expect(deck.pageCount == 0 && deck.renderer == nil)
        #expect(try env.store.match("Altfassung", in: .words).count == 1, "only the Word page is left")
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["folien.pptx"])
        // A first recorded renderer (fresh index) clears nothing: covered by firstRunRecordsRenderersWithoutExtraWork.
    }

    /// Review 2: the reset and the new expected renderer are stored together; a failing reset keeps the old one, so the
    /// next run tries again (old words never stay searchable under the new identity).
    @Test func failedResetKeepsOldRendererForNextRun() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "folien.pptx")
        _ = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .pages(["Altfassung"]) }).update { _ in }
        try env.store.batch { db in
            try db.run("CREATE TEMP TRIGGER kein_loeschen BEFORE DELETE ON page_text BEGIN SELECT RAISE(ABORT, 'kaputt'); END", [])
        }
        let other = FakeLayout(names: [.powerpoint: "slidekit"])
        await #expect(throws: (any Error).self) { _ = try await Indexer(root: env.root, store: env.store, layout: other).update { _ in } }
        #expect(try env.store.layoutRenderer(for: .powerpoint) == "quicklook:1")
        #expect(other.calls.isEmpty)
        try env.store.batch { db in try db.run("DROP TRIGGER kein_loeschen", []) }
        let again = FakeLayout(names: [.powerpoint: "slidekit"]) { _ in .transientError }
        _ = try await Indexer(root: env.root, store: env.store, layout: again).update { _ in }
        #expect(try env.store.layoutRenderer(for: .powerpoint) == "slidekit:1")
        #expect(try env.store.match("Altfassung", in: .words).isEmpty)
    }

    @Test func firstRunRecordsRenderersWithoutExtraWork() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        let fake = FakeLayout(names: [.word: "textkit"])
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(fake.calls.sorted() == ["brief.docx", "folien.pptx"] && report.layout.laidOut == 2)
        #expect(try env.store.layoutRenderer(for: .word) == "textkit:1")
        #expect(try env.store.layoutRenderer(for: .powerpoint) == "quicklook:1")
    }

    @Test func unreadableMarksError() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "kaputt.docx")
        try addOffice(env, "gut.pptx")
        let fake = FakeLayout { url in url.lastPathComponent == "kaputt.docx" ? .unreadable : .pages(["Folie"]) }
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(report.layout.failed == ["kaputt.docx"] && report.layout.laidOut == 1)
        #expect(report.failed.isEmpty && report.noText.isEmpty)
        #expect(try doc(env, "kaputt.docx").status == .error)
        #expect(try env.store.pendingLayoutJobs().isEmpty)
        let again = FakeLayout()
        _ = try await Indexer(root: env.root, store: env.store, layout: again).update { _ in }
        #expect(again.calls.isEmpty) // not retried until the file changes
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutMarksError() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "haengt.docx")
        try addOffice(env, "langsam.pptx")
        try addOffice(env, "schnell.docx")
        let gate = AsyncGate()
        let fake = FakeLayout { url in
            switch url.lastPathComponent {
            case "haengt.docx": .uncooperative(gate, ["spätes Ergebnis"])
            case "langsam.pptx": .slow(.seconds(30), ["spätes Ergebnis"])
            default: .pages(["schnell gesetzt"])
            }
        }
        // 400 ms: `schnell.docx` starts only after a hanging file timed out and must finish within
        // the same limit, also on a loaded machine.
        let report = try await Indexer(root: env.root, store: env.store, layout: fake, layoutTimeout: .milliseconds(400))
            .update { _ in }
        #expect(report.layout.failed == ["haengt.docx", "langsam.pptx"])
        #expect(report.layout.laidOut == 1)
        #expect(try doc(env, "haengt.docx").status == .error)
        #expect(try env.store.pendingLayoutJobs().isEmpty)
        try await waitUntil { fake.cancelled == ["langsam.pptx"] } // the timed-out task was cancelled

        // The uncooperative layout finishes later: its result must not be stored.
        gate.open()
        try await waitUntil { fake.finished.contains("haengt.docx") }
        try await Task.sleep(for: .milliseconds(100))
        let haengt = try doc(env, "haengt.docx")
        #expect(haengt.status == .error && haengt.pageCount == 0 && haengt.renderer == nil)
        #expect(try env.store.match("spätes", in: .words).isEmpty)
    }

    @Test func transientErrorRetriedNextRun() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        let report = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .transientError }).update { _ in }
        #expect(report.layout.deferred == 1 && report.layout.failed.isEmpty && report.layout.laidOut == 0)
        #expect(report.noText.isEmpty && report.layout.noText.isEmpty)
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["brief.docx"])
        let retry = FakeLayout()
        let second = try await Indexer(root: env.root, store: env.store, layout: retry).update { _ in }
        #expect(retry.calls == ["brief.docx"] && second.layout.laidOut == 1)
    }

    @Test func emptyLayoutIsNoText() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "leer.pptx")
        let report = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .pages(["", ""]) }).update { _ in }
        #expect(report.layout.noText == ["leer.pptx"] && report.layout.laidOut == 1)
        #expect(try doc(env, "leer.pptx").status == .noText)
    }

    @Test func atMostTwoConcurrent() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        for i in 0..<6 { try addOffice(env, "datei\(i).docx") }
        let fake = FakeLayout(delay: .milliseconds(50))
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(fake.calls.count == 6 && report.layout.laidOut == 6)
        #expect(fake.maxRunning == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationKeepsFinishedFiles() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        for i in 0..<6 { try addOffice(env, "datei\(i).docx") }
        let gate = AsyncGate()
        // Others take 0.1 s each, so the later ones are still queued when the cancel lands.
        let fake = FakeLayout(delay: .milliseconds(100)) { url in
            url.lastPathComponent == "datei2.docx" ? .wait(gate, ["spät"]) : .pages(["fertig"])
        }
        let indexer = Indexer(root: env.root, store: env.store, layout: fake)
        let task = Task { try await indexer.update { _ in } }
        try await waitUntil { fake.calls.contains("datei2.docx") }
        task.cancel()
        // Returns without waiting for the layout running at cancel (it ignores cancellation).
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        gate.open()
        let pending = Set(try env.store.pendingLayoutJobs().map(\.relativePath))
        let stored = Set(try env.store.documents().filter { $0.renderer != nil }.map(\.relativePath))
        #expect(pending.contains("datei2.docx")) // running at cancel: dropped, queued for the next run
        #expect(stored.isSubset(of: Set(fake.calls)) && !stored.isEmpty) // finished before the cancel: kept
        #expect(pending.count + stored.count == 6)
        try await waitUntil { fake.finished.contains("datei2.docx") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try env.store.match("spät", in: .words).isEmpty) // its late result is never stored
        // The next run continues with exactly the rest.
        let next = FakeLayout()
        _ = try await Indexer(root: env.root, store: env.store, layout: next).update { _ in }
        #expect(Set(next.calls) == pending)
        #expect(try env.store.pendingLayoutJobs().isEmpty)
    }

    /// Stopping a run does not wait for a long layout (a deck takes seconds, at worst the time limit).
    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsRunningLayoutPromptly() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "lang.pptx")
        let fake = FakeLayout { _ in .slow(.seconds(10), ["spät"]) }
        let indexer = Indexer(root: env.root, store: env.store, layout: fake)
        let task = Task { try await indexer.update { _ in } }
        try await waitUntil { fake.calls.contains("lang.pptx") }
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - start < .seconds(1))
        try await waitUntil { fake.cancelled == ["lang.pptx"] } // the source saw the cancellation
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["lang.pptx"])
        #expect(try doc(env, "lang.pptx").renderer == nil)
    }

    @Test func layoutResultIgnoredWhenFileChanged() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        let fake = FakeLayout { _ in .touchFile(["alte Fassung"]) }
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(fake.calls == ["brief.docx"])
        #expect(report.layout.laidOut == 0 && report.layout.failed.isEmpty)
        #expect(try env.store.match("Fassung", in: .words).isEmpty)
        #expect(try doc(env, "brief.docx").renderer == nil)
        // The next run sees the changed file and lays it out again.
        let next = FakeLayout { _ in .pages(["neue Fassung"]) }
        let second = try await Indexer(root: env.root, store: env.store, layout: next).update { _ in }
        #expect(second.updated == 1 && second.layout.laidOut == 1 && next.calls == ["brief.docx"])
        #expect(try env.store.match("neue", in: .words).count == 1)
    }

    @Test func fileDeletedDuringLayoutIsNotStored() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "weg.docx")
        let fake = FakeLayout { _ in .run { url in try FileManager.default.removeItem(at: url); return ["weg"] } }
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(report.layout == LayoutReport(deferred: 1))
        #expect(try env.store.match("weg", in: .words).isEmpty)
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["weg.docx"]) // until the next scan
        let next = FakeLayout()
        let second = try await Indexer(root: env.root, store: env.store, layout: next).update { _ in }
        #expect(second.removed == 1 && next.calls.isEmpty)
        #expect(try env.store.documents().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func wipeDuringLayoutStopsAndStartsOver() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        for i in 0..<6 { try addOffice(env, "datei\(i).docx") }
        let store = env.store
        let wiped = Mutex(false)
        let fake = FakeLayout(delay: .milliseconds(20)) { url in
            .run { url in
                if url.lastPathComponent == "datei1.docx", !wiped.withLock({ let was = $0; $0 = true; return was }) {
                    try? store.deleteIndex() // once, like a damage rebuild in a concurrent search
                }
                return ["gesetzt \(url.lastPathComponent)"]
            }
        }
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        // Pass 1 stops starting new files after the wipe; pass 2 indexes and lays out everything.
        #expect(fake.calls.count < 12, "\(fake.calls)")
        #expect(try env.store.pendingLayoutJobs().isEmpty)
        #expect(try env.store.documents().count == 6)
        #expect(report.layout.laidOut == 6)
        // Nothing stale from pass 1: exactly one page per document.
        #expect(try env.store.allPages().count == 6)
    }

    @Test func sourceCancellationStopsRun() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        let fake = FakeLayout { _ in .run { _ in throw CancellationError() } }
        await #expect(throws: CancellationError.self) {
            _ = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        }
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["brief.docx"])
        let next = FakeLayout()
        let second = try await Indexer(root: env.root, store: env.store, layout: next).update { _ in }
        #expect(next.calls == ["brief.docx"] && second.layout.laidOut == 1)
    }

    /// The document changed in the index while its layout failed: nothing is written, so it is not
    /// reported as failed either.
    @Test func staleFailureIsNotReported() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "kaputt.docx")
        let store = env.store
        let fake = FakeLayout { _ in
            .run { url in
                try store.remove(relativePaths: ["kaputt.docx"])
                throw LayoutSourceError.unreadable(url, reason: "kaputt")
            }
        }
        let report = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(report.layout.failed.isEmpty)
        #expect(try env.store.documents().isEmpty)
    }

    @Test func withoutLayoutSourceOfficeFilesNotListed() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        try addOffice(env, "folien.pptx")
        try PDFFixtures.makePDF(at: env.url("vertrag.pdf"), pages: ["Dieser Vertrag hat genug Text für die Seite"])
        let log = Mutex<[IndexProgress]>([])
        let report = try await Indexer(root: env.root, store: env.store, source: PDFOnlyTextSource())
            .update { p in log.withLock { $0.append(p) } }
        #expect(try env.store.documents().map(\.relativePath) == ["vertrag.pdf"])
        #expect(report.added == 1 && report.layout == LayoutReport())
        #expect(!log.withLock { $0 }.contains { $0.phase == .layout })
    }

    /// An Office file listed by an explicit scanner without a layout source waits for a later
    /// run with one; it never reaches the TextSource.
    @Test func officeFileWithoutLayoutSourceWaits() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "brief.docx")
        let report = try await Indexer(root: env.root, store: env.store, source: PDFOnlyTextSource(),
                                       scanner: FolderScanner(includeOffice: true)).update { _ in }
        #expect(report.added == 1 && report.noText.isEmpty)
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["brief.docx"])
        let fake = FakeLayout()
        let later = try await Indexer(root: env.root, store: env.store, layout: fake).update { _ in }
        #expect(fake.calls == ["brief.docx"] && later.unchanged == 1 && later.layout.laidOut == 1)
    }

    /// 1.3 Teil B: like OCR (1.2.1 `problems(in:report:)`), the layout report's problem lists describe the whole
    /// index after every run, so a cancelled run loses none; documents still waiting are in neither list.
    @Test(.timeLimit(.minutes(1)))
    func layoutProblemsComeFromWholeIndex() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addOffice(env, "x.pptx")
        try addOffice(env, "y.docx")
        try addOffice(env, "z.docx")
        let fake = FakeLayout { url in
            switch url.lastPathComponent {
            case "x.pptx": .unreadable
            case "y.docx": .pages([""])
            default: .slow(.seconds(10), ["spät"])
            }
        }
        let indexer = Indexer(root: env.root, store: env.store, layout: fake)
        let task = Task { try await indexer.update { _ in } }
        try await waitUntil { fake.finished.contains("x.pptx") && fake.finished.contains("y.docx") && fake.calls.contains("z.docx") }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        // Run 2 without any waiting file (z is gone): the problems of run 1 are reported.
        try FileManager.default.removeItem(at: env.url("z.docx"))
        let second = try await Indexer(root: env.root, store: env.store, layout: FakeLayout()).update { _ in }
        #expect(second.layout == LayoutReport(failed: ["x.pptx"], noText: ["y.docx"]))

        // A file that stays waiting (passing error) appears in neither list.
        try addOffice(env, "w.docx")
        let third = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .transientError }).update { _ in }
        #expect(third.layout == LayoutReport(failed: ["x.pptx"], noText: ["y.docx"], deferred: 1))
        #expect(try env.store.pendingLayoutJobs().map(\.relativePath) == ["w.docx"])
        let pending = try await Indexer(root: env.root, store: env.store, layout: FakeLayout { _ in .transientError })
            .layOutPending { _ in }
        #expect(pending == LayoutReport(failed: ["x.pptx"], noText: ["y.docx"], deferred: 1))
    }
}

/// Lays out Word as `textkit` with the substitute-font marker (renderer name), like `TextKitWordSource` past the gate.
private struct FakeSubstituteLayout: PageLayoutSource {
    static let substitute = "textkit-substitute"
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (kind == .word ? "textkit" : "quicklook", 1) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "ersatz", words: [], size: CGSize(width: 595, height: 842))],
                     renderer: kind == .word ? Self.substitute : "quicklook", layoutVersion: 1)
    }
}
