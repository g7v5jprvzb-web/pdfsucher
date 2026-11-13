// Indexer.swift — Task 1.3
import Foundation
import os

/// Brings an `IndexStore` up to date with the PDFs (and, with OCR, the images) below `root`.
///
/// One `update` run:
/// 1. scans the folder (throws if the folder itself is unreachable; the index is untouched),
/// 2. compares with the stored documents by (path, size, modification date),
/// 3. removes documents whose files are gone — except below paths the scan could not reach
///    (unreadable subdirectories, links to a missing target), whose documents are kept,
/// 4. extracts text of new and changed files in parallel and writes the results in
///    transactions of `batchSize` files.
///
/// Parallelism: at most `activeProcessorCount - 1` extractions at once (min. 1). Extraction is
/// synchronous PDFKit work on the cooperative pool; leaving one thread free keeps other async
/// work (searches, thumbnails) responsive. (The plan said "core count"; see docs/decisions.md.)
///
/// A file whose text cannot be read is stored with status `error` (no pages), logged, and listed
/// in `IndexReport.failed`; it is not retried until its size or date changes. A file whose pages
/// are all empty is stored with status `noText` (listed in `IndexReport.noText`, except while phase 2
/// will still recognize it in this run; images waiting for recognition are never listed). Pages with fewer than `OCRPolicy.minimumTextLength`
/// characters are queued for recognition; an image is stored as one empty, queued page.
/// `added`/`updated` count every new/changed file, including failed ones.
///
/// Progress: first `(0, total, nil)`, then one value per finished file with that file as
/// `currentFile`; with nothing to do a single `(0, 0, nil)`.
///
/// Concurrent calls run one after another (the second one then usually finds everything
/// unchanged); each gets its own progress and report. A waiting call that is cancelled
/// throws `CancellationError` at once.
///
/// Wiped index: if the index content is wiped during a run (the store hit damage and rebuilt —
/// in this run or in a concurrent search — or `deleteIndex` was called), the run starts over,
/// at most twice, so the index ends up complete. Progress then starts again at
/// `(0, total, nil)` and the report describes the last pass. `store.wasRebuilt` tells the
/// caller about a damage rebuild.
///
/// Cancellation: checked before each extraction, between pages and after each finished file;
/// throws `CancellationError`. Finished files are written first, so the store is consistent and
/// the next run continues incrementally.
///
/// Phase 2 (spec 1.2 §3, only with an `OCRSource` and `ocrSettings.recognizeText`): after phase 1
/// the same `update` call recognizes every page waiting for OCR (see `runOCR`); progress then
/// starts again at `(0, total, nil, phase: .ocr)`, counted in pages. Cancellation is checked
/// before each page; pages already being recognized are still stored. A wipe stops phase 2 early
/// and the run starts over as described above.
///
/// For callers: phase 2 can take long and holds the turn, so a further `update` (new files,
/// another source) waits behind it. To make new files searchable at once, cancel the running
/// `update` and start a new one; nothing finished is lost and recognition continues where it
/// stopped.
public actor Indexer {
    private let root: URL
    private let store: IndexStore
    private let source: any TextSource
    private let scanner: FolderScanner
    private let batchSize: Int
    private let ocr: (any OCRSource)?
    private let ocrSettings: OCRSettings
    private var isRunning = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextWaiterID = 0

    /// Modification dates within this many seconds count as equal (Double round-trip slack).
    static let dateTolerance: TimeInterval = 0.001
    private static let log = Logger(subsystem: "local.pdfsucher", category: "Indexer")

    /// - Parameters:
    ///   - scanner: nil = a `FolderScanner` that lists images when `ocr` is set and
    ///     `ocrSettings.includeImages` is on.
    ///   - ocr: text recognition for phase 2 (spec 1.2 §3). Without it only PDFs are listed and no
    ///     recognition runs; pages without text are still queued for a later run with OCR.
    ///   - ocrSettings: fixed for this Indexer; to apply changed settings, create a new one.
    public init(root: URL, store: IndexStore, source: any TextSource = PDFKitTextSource(), scanner: FolderScanner? = nil,
                batchSize: Int = 50, ocr: (any OCRSource)? = nil, ocrSettings: OCRSettings = .default) {
        self.root = root
        self.store = store
        self.source = source
        self.scanner = scanner ?? FolderScanner(includeImages: ocr != nil && ocrSettings.includeImages)
        self.batchSize = max(1, batchSize)
        self.ocr = ocr
        self.ocrSettings = ocrSettings
    }

    private struct Extracted: Sendable {
        let file: ScannedFile
        let isNew: Bool
        let pages: [PageText]
        let status: DocumentStatus
    }

    public func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        try await acquireTurn()
        defer { releaseTurn() }
        var passes = 0
        while true {
            passes += 1
            let resetsBefore = store.resetCount
            do {
                var report = try await run(progress: progress)
                if ocr != nil, ocrSettings.recognizeText, store.resetCount == resetsBefore {
                    report.ocr = try await runOCR(progress: progress)
                }
                guard store.resetCount != resetsBefore, passes < 3 else { return report }
                Self.log.notice("Index was wiped during the run; indexing again")
            } catch IndexStoreError.corruptIndexRebuilt where passes < 3 {
                Self.log.error("Index was damaged and rebuilt; indexing again from scratch")
            }
        }
    }

    /// Phase 2 alone: recognizes every page still waiting for OCR (e.g. after
    /// `IndexStore.resetOCR()`, „Texterkennung neu ausführen“). Waits for a running `update`.
    /// Does nothing without an `OCRSource`; ignores `ocrSettings.recognizeText` (an explicit
    /// request). Progress values have phase `.ocr`.
    public func recognizePending(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        guard ocr != nil else { return OCRReport() }
        try await acquireTurn()
        defer { releaseTurn() }
        return try await runOCR(progress: progress)
    }

    /// Waits until no other `update`/`recognizePending` runs, then marks this one as running.
    private func acquireTurn() async throws {
        while isRunning {
            try Task.checkCancellation()
            let id = nextWaiterID
            nextWaiterID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { waiters.append((id, continuation)) }
                }
            } onCancel: {
                Task { await self.wakeCancelledWaiter(id) }
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // We may have been woken as the next runner: hand the turn on, or the next queued
            // call would wait forever.
            if !isRunning { wakeNextWaiter() }
            throw error
        }
        isRunning = true
    }

    private func releaseTurn() {
        isRunning = false
        wakeNextWaiter()
    }

    private func wakeNextWaiter() {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
    }

    private func wakeCancelledWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    private func run(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        try Task.checkCancellation()
        let scan = try scanner.scanDetailed(root: root)
        let stored = try store.documents()
        let storedByPath = Dictionary(stored.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })

        var report = IndexReport()
        var work: [(file: ScannedFile, isNew: Bool)] = []
        var seen = Set<String>()
        for file in scan.files where seen.insert(file.relativePath).inserted {
            if let old = storedByPath[file.relativePath] {
                if old.fileSize == file.fileSize,
                   abs(old.modifiedAt.timeIntervalSince1970 - file.modifiedAt.timeIntervalSince1970) < Self.dateTolerance {
                    report.unchanged += 1
                } else {
                    work.append((file, false))
                }
            } else {
                work.append((file, true))
            }
        }

        // "" would mean the root itself became unreadable mid-scan: keep everything.
        let keepAll = scan.unreachablePaths.contains("")
        let kept = scan.unreachablePaths
        let removed = keepAll ? [] : stored.map(\.relativePath).filter { path in
            !seen.contains(path) && !kept.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        if !kept.isEmpty {
            Self.log.notice("Kept documents below unreachable paths: \(kept.joined(separator: ", "), privacy: .public)")
        }
        try store.remove(relativePaths: removed)
        report.removed = removed.count

        let total = work.count
        progress(IndexProgress(done: 0, total: total, currentFile: nil))
        guard total > 0 else { return report }

        let source = self.source
        // Pages are always queued, so an index built without OCR (e.g. before the app passes an
        // OCRSource) is recognized later although its files are unchanged.
        let ocrWillRun = ocr != nil && ocrSettings.recognizeText
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        var pending: [Extracted] = []
        var done = 0
        var failed: [String] = []
        var noText: [String] = []

        do {
            try await withThrowingTaskGroup(of: Extracted.self) { group in
                var queue = work.makeIterator()
                func makeTask(_ item: (file: ScannedFile, isNew: Bool)) -> @Sendable () async throws -> Extracted {
                    { try Self.extract(item.file, isNew: item.isNew, from: source) }
                }
                for _ in 0..<limit {
                    guard let item = queue.next() else { break }
                    group.addTask(operation: makeTask(item))
                }
                while let result = try await group.next() {
                    done += 1
                    if result.isNew { report.added += 1 } else { report.updated += 1 }
                    switch result.status {
                    case .error: failed.append(result.file.relativePath)
                    // A queued PDF is reported like 1.0 unless phase 2 follows; a queued image never
                    // (nothing was looked at yet).
                    case .noText where !result.pages.contains(where: \.needsOCR)
                        || (!ocrWillRun && result.file.kind == .pdf):
                        noText.append(result.file.relativePath)
                    case .noText, .ok: break
                    }
                    pending.append(result)
                    try Task.checkCancellation()
                    if pending.count >= batchSize {
                        try store.upsertBatch(pending.map { ($0.file, $0.pages, $0.status) })
                        pending.removeAll(keepingCapacity: true)
                    }
                    progress(IndexProgress(done: done, total: total, currentFile: result.file.relativePath))
                    if let item = queue.next() { group.addTask(operation: makeTask(item)) }
                }
            }
        } catch is CancellationError {
            // Keep what is already extracted; the next run then skips those files.
            do {
                try store.upsertBatch(pending.map { ($0.file, $0.pages, $0.status) })
            } catch {
                Self.log.error("Could not save finished files after cancel: \(String(describing: error), privacy: .public)")
            }
            throw CancellationError()
        }
        try store.upsertBatch(pending.map { ($0.file, $0.pages, $0.status) })

        report.failed = failed.sorted()
        report.noText = noText.sorted()
        return report
    }

    // MARK: Phase 2 — text recognition (spec 1.2 §3)

    /// At most this many recognitions at once (spec 1.2 §3), so the Mac stays responsive.
    static let ocrParallelism = 2

    private enum OCROutcome: Sendable {
        case text(OCRResult)
        case unreadable
        case retryLater
    }

    /// Works through `store.pendingOCRJobs()`: at most `ocrParallelism` at once, each on its own
    /// utility-priority thread (Vision blocks its caller for the whole recognition and must
    /// not occupy the cooperative pool). Each result is written at once, so a cancel loses
    /// nothing finished; a recognition still running when the run is cancelled is awaited and
    /// stored too. Cancellation is checked before each page.
    private func runOCR(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        guard let ocr else { return OCRReport() }
        try Task.checkCancellation()
        let jobs = try store.pendingOCRJobs()
        let total = jobs.count
        progress(IndexProgress(done: 0, total: total, currentFile: nil, phase: .ocr))
        guard total > 0 else { return try Self.problems(in: store, report: OCRReport()) }

        let root = self.root
        let store = self.store
        let resetsAtStart = store.resetCount
        var report = OCRReport()
        var done = 0
        var cancelled = false
        var storeError: Error?
        await withTaskGroup(of: (OCRPageJob, OCROutcome).self) { group in
            var queue = jobs.makeIterator()
            func start(_ job: OCRPageJob) {
                group.addTask {
                    let url = root.appendingPathComponent(job.relativePath)
                    return (job, await Self.recognizeOnThread(job, at: url, with: ocr))
                }
            }
            for _ in 0..<Self.ocrParallelism {
                guard let job = queue.next() else { break }
                start(job)
            }
            while let (job, outcome) = await group.next() {
                done += 1
                do {
                    try Self.store(outcome, of: job, in: store, report: &report)
                } catch {
                    // A store failure (e.g. damage) ends the run; finish the running pages first.
                    Self.log.error("Could not store OCR result of \(job.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
                    cancelled = true
                    storeError = error
                }
                progress(IndexProgress(done: done, total: total, currentFile: job.relativePath, phase: .ocr))
                if Task.isCancelled { cancelled = true }
                // After a wipe every remaining job is stale: stop starting new ones; `update`
                // notices the wipe and starts over.
                let wiped = store.resetCount != resetsAtStart
                if !cancelled, !wiped, let next = queue.next() { start(next) }
            }
        }
        if let storeError { throw storeError }
        if cancelled { throw CancellationError() }

        return try Self.problems(in: store, report: report)
    }

    /// Every document of the index that ended without any text, and every unreadable image — not only
    /// those of this run: an interrupted run throws its report away (final review). Documents that
    /// still wait for recognition (e.g. after a passing error) are left out.
    private static func problems(in store: IndexStore, report: OCRReport) throws -> OCRReport {
        var report = report
        let stillPending = Set(try store.pendingOCRJobs().map(\.relativePath))
        for doc in try store.documents() where !stillPending.contains(doc.relativePath) {
            switch doc.status {
            case .noText: report.noText.append(doc.relativePath)
            case .error where doc.kind == .image: report.failed.append(doc.relativePath)
            default: break
            }
        }
        report.noText.sort()
        report.failed.sort()
        return report
    }

    private static func store(_ outcome: OCROutcome, of job: OCRPageJob, in store: IndexStore, report: inout OCRReport) throws {
        switch outcome {
        case .text(let result):
            if try store.storeOCR(job, text: result.text, words: result.words), !result.text.isEmpty {
                report.recognized += 1
            }
        case .unreadable:
            // Image → status error; PDF page → only that page is finished (see the store).
            try store.markOCRUnreadable(job)
        case .retryLater:
            report.deferred += 1
        }
    }

    /// Runs one recognition on a new utility-priority thread and waits for it without
    /// blocking a cooperative thread.
    private static func recognizeOnThread(_ job: OCRPageJob, at url: URL, with ocr: any OCRSource) async -> OCROutcome {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let outcome: OCROutcome
                do {
                    outcome = .text(try ocr.recognize(pageIndex: job.pageIndex, of: url, kind: job.kind))
                } catch OCRSourceError.unreadable {
                    log.error("Cannot read for OCR: \(job.relativePath, privacy: .public) page \(job.pageIndex)")
                    outcome = .unreadable
                } catch {
                    log.error("OCR failed for \(job.relativePath, privacy: .public) page \(job.pageIndex), retrying next run: \(String(describing: error), privacy: .public)")
                    outcome = .retryLater
                }
                continuation.resume(returning: outcome)
            }
            thread.qualityOfService = .utility
            thread.name = "PDFSucher OCR"
            thread.start()
        }
    }

    /// Runs off the actor, in a task group child. Pages with less than
    /// `OCRPolicy.minimumTextLength` characters are marked for phase 2, and an image becomes one
    /// empty page waiting for recognition (status `noText` until then).
    private static func extract(_ file: ScannedFile, isNew: Bool, from source: any TextSource) throws -> Extracted {
        try Task.checkCancellation()
        if file.kind == .image {
            return Extracted(file: file, isNew: isNew, pages: [PageText(pageIndex: 0, text: "", needsOCR: true)], status: .noText)
        }
        do {
            let pages = try source.pages(of: file.url).map { page in
                page.text.count < OCRPolicy.minimumTextLength
                    ? PageText(pageIndex: page.pageIndex, text: page.text, needsOCR: true) : page
            }
            let status: DocumentStatus = pages.allSatisfy { $0.text.isEmpty } ? .noText : .ok
            return Extracted(file: file, isNew: isNew, pages: pages, status: status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Cannot read \(file.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
            return Extracted(file: file, isNew: isNew, pages: [], status: .error)
        }
    }
}
