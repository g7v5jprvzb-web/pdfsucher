import AppKit
import Foundation
import IndexKit
import OutputKit
import SearchKit
import ViewerUI
@testable import AppCore

/// Stand-in for a folder index: scripted search results, a counter, and an `update` that can be
/// held open until the test releases it (or the task is cancelled).
final class FakeIndex: FolderIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var _hits: [DocumentHit] = []
    private var _searchCount = 0
    private var _searchErrors: [Error] = []
    private var _events: [String] = []
    private var _holdUpdates = false
    private var _report = IndexReport()
    private var _rebuilt = false
    private var _linger = false
    private var _holdSearches = false
    private var _updateErrors: [Error] = []

    var hits: [DocumentHit] {
        get { lock.withLock { _hits } }
        set { lock.withLock { _hits = newValue } }
    }
    var searchCount: Int { lock.withLock { _searchCount } }
    var events: [String] { lock.withLock { _events } }
    var holdUpdates: Bool {
        get { lock.withLock { _holdUpdates } }
        set { lock.withLock { _holdUpdates = newValue } }
    }
    var report: IndexReport {
        get { lock.withLock { _report } }
        set { lock.withLock { _report = newValue } }
    }
    var wasRebuilt: Bool {
        get { lock.withLock { _rebuilt } }
        set { lock.withLock { _rebuilt = newValue } }
    }
    /// When set, a cancelled `update` keeps running until this is cleared (a slow cancellation).
    var lingerOnCancel: Bool {
        get { lock.withLock { _linger } }
        set { lock.withLock { _linger = newValue } }
    }
    /// While true, `search` blocks (on its background thread) until released or cancelled.
    var holdSearches: Bool {
        get { lock.withLock { _holdSearches } }
        set { lock.withLock { _holdSearches = newValue } }
    }
    func failNextUpdate(with error: Error) { lock.withLock { _updateErrors.append(error) } }
    func failNextSearch(with error: Error) { lock.withLock { _searchErrors.append(error) } }
    /// Optional log shared by several fakes (order across folders); entries are "<name>:<event>".
    var name = ""
    var sharedLog: StringLog?
    private func record(_ e: String) {
        lock.withLock { _events.append(e) }
        sharedLog?.append("\(name):\(e)")
    }

    private var _partialHits: [DocumentHit]?
    /// Reported through `onPartial` at the start of every search (before a held search waits).
    var partialHits: [DocumentHit]? {
        get { lock.withLock { _partialHits } }
        set { lock.withLock { _partialHits = newValue } }
    }

    func search(_ q: ParsedQuery, sort: SortMode, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        let error: Error? = lock.withLock {
            _searchCount += 1
            return _searchErrors.isEmpty ? nil : _searchErrors.removeFirst()
        }
        if let error { throw error }
        if let early = partialHits, let onPartial { onPartial(sortHits(early, by: sort)) }
        while holdSearches {
            if Task.isCancelled { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return sortHits(hits, by: sort)
    }

    func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        record("update-start")
        ocrLog?.append("\(name):update-start")
        progress(IndexProgress(done: 0, total: 3, currentFile: nil))
        while holdUpdates {
            for p in lock.withLock({ defer { _progress.removeAll() }; return _progress }) { progress(p) }
            if Task.isCancelled {
                record("update-cancelled")
                while lingerOnCancel { try? await Task.sleep(for: .milliseconds(2)) }
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if let error = lock.withLock({ _updateErrors.isEmpty ? nil : _updateErrors.removeFirst() }) {
            record("update-failed")
            throw error
        }
        record("update-end")
        ocrLog?.append("\(name):update-end")
        return report
    }

    func deleteIndex() throws { record(Thread.isMainThread ? "delete-on-main" : "delete") }

    // MARK: Phase 2 (text recognition, spec 1.2)

    /// Phase 1 and phase 2 events "<name>:<event>" (phase 2 is not in `events`/`sharedLog`, so 1.1 tests keep
    /// their exact sequences).
    var ocrLog: StringLog?
    private var _holdRecognition = false
    private var _ocrReport = OCRReport()
    private var _ocrTotal = 5
    private var _ocrCount = 0
    private var _hitsAfterRecognition: [DocumentHit]?
    var holdRecognition: Bool {
        get { lock.withLock { _holdRecognition } }
        set { lock.withLock { _holdRecognition = newValue } }
    }
    var ocrReport: OCRReport {
        get { lock.withLock { _ocrReport } }
        set { lock.withLock { _ocrReport = newValue } }
    }
    var recognizeCount: Int { lock.withLock { _ocrCount } }
    /// Hits that become searchable when a recognition run ends.
    var hitsAfterRecognition: [DocumentHit]? {
        get { lock.withLock { _hitsAfterRecognition } }
        set { lock.withLock { _hitsAfterRecognition = newValue } }
    }
    private(set) var configured: [OCRSettings] = []

    func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        lock.withLock { _ocrCount += 1 }
        ocrLog?.append("\(name):ocr-start")
        progress(IndexProgress(done: 0, total: lock.withLock { _ocrTotal }, currentFile: nil, phase: .ocr))
        while holdRecognition {
            for p in lock.withLock({ defer { _progress.removeAll() }; return _progress }) { progress(p) }
            if Task.isCancelled {
                ocrLog?.append("\(name):ocr-cancelled")
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if let after = hitsAfterRecognition { hits = after }
        ocrLog?.append("\(name):ocr-end")
        return ocrReport
    }

    func configure(_ settings: OCRSettings) { lock.withLock { configured.append(settings) } }
    var counts = (pages: 0, images: 0)
    func ocrCounts() throws -> (pages: Int, images: Int) { counts }
    func resetOCR() throws { ocrLog?.append("\(name):reset-ocr") }
    func ocrPage(relativePath: String, pageIndex: Int) throws -> OCRPageText? { nil }

    private var _browseList: [DocumentHit] = []
    private var _progress: [IndexProgress] = []
    var browseList: [DocumentHit] {
        get { lock.withLock { _browseList } }
        set { lock.withLock { _browseList = newValue } }
    }
    private var _browseCount = 0
    private var _browseDelay: Double = 0
    var browseCount: Int { lock.withLock { _browseCount } }
    /// Seconds each `browse` takes (a big folder or a slow disk).
    var browseDelay: Double {
        get { lock.withLock { _browseDelay } }
        set { lock.withLock { _browseDelay = newValue } }
    }
    func browse() throws -> [DocumentHit] {
        let delay = lock.withLock { _browseCount += 1; return _browseDelay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return browseList
    }
    /// Reported by a held `update` (as if the indexer had made progress).
    func emitProgress(_ p: IndexProgress) { lock.withLock { _progress.append(p) } }
}

@MainActor final class FakeEnvironment: AppEnvironment {
    var sources: [URL] = []
    var saveURL: URL?
    var printed: [NSPrintOperation] = []
    var opened: [URL] = []
    var confirmAnswer = true

    func chooseSources() -> [URL] { sources }
    func chooseSaveLocation(defaultName: String) -> URL? { saveURL }
    func runPrint(_ operation: NSPrintOperation) { printed.append(operation) }
    func openInPreview(_ url: URL) { opened.append(url) }
    var confirmations: [String] = []
    func confirmDeleteIndex(question: String) -> Bool { confirmations.append(question); return confirmAnswer }
}

func doc(_ path: String, pages: [Int], matches: Int? = nil, root: String = "/docs", modified: Date = .distantPast,
         relevance: Double = 0) -> DocumentHit {
    let hits = pages.map { PageHit(pageIndex: $0, matchCount: 1) }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    return DocumentHit(url: rootURL.appendingPathComponent(path), relativePath: path,
                       modifiedAt: modified, pageHits: hits, totalMatches: matches ?? hits.count, relevance: relevance,
                       sourceRoot: rootURL, pageCount: 0)
}

final class StringLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func append(_ e: String) { lock.withLock { _entries.append(e) } }
}

@MainActor func makeSettings() -> GridSettings {
    GridSettings(defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!)
}

@MainActor func makeModel(index: FakeIndex, environment: FakeEnvironment = FakeEnvironment(),
                          settings: GridSettings? = nil) -> AppModel {
    AppModel(settings: settings ?? makeSettings(),
             defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
             environment: environment,
             debounce: .zero,
             openIndex: { _ in index })
}

/// Polls `condition` on the main actor (for states reached while another task is held open).
@MainActor func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func append(_ url: URL) { lock.withLock { _urls.append(url) } }
}
