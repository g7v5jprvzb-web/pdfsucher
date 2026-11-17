import CoreGraphics
import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport
import UniformTypeIdentifiers

/// Scriptable OCR stand-in: answers by file name, records calls and concurrency.
final class StubOCR: OCRSource, Sendable {
    enum Answer: Sendable { case text(String), unreadable, transientError, wait(DispatchSemaphore, String) }
    private struct State { var calls: [String] = []; var running = 0; var maxRunning = 0 }
    private let state = Mutex(State())
    private let answers: @Sendable (URL, Int) -> Answer
    let delay: TimeInterval

    init(delay: TimeInterval = 0, answers: @escaping @Sendable (URL, Int) -> Answer = { url, page in
        .text("erkannt \(url.deletingPathExtension().lastPathComponent) seite \(page)")
    }) {
        self.answers = answers
        self.delay = delay
    }

    var calls: [String] { state.withLock { $0.calls } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    struct Transient: Error {}

    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult {
        state.withLock { $0.calls.append("\(url.lastPathComponent)#\(pageIndex)"); $0.running += 1; $0.maxRunning = max($0.maxRunning, $0.running) }
        defer { state.withLock { $0.running -= 1 } }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch answers(url, pageIndex) {
        case .text(let text):
            return OCRResult(text: text, words: text.isEmpty ? [] : [OCRWord(range: NSRange(location: 0, length: 1), box: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))])
        case .unreadable: throw OCRSourceError.unreadable(url)
        case .transientError: throw Transient()
        case .wait(let gate, let text):
            gate.wait()
            return OCRResult(text: text, words: [])
        }
    }
}

/// Fails the test if asked to read an image as PDF.
private struct PDFOnlySource: TextSource {
    let inner = PDFKitTextSource()
    func pages(of url: URL) throws -> [PageText] {
        let ext = url.pathExtension.lowercased()
        #expect(ext == "pdf", "TextSource called for \(url.lastPathComponent)")
        return try inner.pages(of: url)
    }
}

@Suite("Indexer OCR")
struct IndexerOCRTests {
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

    static let longText = "Dieser Vertrag hat genug Text für die erste Seite"

    func addMixedPDF(_ env: Env, _ name: String = "gemischt.pdf") throws {
        try OCRFixtures.makeMixedPDF(at: env.url(name), text: Self.longText,
                                     image: try OCRFixtures.textImage(["Scan"], size: CGSize(width: 200, height: 100), fontSize: 20).image)
    }

    func addImage(_ env: Env, _ name: String) throws {
        try OCRFixtures.write(try OCRFixtures.textImage(["Bild"], size: CGSize(width: 200, height: 100), fontSize: 20).image,
                              to: env.url(name), type: .png)
    }

    static let textOnly = OCRSettings(recognizeText: false, includeImages: true)

    // MARK: Phase 1 marking (Task 4)

    @Test func scanPagesAreMarkedForOCR() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        try OCRFixtures.makeScanPDF(at: env.url("scan.pdf"), images: [try OCRFixtures.textImage(["x"]).image])
        let indexer = Indexer(root: env.root, store: env.store, source: PDFOnlySource(), ocr: StubOCR(), ocrSettings: Self.textOnly)
        let report = try await indexer.update { _ in }
        #expect(try env.store.pendingOCRJobs().map { "\($0.relativePath)#\($0.pageIndex)" } == ["gemischt.pdf#1", "scan.pdf#0"])
        #expect(report.noText == ["scan.pdf"]) // recognition is off: reported like 1.0
        #expect(report.added == 2)
    }

    /// Indexes built before the app passes an OCRSource (1.1 builds with schema 2) must still
    /// queue their scan pages, or a later 1.2 would never recognize them (files unchanged).
    @Test func pagesAreQueuedEvenWithoutOCRSource() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        try OCRFixtures.makeScanPDF(at: env.url("scan.pdf"), images: [try OCRFixtures.textImage(["x"]).image])
        try addImage(env, "bild.png")
        let report = try await Indexer(root: env.root, store: env.store).update { _ in }
        #expect(try env.store.pendingOCRJobs().map { "\($0.relativePath)#\($0.pageIndex)" } == ["gemischt.pdf#1", "scan.pdf#0"])
        #expect(report.noText == ["scan.pdf"]) // as in 1.0: no recognition will run
        #expect(try env.store.documents().map(\.relativePath) == ["gemischt.pdf", "scan.pdf"]) // no images without OCR
        // A later run with OCR recognizes them although the files did not change.
        let stub = StubOCR()
        let later = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(Set(stub.calls).isSuperset(of: ["gemischt.pdf#1", "scan.pdf#0"]))
        #expect(later.ocr.recognized == 3) // two pages plus the image now listed
    }

    @Test func recognitionOffKeepsScansInNoTextList() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try OCRFixtures.makeScanPDF(at: env.url("scan.pdf"), images: [try OCRFixtures.textImage(["x"]).image])
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR(), ocrSettings: Self.textOnly).update { _ in }
        #expect(report.noText == ["scan.pdf"])
        #expect(try env.store.pendingOCRJobs().count == 1)
    }

    @Test func imageGetsOnePendingPage() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "bild.PNG")
        let indexer = Indexer(root: env.root, store: env.store, source: PDFOnlySource(), ocr: StubOCR(), ocrSettings: Self.textOnly)
        let report = try await indexer.update { _ in }
        let doc = try #require(try env.store.documents().first)
        #expect(doc.kind == .image && doc.pageCount == 1)
        #expect(try env.store.pendingOCRJobs().count == 1)
        #expect(report.added == 1 && report.noText.isEmpty && report.failed.isEmpty)
    }

    @Test func imagesOffLeavesImagesOut() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "bild.png")
        let indexer = Indexer(root: env.root, store: env.store, ocr: StubOCR(),
                              ocrSettings: OCRSettings(recognizeText: true, includeImages: false))
        _ = try await indexer.update { _ in }
        #expect(try env.store.documents().isEmpty)
    }

    // MARK: Phase 2 (Task 5)

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func ocrTextBecomesSearchable() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        try addImage(env, "foto.png")
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        #expect(try env.store.match("erkannt", in: .words).count == 2)
        #expect(try env.store.pendingOCRJobs().isEmpty)
        #expect(report.ocr.recognized == 2 && report.ocr.noText.isEmpty && report.ocr.failed.isEmpty && report.ocr.deferred == 0)
        let docs = try env.store.documents()
        #expect(docs.allSatisfy { $0.status == .ok })
        let image = try #require(docs.first { $0.kind == .image })
        #expect(try env.store.ocrWords(docId: image.id, pageIndex: 0).count == 1)
    }

    @Test func secondRunRecognizesNothing() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        try addImage(env, "foto.png")
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        let second = StubOCR()
        let report = try await Indexer(root: env.root, store: env.store, ocr: second).update { _ in }
        #expect(second.calls.isEmpty)
        #expect(report.unchanged == 2 && report.ocr == OCRReport())
    }

    @Test func changedFileIsRecognizedAgain() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "foto.png")
        try addImage(env, "anderes.png")
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        try OCRFixtures.write(try OCRFixtures.textImage(["Neu"], size: CGSize(width: 300, height: 100), fontSize: 20).image,
                              to: env.url("foto.png"), type: .png)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: env.url("foto.png").path)
        let second = StubOCR { _, _ in .text("zweite Fassung") }
        let report = try await Indexer(root: env.root, store: env.store, ocr: second).update { _ in }
        #expect(second.calls == ["foto.png#0"])
        #expect(report.updated == 1 && report.ocr.recognized == 1)
        #expect(try env.store.match("Fassung", in: .words).count == 1)
    }

    /// 1.4.0 P7: at most `ocrParallelism` (2 to 4 by cores; it was 2 before) at once.
    @Test func atMostOCRParallelismAtOnce() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        for i in 0..<8 { try addImage(env, "bild\(i).png") }
        let stub = StubOCR(delay: 0.05)
        let report = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(stub.calls.count == 8 && report.ocr.recognized == 8)
        #expect(stub.maxRunning == Indexer.ocrParallelism)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelDuringOCRKeepsFinishedPages() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        for i in 0..<6 { try addImage(env, "bild\(i).png") }
        let gate = DispatchSemaphore(value: 0)
        // Others take 0.1 s each, so the later ones are still queued when the cancel lands.
        let stub = StubOCR(delay: 0.1) { url, _ in url.lastPathComponent == "bild2.png" ? .wait(gate, "spät") : .text("fertig") }
        let indexer = Indexer(root: env.root, store: env.store, ocr: stub)
        let task = Task { try await indexer.update { _ in } }
        try await waitUntil { stub.calls.contains("bild2.png#0") }
        task.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let pending = Set(try env.store.pendingOCRJobs().map(\.relativePath))
        let finished = Set(stub.calls.map { String($0.dropLast(2)) })
        #expect(pending.isDisjoint(with: finished)) // every started page was stored
        #expect(pending.count + finished.count == 6)
        #expect(!pending.isEmpty)
        // The next run continues with exactly the rest.
        let next = StubOCR()
        _ = try await Indexer(root: env.root, store: env.store, ocr: next).update { _ in }
        #expect(Set(next.calls.map { String($0.dropLast(2)) }) == pending)
        #expect(try env.store.pendingOCRJobs().isEmpty)
    }

    @Test func transientOCRErrorRetriesNextRun() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "foto.png")
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .transientError }).update { _ in }
        #expect(report.ocr.deferred == 1 && report.ocr.failed.isEmpty)
        #expect(report.ocr.noText.isEmpty) // still waiting, not „kein Text erkannt“
        #expect(try env.store.pendingOCRJobs().count == 1)
        let retry = StubOCR()
        let second = try await Indexer(root: env.root, store: env.store, ocr: retry).update { _ in }
        #expect(retry.calls == ["foto.png#0"] && second.ocr.recognized == 1)
    }

    @Test func unreadableImageIsFailed() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "kaputt.png")
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .unreadable }).update { _ in }
        #expect(report.ocr.failed == ["kaputt.png"])
        #expect(try env.store.documents().first?.status == .error)
        #expect(try env.store.pendingOCRJobs().isEmpty)
    }

    /// Final review minor: a run interrupted after finding problems throws away its report; the next run
    /// (with other jobs only) still lists every unreadable image and every document without text.
    @Test func laterRunStillListsEarlierProblems() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "kaputt.png")
        try addImage(env, "leer.png")
        let first = StubOCR { url, _ in url.lastPathComponent == "kaputt.png" ? .unreadable : .text("") }
        _ = try await Indexer(root: env.root, store: env.store, ocr: first).update { _ in }
        try addImage(env, "neu.png")
        let second = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        #expect(second.ocr.recognized == 1)
        #expect(second.ocr.failed == ["kaputt.png"])
        #expect(second.ocr.noText == ["leer.png"])
    }

    @Test func unreadablePDFPageCountsAsNothingFound() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .unreadable }).update { _ in }
        #expect(report.ocr.failed.isEmpty)
        #expect(try env.store.documents().first?.status == .ok) // page 0 still has its text
        #expect(try env.store.pendingOCRJobs().isEmpty)
    }

    @Test func nothingRecognizedIsNoText() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "leer.png")
        try OCRFixtures.makeScanPDF(at: env.url("leer.pdf"), images: [try OCRFixtures.textImage(["x"]).image])
        try addMixedPDF(env)
        let report = try await Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .text("") }).update { _ in }
        #expect(report.ocr.noText == ["leer.pdf", "leer.png"])
        #expect(report.ocr.recognized == 0)
    }

    @Test func progressReportsOCRPhase() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addMixedPDF(env)
        try addImage(env, "foto.png")
        let log = Mutex<[IndexProgress]>([])
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { p in log.withLock { $0.append(p) } }
        let all = log.withLock { $0 }
        let text = all.filter { $0.phase == .text }
        let ocr = all.filter { $0.phase == .ocr }
        #expect(text.first == IndexProgress(done: 0, total: 2, currentFile: nil))
        #expect(ocr.first == IndexProgress(done: 0, total: 2, currentFile: nil, phase: .ocr))
        #expect(ocr.last?.done == 2 && ocr.count == 3)
        #expect(all.firstIndex { $0.phase == .ocr }! > all.lastIndex { $0.phase == .text }!)
    }

    @Test func disabledOCRSkipsPhase2() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "foto.png")
        let stub = StubOCR()
        let report = try await Indexer(root: env.root, store: env.store, ocr: stub, ocrSettings: Self.textOnly).update { _ in }
        #expect(stub.calls.isEmpty && report.ocr == OCRReport())
        #expect(try env.store.pendingOCRJobs().count == 1) // waits until OCR is switched on
    }

    @Test func recognizePendingAfterReset() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try addImage(env, "foto.png")
        let indexer = Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .text("erste") })
        _ = try await indexer.update { _ in }
        try env.store.resetOCR()
        let again = Indexer(root: env.root, store: env.store, ocr: StubOCR { _, _ in .text("zweite") })
        let report = try await again.recognizePending { _ in }
        #expect(report.recognized == 1)
        #expect(try env.store.match("zweite", in: .words).count == 1)
        #expect(try env.store.match("erste", in: .words).isEmpty)
    }

    @Test func recognizePendingWithoutOCRSourceDoesNothing() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        #expect(try await Indexer(root: env.root, store: env.store).recognizePending { _ in } == OCRReport())
    }

    @Test(.timeLimit(.minutes(1)))
    func wipeDuringOCRStopsAndStartsOver() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        // 12 images (1.4.0: up to 4 recognitions at once): pass 1 must stop well before all of them.
        for i in 0..<12 { try addImage(env, "bild\(i).png") }
        let store = env.store
        let wiped = Mutex(false)
        let stub = StubOCR(delay: 0.05) { url, _ in
            if url.lastPathComponent == "bild1.png", !wiped.withLock({ let was = $0; $0 = true; return was }) {
                try? store.deleteIndex() // once, like a damage rebuild in a concurrent search
            }
            return .text("erkannt")
        }
        let report = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        // Pass 1 stops starting new pages after the wipe; pass 2 indexes and recognizes everything.
        #expect(stub.calls.count < 24, "\(stub.calls)")
        #expect(try env.store.pendingOCRJobs().isEmpty)
        #expect(try env.store.documents().count == 12)
        #expect(report.ocr.recognized == 12)
    }
}
