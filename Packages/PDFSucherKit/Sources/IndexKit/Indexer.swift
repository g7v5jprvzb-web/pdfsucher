// Indexer.swift — Task 1.3
import Foundation
import os
import Synchronization

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
/// Phase „layout“ (spec 1.3, only with a `PageLayoutSource`): between phase 1 and phase 2 the same
/// `update` call lays out every Word/PowerPoint document waiting for it (see `runLayout`); progress
/// then starts again at `(0, total, nil, phase: .layout)`, counted in files. Phase 1 stores new and
/// changed Office files without pages, waiting for layout (never through the `TextSource`, not in
/// `IndexReport.noText`); unchanged ones are left alone, so their layout stays. Office pages never go
/// through OCR. Without a layout source the scanner does not list Office files at all.
/// With `layoutDuringUpdate: false` `update` leaves the layout out and `layOutPending` runs it alone,
/// so a queue over several sources can run phase 1 of every source, then every layout, then every
/// recognition (1.2.1 queue order, merge Task 12), like `recognizePending` for phase 2.
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
    private let layout: (any PageLayoutSource)?
    private let layoutConcurrency: Int
    private let layoutTimeout: Duration
    private let layoutDuringUpdate: Bool
    /// `IndexMetrics.hash` of `root` (the measurement log names sources only by hash).
    private let metricsSource: String
    private let metrics: IndexMetrics
    /// 1.4.0 P2: relative path prefixes (ending in "/") whose files go first in layout, recognition and Wortteil-Index
    /// (the folder filter); read before each next job, so a new filter takes effect without stopping anything.
    private let priority: @Sendable () -> [String]
    /// 1.4.0 P3: a count the caller raises to stop the running layout gently: no further file starts, the files being
    /// laid out finish and are stored, then `layOutPending` throws `CancellationError` (the rest waits for the next run).
    private let stopRequests: @Sendable () -> Int
    /// 1.4.0 P5: the provisional text of a Word document in phase 1 (`WordPreviewText` in the app); nil = none.
    private let wordPreview: (@Sendable (URL) -> String?)?
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
    ///   - layout: lays out Word/PowerPoint documents (spec 1.3). With it the default scanner lists
    ///     Office files; without it they are not listed.
    ///   - layoutConcurrency: at most this many layouts at once (min. 1).
    ///   - layoutTimeout: time limit per file (spec 1.3 §11); a file that takes longer gets status
    ///     `error` („Zeitlimit“).
    ///   - layoutDuringUpdate: false = `update` does not lay out (phase 1 only stores Office files as
    ///     waiting); `layOutPending` does it. Like `ocrSettings.recognizeText` for phase 2.
    public init(root: URL, store: IndexStore, source: any TextSource = PDFKitTextSource(), scanner: FolderScanner? = nil,
                batchSize: Int = 50, ocr: (any OCRSource)? = nil, ocrSettings: OCRSettings = .default,
                layout: (any PageLayoutSource)? = nil, layoutConcurrency: Int = 2, layoutTimeout: Duration = .seconds(120),
                layoutDuringUpdate: Bool = true, metrics: IndexMetrics = .shared,
                priority: @escaping @Sendable () -> [String] = { [] },
                stopRequests: @escaping @Sendable () -> Int = { 0 },
                wordPreview: (@Sendable (URL) -> String?)? = nil) {
        self.root = root
        self.store = store
        self.source = source
        self.scanner = scanner ?? FolderScanner(includeImages: ocr != nil && ocrSettings.includeImages,
                                                includeOffice: layout != nil)
        self.batchSize = max(1, batchSize)
        self.ocr = ocr
        self.ocrSettings = ocrSettings
        self.layout = layout
        self.layoutConcurrency = max(1, layoutConcurrency)
        self.layoutTimeout = layoutTimeout
        self.layoutDuringUpdate = layoutDuringUpdate
        self.metricsSource = IndexMetrics.hash(root)
        self.metrics = metrics
        self.priority = priority
        self.stopRequests = stopRequests
        self.wordPreview = wordPreview
    }

    private struct Extracted: Sendable {
        let file: ScannedFile
        let isNew: Bool
        let pages: [PageText]
        let status: DocumentStatus
        /// An Office file: stored without pages, waiting for the phase „layout“.
        var needsLayout = false
        /// Extraction time (measurement log).
        var ms = 0.0
    }

    /// - Parameter atTurnStart: runs once this call has the turn, before any work (no other run of this Indexer is
    ///   active then), e.g. the caller's renderer adoption (1.3 Teil B Task 12).
    /// - Parameter scopes: 1.4.0 P3: relative folder paths (no trailing "/") below which something changed on disk;
    ///   phase 1 then scans and compares only those folders (stored documents elsewhere stay as they are). nil (or a
    ///   restart after a wipe) = the whole folder.
    public func update(scopes: [String]? = nil, progress: @Sendable (IndexProgress) -> Void,
                       atTurnStart: (@Sendable () -> Void)? = nil) async throws -> IndexReport {
        try await acquireTurn()
        defer { releaseTurn() }
        atTurnStart?()
        var passes = 0
        while true {
            passes += 1
            let resetsBefore = store.resetCount
            do {
                var report = try await run(scopes: passes == 1 ? scopes : nil, progress: progress)
                if layout != nil, layoutDuringUpdate, store.resetCount == resetsBefore {
                    report.layout = try await runLayout(progress: progress)
                }
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

    /// Pages moved into the trigram index per transaction (1.3.12): about 0.3 s of writing, so a search or a new phase 1
    /// waits at most that long, and a cancel takes effect after it.
    static let wordPartsBatch = 1_000

    /// „Wortteil-Index“ (1.3.12): moves every page phase 1 stored into the trigram index, `wordPartsBatch` pages per
    /// transaction. Waits for a running `update`. Cancellation is checked before each transaction; what is moved stays
    /// (a later call continues, also after a restart). Progress has phase `.wordParts`, counted in pages. Returns the
    /// pages moved.
    public func buildWordParts(progress: @Sendable (IndexProgress) -> Void) async throws -> Int {
        try await acquireTurn()
        defer { releaseTurn() }
        let total = try store.trigramProgress().pending
        progress(IndexProgress(done: 0, total: total, currentFile: nil, phase: .wordParts))
        guard total > 0 else { return 0 }
        let start = ContinuousClock.now
        var done = 0, transactions = 0, cancelled = false
        defer {
            metrics.log("phase_end", ["source": metricsSource, "phase": "wordparts", "wall_ms": IndexMetrics.ms(since: start),
                                      "sum_ms": IndexMetrics.ms(since: start), "count": done, "queued": total,
                                      "transactions": transactions, "cancelled": cancelled])
        }
        while true {
            if Task.isCancelled { cancelled = true; throw CancellationError() }
            let t = ContinuousClock.now
            let moved = try store.fillTrigramIndex(maxPages: Self.wordPartsBatch, preferring: priority())
            guard moved > 0 else { break }
            transactions += 1
            done += moved
            metrics.log("wordparts_batch", ["source": metricsSource, "pages": moved, "ms": IndexMetrics.ms(since: t)])
            progress(IndexProgress(done: min(done, total), total: total, currentFile: nil, phase: .wordParts))
        }
        return done
    }

    /// Phase „layout“ alone (spec 1.3): lays out every Word/PowerPoint document waiting for it, e.g.
    /// after a phase-1-only `update` (`layoutDuringUpdate: false`). Waits for a running `update`.
    /// Does nothing without a `PageLayoutSource`. Progress values have phase `.layout`.
    /// `atTurnStart` as for `update`.
    public func layOutPending(progress: @Sendable (IndexProgress) -> Void,
                              atTurnStart: (@Sendable () -> Void)? = nil) async throws -> LayoutReport {
        guard layout != nil else { return LayoutReport() }
        try await acquireTurn()
        defer { releaseTurn() }
        atTurnStart?()
        return try await runLayout(progress: progress)
    }

    /// Waits until no other `update`/`recognizePending`/`layOutPending` runs, then marks this one as running.
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

    /// The scan of phase 1: the whole folder, or (P3) only `scopes`, with their paths relative to the root. A scope that
    /// no longer exists (while the root does) lists nothing, so its stored documents leave.
    private func scan(scopes: [String]?) throws -> FolderScanResult {
        guard let scopes else { return try scanner.scanDetailed(root: root) }
        var files: [ScannedFile] = [], unreachable: [String] = []
        for scope in scopes {
            let url = root.appendingPathComponent(scope, isDirectory: true)
            let depth = scope.split(separator: "/").count
            guard FileManager.default.fileExists(atPath: url.path) else {
                _ = try root.resourceValues(forKeys: [.isDirectoryKey])      // the root itself gone: throw like a full scan
                continue
            }
            guard let scanner = scanner.scoped(depth: depth) else { continue }
            let result = try scanner.scanDetailed(root: url)
            files += result.files.map {
                ScannedFile(relativePath: scope + "/" + $0.relativePath, url: $0.url, fileSize: $0.fileSize, modifiedAt: $0.modifiedAt)
            }
            unreachable += result.unreachablePaths.map { $0.isEmpty ? scope : scope + "/" + $0 }
        }
        return FolderScanResult(files: files, unreachablePaths: unreachable)
    }

    private func run(scopes: [String]? = nil, progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        try Task.checkCancellation()
        let metrics = metrics, source = metricsSource
        let phaseStart = ContinuousClock.now
        var extractMs = 0.0, dbMs = 0.0, writerWaitMs = 0.0, extracted = 0
        defer {
            metrics.log("phase_end", ["source": source, "phase": "text", "wall_ms": IndexMetrics.ms(since: phaseStart),
                                      "sum_ms": extractMs, "db_ms": dbMs, "writer_wait_ms": writerWaitMs, "count": extracted])
        }
        let scan = try self.scan(scopes: scopes)
        if metrics.isEnabled {
            var kinds: [String: Int] = [:]
            for file in scan.files { kinds[file.kind.rawValue, default: 0] += 1 }
            metrics.log("scan", ["source": source, "ms": IndexMetrics.ms(since: phaseStart), "files": scan.files.count,
                                 "kinds": kinds, "unreachable": scan.unreachablePaths.count, "scopes": scopes?.count ?? 0])
        }
        let diffStart = ContinuousClock.now
        let inScope = { (path: String) in scopes.map { $0.contains { path.hasPrefix($0 + "/") } } ?? true }
        let stored = try store.documents().filter { inScope($0.relativePath) }
        let documentsMs = IndexMetrics.ms(since: diffStart)
        let storedByPath = Dictionary(stored.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })

        var report = IndexReport()
        var work: [(file: ScannedFile, isNew: Bool)] = []
        var seen = Set<String>()
        var backfill: [(path: String, fileID: String)] = []
        for file in scan.files where seen.insert(file.relativePath).inserted {
            if let old = storedByPath[file.relativePath] {
                if old.fileSize == file.fileSize,
                   abs(old.modifiedAt.timeIntervalSince1970 - file.modifiedAt.timeIntervalSince1970) < Self.dateTolerance {
                    report.unchanged += 1
                    if let id = file.fileID, old.fileID != id { backfill.append((file.relativePath, id)) }
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
        var removed = keepAll ? [] : stored.map(\.relativePath).filter { path in
            !seen.contains(path) && !kept.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        // 1.4.0 P4: a new path with the file identity, size, date and kind of a document gone in this run is that file,
        // moved or renamed on its volume: its entry moves along (pages, OCR, layout) instead of being read again.
        // Identities shared by several gone documents (hard links) are not trusted.
        let moves = Self.moves(new: work, gone: removed.compactMap { storedByPath[$0] })
        if !moves.isEmpty {
            let to = Set(moves.map(\.to)), from = Set(moves.map(\.from))
            work.removeAll { $0.isNew && to.contains($0.file.relativePath) }
            removed.removeAll { from.contains($0) }
            try store.move(moves)
            report.moved = moves.count
        }
        try store.setFileIDs(backfill)
        Self.sortForExtraction(&work)
        if !kept.isEmpty {
            Self.log.notice("Kept documents below unreachable paths: \(kept.joined(separator: ", "), privacy: .public)")
        }
        try store.remove(relativePaths: removed)
        report.removed = removed.count
        metrics.log("diff", ["source": source, "documents_ms": documentsMs, "ms": IndexMetrics.ms(since: diffStart),
                             "stored": stored.count, "unchanged": report.unchanged, "new": work.filter(\.isNew).count,
                             "changed": work.filter { !$0.isNew }.count, "removed": removed.count, "moved": moves.count,
                             "file_ids_filled": backfill.count])

        let total = work.count
        progress(IndexProgress(done: 0, total: total, currentFile: nil))
        guard total > 0 else { return report }

        let textSource = self.source, wordPreview = self.wordPreview
        // Pages are always queued, so an index built without OCR (e.g. before the app passes an
        // OCRSource) is recognized later although its files are unchanged.
        let ocrWillRun = ocr != nil && ocrSettings.recognizeText
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        var pending: [Extracted] = []
        let writer = BatchWriter(maxInFlight: Self.writesInFlight) { [self] batch in try upsert(batch) }
        defer { dbMs = writer.writtenMs; writerWaitMs = writer.waitMs }
        var done = 0
        var failed: [String] = []
        var noText: [String] = []

        do {
            try await withThrowingTaskGroup(of: Extracted.self) { group in
                var queue = work.makeIterator()
                func makeTask(_ item: (file: ScannedFile, isNew: Bool)) -> @Sendable () async throws -> Extracted {
                    {
                        let start = ContinuousClock.now
                        var result = try Self.extract(item.file, isNew: item.isNew, from: textSource, wordPreview: wordPreview)
                        result.ms = IndexMetrics.ms(since: start)
                        return result
                    }
                }
                for _ in 0..<limit {
                    guard let item = queue.next() else { break }
                    group.addTask(operation: makeTask(item))
                }
                while let result = try await group.next() {
                    done += 1
                    extracted += 1
                    extractMs += result.ms
                    if metrics.isEnabled { logFile(result) }
                    if result.isNew { report.added += 1 } else { report.updated += 1 }
                    switch result.status {
                    case .error: failed.append(result.file.relativePath)
                    case .noText where result.needsLayout: break // nothing looked at yet
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
                        let batch = pending
                        pending.removeAll(keepingCapacity: true)
                        try await writer.submit(batch)
                    }
                    progress(IndexProgress(done: done, total: total, currentFile: result.file.relativePath))
                    if let item = queue.next() { group.addTask(operation: makeTask(item)) }
                }
            }
            try await writer.submit(pending)
            if let error = await writer.drain() { throw error }
        } catch is CancellationError {
            // Keep what is already extracted; the next run then skips those files.
            var saveError: Error?
            do { try await writer.submit(pending) } catch { saveError = error }
            if let error = await writer.drain() ?? saveError {
                Self.log.error("Could not save finished files after cancel: \(String(describing: error), privacy: .public)")
            }
            throw CancellationError()
        } catch {
            _ = await writer.drain()            // nothing of this run may still write after it ended (a wipe restarts it)
            throw error
        }

        report.failed = failed.sorted()
        report.noText = noText.sorted()
        return report
    }

    /// New files that are gone documents under another path (P4): same file identity, size, date and kind.
    static func moves(new work: [(file: ScannedFile, isNew: Bool)], gone: [StoredDocument]) -> [(from: String, to: String, fileID: String?)] {
        var byID: [String: StoredDocument] = [:], ambiguous = Set<String>()
        for doc in gone {
            guard let id = doc.fileID else { continue }
            if byID.updateValue(doc, forKey: id) != nil { ambiguous.insert(id) }
        }
        for id in ambiguous { byID[id] = nil }
        var moves: [(from: String, to: String, fileID: String?)] = []
        for item in work where item.isNew {
            guard let id = item.file.fileID, let doc = byID[id], doc.fileSize == item.file.fileSize, doc.kind == item.file.kind,
                  abs(doc.modifiedAt.timeIntervalSince1970 - item.file.modifiedAt.timeIntervalSince1970) < dateTolerance else { continue }
            byID[id] = nil
            moves.append((doc.relativePath, item.file.relativePath, id))
        }
        return moves
    }

    /// index-speed-1: largest files first (ties by path), so a long file does not start last and hold up the run's end.
    static func sortForExtraction(_ work: inout [(file: ScannedFile, isNew: Bool)]) {
        work.sort { ($0.file.fileSize, $1.file.relativePath) > ($1.file.fileSize, $0.file.relativePath) }
    }

    /// Phase-1 batches written or waiting at once (index-speed-1): one being written, one ready behind it.
    static let writesInFlight = 2

    /// Writes one batch of phase 1; returns its time in ms (measurement log `db_batch`).
    private nonisolated func upsert(_ items: [Extracted]) throws -> Double {
        func r(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }
        let start = ContinuousClock.now
        let t = try store.upsertBatch(items.map { ($0.file, $0.pages, $0.status, $0.needsLayout) })
        let ms = IndexMetrics.ms(since: start)
        if !items.isEmpty {
            metrics.log("db_batch", ["source": metricsSource, "ms": ms, "files": items.count,
                                     "pages": items.reduce(0) { $0 + $1.pages.count },
                                     "chars": items.reduce(0) { $0 + $1.pages.reduce(0) { $0 + $1.text.utf8.count } },
                                     "lock_wait_ms": t.lockWaitMs, "lookup_ms": r(t.lookupMs), "delete_old_ms": r(t.deleteOldMs),
                                     "document_ms": r(t.documentMs), "pages_fts_ms": r(t.pagesMs), "commit_ms": t.commitMs])
        }
        return ms
    }

    private func logFile(_ r: Extracted) {
        let file = IndexMetrics.hash(r.file.url), ext = r.file.url.pathExtension.lowercased()
        let mtime = IndexMetrics.stamp(r.file.modifiedAt)
        metrics.log("file", ["source": metricsSource, "file": file, "ext": ext, "kind": r.file.kind.rawValue,
                             "bytes": r.file.fileSize, "mtime": mtime, "new": r.isNew, "ms": r.ms, "pages": r.pages.count,
                             "needs_ocr": r.pages.filter(\.needsOCR).count, "status": r.status.rawValue])
        // Only PDFs are read here; images and Office files are only listed (their work is OCR / layout).
        if r.file.kind == .pdf { metrics.noteDone(phase: "text", file: file, ext: ext, key: "\(r.file.fileSize)|\(mtime)", ms: r.ms) }
    }

    /// One `ocr_page` / `layout_file` line; `pages`/`chars` only for a finished result.
    private func logJob(_ event: String, phase: String, relativePath: String, kind: DocumentKind, fileSize: Int64,
                        modifiedAt: Date, page: Int?, ms: Double, waitMs: Double?, result: String, pages: Int?, chars: Int?) {
        let url = root.appendingPathComponent(relativePath)
        let file = IndexMetrics.hash(url), ext = url.pathExtension.lowercased(), mtime = IndexMetrics.stamp(modifiedAt)
        var fields: [String: Any] = ["source": metricsSource, "file": file, "ext": ext, "kind": kind.rawValue,
                                     "bytes": fileSize, "mtime": mtime, "ms": ms, "result": result]
        if let page { fields["page"] = page }
        if let waitMs { fields["wait_ms"] = waitMs }
        if let pages { fields["pages"] = pages }
        if let chars { fields["chars"] = chars }
        metrics.log(event, fields)
        if result == "ok" {
            metrics.noteDone(phase: phase, file: file, ext: ext, key: "\(fileSize)|\(mtime)" + (page.map { "|p\($0)" } ?? ""), ms: ms)
        }
    }

    // MARK: Phase 2 — text recognition (spec 1.2 §3)

    /// At most this many recognitions at once (spec 1.2 §3), so the Mac stays responsive: a quarter of the cores, 2 to 4
    /// (1.4.0 P7, measured on 48 real scan pages, M3 Max: 2 → 5.7, 4 → 7.3, 6 → 7.8 pages/s, the same text in every case;
    /// each on a utility thread). 2 on Macs with fewer than 12 cores, as before.
    public static let ocrParallelism = parallelism(cores: ProcessInfo.processInfo.activeProcessorCount)

    static func parallelism(cores: Int) -> Int { max(2, min(4, cores / 4)) }

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
        let metrics = metrics, phaseStart = ContinuousClock.now
        var sumMs = 0.0
        await withTaskGroup(of: (OCRPageJob, OCROutcome, Double).self) { group in
            var queue = PreferredOrder(jobs, path: \.relativePath)
            let priority = self.priority
            func start(_ job: OCRPageJob) {
                group.addTask {
                    let url = root.appendingPathComponent(job.relativePath)
                    let started = ContinuousClock.now
                    let outcome = await Self.recognizeOnThread(job, at: url, with: ocr)
                    return (job, outcome, IndexMetrics.ms(since: started))
                }
            }
            for _ in 0..<Self.ocrParallelism {
                guard let job = queue.next(preferring: priority()) else { break }
                start(job)
            }
            while let (job, outcome, ms) = await group.next() {
                done += 1
                sumMs += ms
                if metrics.isEnabled {
                    let (result, chars): (String, Int?) = switch outcome {
                    case .text(let r): ("ok", r.text.count)
                    case .unreadable: ("unreadable", nil)
                    case .retryLater: ("retry_later", nil)
                    }
                    logJob("ocr_page", phase: "ocr", relativePath: job.relativePath, kind: job.kind, fileSize: job.fileSize,
                           modifiedAt: job.modifiedAt, page: job.pageIndex, ms: ms, waitMs: nil, result: result, pages: nil, chars: chars)
                }
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
                if !cancelled, !wiped, let next = queue.next(preferring: priority()) { start(next) }
            }
        }
        metrics.log("phase_end", ["source": metricsSource, "phase": "ocr", "wall_ms": IndexMetrics.ms(since: phaseStart),
                                  "sum_ms": sumMs, "count": done, "queued": total, "cancelled": cancelled])
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
        // Word/PowerPoint never go through OCR: their problems are the layout phase's (`LayoutReport`),
        // and one waiting for layout is stored as `noText` (merge 1.2.1, Task 12).
        for doc in try store.documents() where !stillPending.contains(doc.relativePath) && !doc.kind.isOffice {
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

    // MARK: Phase „layout“ — Word and PowerPoint (spec 1.3)

    private enum LayoutOutcome: Sendable {
        case laidOut(LayoutResult)
        case unreadable(reason: String)
        case timedOut
        /// The file on disk changed during layout: the result belongs to an old version.
        case fileChanged
        /// The source threw `CancellationError` on its own: stop the run.
        case cancelled
        case retryLater
    }

    /// Works through `store.pendingLayoutJobs()` after queueing every document of a kind whose
    /// renderer changed since the last run (`adoptLayoutRenderer`, recorded per kind in the index,
    /// so Word and PowerPoint may have different renderers) and documents of outdated versions:
    /// at most `layoutConcurrency` at once, `.utility` priority. Each result is written at once;
    /// a layout still running when the run is cancelled is cancelled and dropped at once (the
    /// document stays queued for the next run), results finished before the cancel are stored.
    /// Cancellation is checked before each file. A wipe stops starting new files
    /// (like phase 2); `update` then starts over.
    private func runLayout(progress: @Sendable (IndexProgress) -> Void) async throws -> LayoutReport {
        guard let layout else { return LayoutReport() }
        try Task.checkCancellation()
        for kind in [DocumentKind.word, .powerpoint] {
            let renderer = layout.renderer(for: kind)
            // Another renderer (name or version) than recorded: every document of the kind again,
            // failed ones and those never laid out included.
            // PowerPoint (1.3 Teil B Task 12): tiles and highlights follow the new renderer at once, so the old words
            // must not stay searchable until each deck is laid out again; removed together with the new record.
            if try store.adoptLayoutRenderer(name: renderer.name, version: renderer.version, for: kind,
                                             clearingPages: kind == .powerpoint) {
                Self.log.notice("Layout renderer for \(kind.rawValue, privacy: .public) is now \(renderer.name, privacy: .public) \(renderer.version); laying out again")
            }
            try store.requestLayout(renderer: renderer.name, olderThan: renderer.version, kind: kind)
            // Laid out under conditions the source now calls stale (Word with substitute fonts, 1.3.2): again.
            for stale in layout.staleRenderers(for: kind) {
                try store.requestLayout(renderer: stale, olderThan: .max, kind: kind)
            }
        }
        let jobs = try store.pendingLayoutJobs()
        let total = jobs.count
        progress(IndexProgress(done: 0, total: total, currentFile: nil, phase: .layout))
        guard total > 0 else { return try Self.layoutProblems(in: store, report: LayoutReport()) }

        let root = self.root
        let store = self.store
        let timeout = layoutTimeout
        let resetsAtStart = store.resetCount
        var report = LayoutReport()
        var done = 0
        var cancelled = false
        var stoppedEarly = false
        var storeError: Error?
        let metrics = metrics, phaseStart = ContinuousClock.now
        var sumMs = 0.0
        await withTaskGroup(of: (LayoutJob, LayoutOutcome, Double, Double).self) { group in
            var queue = PreferredOrder(jobs, path: \.relativePath)
            let priority = self.priority, stopRequests = self.stopRequests, stopsAtStart = stopRequests()
            func start(_ job: LayoutJob) {
                group.addTask(priority: .utility) {
                    let url = root.appendingPathComponent(job.relativePath)
                    let started = ContinuousClock.now
                    let outcome = await Self.layOut(job, at: url, with: layout, timeout: timeout)
                    return (job, outcome, IndexMetrics.ms(since: started), IndexMetrics.ms(started - phaseStart))
                }
            }
            for _ in 0..<layoutConcurrency {
                guard let job = queue.next(preferring: priority()) else { break }
                start(job)
            }
            while let (job, outcome, ms, waitMs) = await group.next() {
                done += 1
                sumMs += ms
                if metrics.isEnabled {
                    let (result, pages): (String, Int?) = switch outcome {
                    case .laidOut(let r): ("ok", r.pages.count)
                    case .unreadable: ("failed", nil)
                    case .timedOut: ("timeout", nil)
                    case .fileChanged: ("fileChanged", nil)
                    case .cancelled: ("cancelled", nil)
                    case .retryLater: ("retry_later", nil)
                    }
                    logJob("layout_file", phase: "layout", relativePath: job.relativePath, kind: job.kind, fileSize: job.fileSize,
                           modifiedAt: job.modifiedAt, page: nil, ms: ms, waitMs: waitMs, result: result, pages: pages, chars: nil)
                }
                do {
                    if try !Self.store(outcome, of: job, in: store, report: &report) { cancelled = true }
                } catch {
                    // A store failure (e.g. damage) ends the run; finish the running files first.
                    Self.log.error("Could not store layout of \(job.relativePath, privacy: .private): \(String(describing: error), privacy: .public)")
                    cancelled = true
                    storeError = error
                }
                progress(IndexProgress(done: done, total: total, currentFile: job.relativePath, phase: .layout))
                if Task.isCancelled { cancelled = true }
                let wiped = store.resetCount != resetsAtStart
                if stopRequests() != stopsAtStart {
                    stoppedEarly = stoppedEarly || queue.hasMore                // finish the running files, start none
                } else if !cancelled, !wiped, let next = queue.next(preferring: priority()) { start(next) }
            }
        }
        metrics.log("phase_end", ["source": metricsSource, "phase": "layout", "wall_ms": IndexMetrics.ms(since: phaseStart),
                                  "sum_ms": sumMs, "count": done, "queued": total, "cancelled": cancelled, "stopped": stoppedEarly])
        if let storeError { throw storeError }
        if cancelled || stoppedEarly { throw CancellationError() }
        return try Self.layoutProblems(in: store, report: report)
    }

    /// `report` with `failed`/`noText` replaced by those of the whole index (1.3 Teil B, like `problems(in:report:)`
    /// for OCR): every Word/PowerPoint document with status `error`, and every one laid out without text — not only
    /// those of this run, so a cancelled run loses no problem. Documents still waiting for layout are in neither
    /// list (one waiting is stored as `noText`). `laidOut` and `deferred` stay this run's values. Sorted by path.
    private static func layoutProblems(in store: IndexStore, report: LayoutReport) throws -> LayoutReport {
        var report = report
        report.failed = []
        report.noText = []
        let waiting = Set(try store.pendingLayoutJobs().map(\.relativePath))
        for doc in try store.documents() where doc.kind.isOffice && !waiting.contains(doc.relativePath) {
            switch doc.status {
            case .error: report.failed.append(doc.relativePath)
            case .noText: report.noText.append(doc.relativePath)
            default: break
            }
        }
        report.failed.sort()
        report.noText.sort()
        return report
    }

    /// Writes one outcome; false = the run must stop (the source reported cancellation).
    private static func store(_ outcome: LayoutOutcome, of job: LayoutJob, in store: IndexStore,
                              report: inout LayoutReport) throws -> Bool {
        switch outcome {
        case .laidOut(let result):
            // Problem lists come from the whole index at the end (`layoutProblems`).
            if try store.storeLayout(job, result: result) { report.laidOut += 1 }
        case .unreadable(let reason):
            try store.markLayoutFailed(job, reason: reason)
        case .timedOut:
            try store.markLayoutFailed(job, reason: "Zeitlimit")
        case .fileChanged, .retryLater:
            // Still waiting (`needs_layout`); a changed file is queued anew by the next phase 1.
            report.deferred += 1
        case .cancelled:
            return false
        }
        return true
    }

    /// One layout raced against `timeout` and the run's cancellation. The layout runs in its own
    /// detached task; cancelling the run cancels it and returns `.cancelled` at once (the document
    /// stays queued; nothing is stored). On timeout the layout task is cancelled and `.timedOut`
    /// returned at once. Neither waits for a source that ignores cancellation: whatever it returns
    /// later is dropped by `LayoutRace` (only the first outcome counts) and never stored; its work
    /// keeps running until it ends, outside the `layoutConcurrency` limit.
    private static func layOut(_ job: LayoutJob, at url: URL, with layout: any PageLayoutSource,
                               timeout: Duration) async -> LayoutOutcome {
        let race = LayoutRace<LayoutOutcome>()
        let work = Task.detached(priority: .utility) {
            race.finish(await attempt(job, at: url, with: layout))
        }
        let timer = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: timeout) } catch { return }
            log.error("Layout timed out: \(job.relativePath, privacy: .private)")
            race.finish(.timedOut)
        }
        race.track(work: work, timer: timer)
        return await withTaskCancellationHandler {
            await race.outcome()
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private static func attempt(_ job: LayoutJob, at url: URL, with layout: any PageLayoutSource) async -> LayoutOutcome {
        do {
            let result = try await layout.layout(of: url, kind: job.kind)
            // `storeLayout` only compares with the index; the file itself may have changed meanwhile.
            guard isUnchanged(job, at: url) else {
                log.notice("File changed during layout, dropping the result: \(job.relativePath, privacy: .private)")
                return .fileChanged
            }
            return .laidOut(result)
        } catch LayoutSourceError.unreadable(_, let reason) {
            log.error("Cannot lay out \(job.relativePath, privacy: .private): \(reason, privacy: .private)")
            return .unreadable(reason: reason)
        } catch is CancellationError {
            return .cancelled
        } catch {
            log.error("Layout failed for \(job.relativePath, privacy: .private), retrying next run: \(String(describing: error), privacy: .public)")
            return .retryLater
        }
    }

    /// Size and modification date on disk still match the job (links resolved, like the scanner).
    private static func isUnchanged(_ job: LayoutJob, at url: URL) -> Bool {
        isUnchanged(fileSize: job.fileSize, modifiedAt: job.modifiedAt, at: url)
    }

    /// The file at `url` (links resolved, like the scanner) has this size and modification date, compared as the
    /// indexer compares a stored document; false when it cannot be read.
    public static func isUnchanged(fileSize: Int64, modifiedAt: Date, at url: URL) -> Bool {
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return false }
        return Int64(size) == fileSize
            && abs(date.timeIntervalSince1970 - modifiedAt.timeIntervalSince1970) < dateTolerance
    }

    /// Runs off the actor, in a task group child. Pages with less than
    /// `OCRPolicy.minimumTextLength` characters are marked for phase 2, and an image becomes one
    /// empty page waiting for recognition (status `noText` until then).
    private static func extract(_ file: ScannedFile, isNew: Bool, from source: any TextSource,
                                wordPreview: (@Sendable (URL) -> String?)?) throws -> Extracted {
        try Task.checkCancellation()
        if file.kind.isOffice {
            // 1.4.0 P5: a Word document's text at once, as one provisional page (searchable now; the layout phase replaces
            // it with the real pages and word boxes). Without it, or for PowerPoint, it waits without pages as before.
            if file.kind == .word, let text = wordPreview?(file.url), !text.isEmpty {
                return Extracted(file: file, isNew: isNew, pages: [PageText(pageIndex: 0, text: text)], status: .ok, needsLayout: true)
            }
            return Extracted(file: file, isNew: isNew, pages: [], status: .noText, needsLayout: true)
        }
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

/// First outcome wins: it is handed to `outcome()` and both racing tasks are cancelled; later
/// outcomes (a layout finishing after its timeout or the run's cancel) are dropped.
/// Also used for Word/PowerPoint single files in the app (1.3 Teil B Task 5).
public final class LayoutRace<Outcome: Sendable>: Sendable {
    private struct State {
        var outcome: Outcome?
        var decided = false
        var continuation: CheckedContinuation<Outcome, Never>?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    public init() {}

    /// Registers the racing tasks; if the race is already decided they are cancelled at once.
    public func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let decided = state.withLock { s in
            if s.decided { return true }
            s.tasks = [work, timer]
            return false
        }
        if decided { work.cancel(); timer.cancel() }
    }

    /// The first outcome; waits until there is one. Call once.
    public func outcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready: Outcome? = state.withLock { s in
                if let outcome = s.outcome { return outcome }
                s.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public func finish(_ outcome: Outcome) {
        let won: (continuation: CheckedContinuation<Outcome, Never>?, tasks: [Task<Void, Never>])? = state.withLock { s in
            guard !s.decided else { return nil }
            s.decided = true
            s.outcome = outcome
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks)
        }
        guard let won else { return }
        for task in won.tasks { task.cancel() }
        won.continuation?.resume(returning: outcome)
    }
}

/// Phase 1's writer (index-speed-1): each batch is written in its own task, after the previous one, so extraction goes on
/// while SQLite writes. At most `maxInFlight` batches wait or are written; `submit` waits for the oldest beyond that
/// (backpressure, `waitMs`). A failed write fails every later one without writing, so nothing is stored after an error.
/// Used only inside the Indexer's `run`; every path ends with `drain`, so no write outlives the run.
/// `@unchecked Sendable`: its state is only touched on the caller's actor (`submit`/`drain` take its isolation; the group
/// body that calls them runs on the Indexer), never from the write tasks.
final class BatchWriter<Batch: Sendable>: @unchecked Sendable {
    private let maxInFlight: Int
    private let write: @Sendable (Batch) throws -> Double
    private var inFlight: [Task<Double, Error>] = []
    private(set) var writtenMs = 0.0
    private(set) var waitMs = 0.0
    /// Most batches waiting or being written at once so far (tests).
    private(set) var peakInFlight = 0

    init(maxInFlight: Int, write: @escaping @Sendable (Batch) throws -> Double) {
        self.maxInFlight = max(1, maxInFlight)
        self.write = write
    }

    /// Runs on the caller's actor (`isolation`), like every use of this writer.
    func submit(_ batch: Batch, isolation: isolated (any Actor)? = #isolation) async throws where Batch: Collection {
        guard !batch.isEmpty else { return }
        if inFlight.count >= maxInFlight {
            let start = ContinuousClock.now
            defer { waitMs += IndexMetrics.ms(since: start) }
            while inFlight.count >= maxInFlight { writtenMs += try await inFlight.removeFirst().value }
        }
        let previous = inFlight.last, write = self.write
        inFlight.append(Task.detached(priority: Task.currentPriority) {
            if let previous { _ = try await previous.value }
            return try write(batch)
        })
        peakInFlight = max(peakInFlight, inFlight.count)
    }

    /// Waits for every batch still waiting or being written; the first error, if any.
    func drain(isolation: isolated (any Actor)? = #isolation) async -> Error? {
        var first: Error?
        while !inFlight.isEmpty {
            do { writtenMs += try await inFlight.removeFirst().value } catch { first = first ?? error }
        }
        return first
    }
}

/// Jobs in their order, except that those below one of the preferred path prefixes come first (1.4.0 P2). The rest is
/// re-partitioned only when the prefixes change, so taking a job stays O(1) for a stable filter.
struct PreferredOrder<Job> {
    private var jobs: [Job]
    private var cursor = 0
    private var applied: [String] = []
    private let path: (Job) -> String

    init(_ jobs: [Job], path: @escaping (Job) -> String) {
        self.jobs = jobs
        self.path = path
    }

    var hasMore: Bool { cursor < jobs.count }

    mutating func next(preferring prefixes: [String]) -> Job? {
        if prefixes != applied {
            applied = prefixes
            if !prefixes.isEmpty, cursor < jobs.count {
                let rest = jobs[cursor...]
                let preferred = rest.filter { job in prefixes.contains { path(job).hasPrefix($0) } }
                let others = rest.filter { job in !prefixes.contains { path(job).hasPrefix($0) } }
                jobs.replaceSubrange(cursor..., with: preferred + others)
            }
        }
        guard cursor < jobs.count else { return nil }
        defer { cursor += 1 }
        return jobs[cursor]
    }
}
