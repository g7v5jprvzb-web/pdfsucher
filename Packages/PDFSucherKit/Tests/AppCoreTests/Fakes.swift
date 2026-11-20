import AppKit
import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import ViewerUI
@testable import AppCore

/// A held fake run that nobody releases or cancels within this time is a test bug (or a regression in the
/// queue's pre-emption): it records an issue and throws instead of hanging the suite.
let fakeHoldDeadline: Duration = .seconds(20)

struct FakeHoldTimedOut: Error {}

/// Records an issue and throws once `deadline` has passed.
func checkFakeHold(_ what: String, deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now > deadline else { return }
    Issue.record("\(what) was held longer than \(fakeHoldDeadline) without release or cancellation")
    throw FakeHoldTimedOut()
}

/// Stand-in for a folder index: scripted search results, a counter, and an `update` that can be
/// held open until the test releases it (or the task is cancelled).
final class FakeIndex: FolderIndexing, @unchecked Sendable {
    private let lock = NSLock()
    /// Renderer names this index reports stored layouts of (`hasLayouts(byRenderer:)`, 1.3.2).
    var storedRenderers: Set<String> {
        get { lock.withLock { _storedRenderers } }
        set { lock.withLock { _storedRenderers = newValue } }
    }
    private var _storedRenderers: Set<String> = []
    func hasLayouts(byRenderer renderer: String) throws -> Bool { storedRenderers.contains(renderer) }
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

    private var _searchNames: [Bool] = []
    private var _nameExtensions: [Bool] = []
    /// `searchNames` of every search (1.3.2: file name search).
    var searchNamesSeen: [Bool] { lock.withLock { _searchNames } }
    /// `nameWithExtension` of every search.
    var nameExtensionsSeen: [Bool] { lock.withLock { _nameExtensions } }

    func search(_ q: ParsedQuery, sort: SortMode, searchNames: Bool, nameWithExtension: Bool,
                onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        lock.withLock { _searchNames.append(searchNames); _nameExtensions.append(nameWithExtension) }
        return try search(q, sort: sort, onPartial: onPartial)
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

    /// Called (off the main actor) at the start of every `update` with its number, 1 for the first.
    var beforeUpdate: (@Sendable (Int) -> Void)?
    private var _updateCount = 0

    func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        let number = lock.withLock { _updateCount += 1; return _updateCount }
        beforeUpdate?(number)
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
    /// `includeOffice` of every `configure` call (1.3 Part B).
    private(set) var configuredOffice: [Bool] = []

    func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        lock.withLock { _ocrCount += 1 }
        ocrLog?.append("\(name):ocr-start")
        progress(IndexProgress(done: 0, total: lock.withLock { _ocrTotal }, currentFile: nil, phase: .ocr))
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while holdRecognition {
            for p in lock.withLock({ defer { _progress.removeAll() }; return _progress }) { progress(p) }
            if Task.isCancelled {
                ocrLog?.append("\(name):ocr-cancelled")
                throw CancellationError()
            }
            try checkFakeHold("\(name) recognition", deadline: deadline)
            try? await Task.sleep(for: .milliseconds(2))
        }
        if let after = hitsAfterRecognition { hits = after }
        ocrLog?.append("\(name):ocr-end")
        return ocrReport
    }

    /// 1.4.0 P3: scopes of every scoped `update`, and how often the layout was asked to stop gently.
    private var _scopedUpdates: [[String]] = []
    private var _gentleStops = 0
    var scopedUpdates: [[String]] { lock.withLock { _scopedUpdates } }
    var gentleStops: Int { lock.withLock { _gentleStops } }
    func update(scopes: [String], progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        lock.withLock { _scopedUpdates.append(scopes) }
        return try await update(progress: progress)
    }
    func stopLayoutGently() { lock.withLock { _gentleStops += 1 } }

    /// 1.4.0 P2: every priority set.
    private var _priorities: [[String]] = []
    var priorities: [[String]] { lock.withLock { _priorities } }
    func setPriority(_ prefixes: [String]) { lock.withLock { _priorities.append(prefixes) } }

    /// Wortteil-Index events "<name>:wordparts-start|end|cancelled" (1.3.12; an own log, so older sequences stay).
    var wordPartsLog: StringLog?
    private var _holdWordParts = false
    var holdWordParts: Bool {
        get { lock.withLock { _holdWordParts } }
        set { lock.withLock { _holdWordParts = newValue } }
    }

    func buildWordParts(progress: @Sendable (IndexProgress) -> Void) async throws -> Int {
        wordPartsLog?.append("\(name):wordparts-start")
        progress(IndexProgress(done: 0, total: 10, currentFile: nil, phase: .wordParts))
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while holdWordParts {
            if Task.isCancelled {
                wordPartsLog?.append("\(name):wordparts-cancelled")
                throw CancellationError()
            }
            try checkFakeHold("\(name) word parts", deadline: deadline)
            try? await Task.sleep(for: .milliseconds(2))
        }
        wordPartsLog?.append("\(name):wordparts-end")
        return 10
    }

    func configure(_ settings: OCRSettings, includeOffice: Bool) {
        lock.withLock { configured.append(settings); configuredOffice.append(includeOffice) }
    }
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

    // MARK: Phase „layout“ (Word/PowerPoint, 1.3 Part B)

    /// Layout events "<name>:layout-start|end|cancelled" (not in `ocrLog`, so 1.2 tests keep their sequences;
    /// layout tests pass the same log for both).
    var layoutLog: StringLog?
    private var _holdLayout = false
    private var _layoutReport = LayoutReport()
    private var _layoutCount = 0
    private var _layoutRequests: [String] = []
    var holdLayout: Bool {
        get { lock.withLock { _holdLayout } }
        set { lock.withLock { _holdLayout = newValue } }
    }
    var layoutReport: LayoutReport {
        get { lock.withLock { _layoutReport } }
        set { lock.withLock { _layoutReport = newValue } }
    }
    var layoutCount: Int { lock.withLock { _layoutCount } }
    private var _finishLayoutDespiteCancel = false
    /// A cancelled held `layOut` ignores the cancellation and still returns `layoutReport` once released
    /// (a run that ends successfully just after it was stopped).
    var finishLayoutDespiteCancel: Bool {
        get { lock.withLock { _finishLayoutDespiteCancel } }
        set { lock.withLock { _finishLayoutDespiteCancel = newValue } }
    }
    /// `requestLayout` calls: "kind:<kind>" or "path:<relativePath>"; `adoptPowerPointRenderer`: "adopt:powerpoint".
    var layoutRequests: [String] { lock.withLock { _layoutRequests } }

    private var _layoutTotal = 2
    /// The documents the first progress of `layOut` reports (like the indexer's pending jobs; 0 = no Office files).
    var layoutTotal: Int {
        get { lock.withLock { _layoutTotal } }
        set { lock.withLock { _layoutTotal = newValue } }
    }

    func layOut(progress: @Sendable (IndexProgress) -> Void) async throws -> LayoutReport {
        lock.withLock { _layoutCount += 1 }
        layoutLog?.append("\(name):layout-start")
        progress(IndexProgress(done: 0, total: layoutTotal, currentFile: nil, phase: .layout))
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while holdLayout {
            for p in lock.withLock({ defer { _progress.removeAll() }; return _progress }) { progress(p) }
            if Task.isCancelled, !finishLayoutDespiteCancel {
                layoutLog?.append("\(name):layout-cancelled")
                throw CancellationError()
            }
            try checkFakeHold("\(name) layout", deadline: deadline)
            try? await Task.sleep(for: .milliseconds(2))
        }
        layoutLog?.append("\(name):layout-end")
        return layoutReport
    }
    var layoutCountsValue = LayoutCounts()
    func layoutCounts() throws -> LayoutCounts { layoutCountsValue }
    func requestLayout(kind: DocumentKind) throws { lock.withLock { _layoutRequests.append("kind:\(kind.rawValue)") } }
    func requestLayout(relativePath: String) throws { lock.withLock { _layoutRequests.append("path:\(relativePath)") } }
    private var _holdAdopt = false
    private var _adoptStarted = 0
    /// `adoptPowerPointRenderer` calls begun (also held ones).
    var adoptStarted: Int { lock.withLock { _adoptStarted } }
    /// Holds `adoptPowerPointRenderer` (runs detached) until cleared.
    var holdAdopt: Bool {
        get { lock.withLock { _holdAdopt } }
        set { lock.withLock { _holdAdopt = newValue } }
    }
    func adoptPowerPointRenderer() throws {
        lock.withLock { _adoptStarted += 1 }
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while holdAdopt {
            try checkFakeHold("\(name) adopt", deadline: deadline)
            Thread.sleep(forTimeInterval: 0.002)
        }
        lock.withLock { _layoutRequests.append("adopt:powerpoint") }
    }

    private var _outdated: Set<String> = []
    private var _outdatedChecks: [String] = []
    /// Relative paths whose file on disk differs from the stored version (`isOutdated`).
    var outdatedPaths: Set<String> {
        get { lock.withLock { _outdated } }
        set { lock.withLock { _outdated = newValue } }
    }
    /// Every `isOutdated` call, by relative path.
    var outdatedChecks: [String] { lock.withLock { _outdatedChecks } }
    func isOutdated(relativePath: String) throws -> Bool {
        lock.withLock {
            _outdatedChecks.append(relativePath)
            return _outdated.contains(relativePath)
        }
    }
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
    var openedWithDefaultApp: [URL] = []
    func openWithDefaultApp(_ url: URL) { openedWithDefaultApp.append(url) }
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

/// The slide cache of every test model and test folder index (1.3 Teil B Task 9, M1): a folder in the temp
/// directory, never the user's `~/Library/Application Support/PDFSucher/SlideCache`.
let testSlideCache = SlideCache(root: FileManager.default.temporaryDirectory
    .appendingPathComponent("AppCoreTests-SlideCache-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true))

@MainActor func makeModel(index: FakeIndex, environment: FakeEnvironment = FakeEnvironment(),
                          settings: GridSettings? = nil) -> AppModel {
    AppModel(settings: settings ?? makeSettings(),
             defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
             environment: environment,
             slideCache: testSlideCache,
             debounce: .zero,
             openIndex: { _ in index }, officeRendering: PowerPointDisplaySetting())
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
