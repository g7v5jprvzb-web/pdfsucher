// FolderIndex.swift — Task 5.1
import Foundation
import IndexKit
import OCRKit
import SearchKit
import Synchronization

/// What `AppModel` needs from the index of one folder: search it, bring it up to date, empty it.
/// The real implementation is `FolderIndex`; tests use a fake.
public protocol FolderIndexing: AnyObject, Sendable {
    /// Whether the index file was found damaged and recreated (empty) when it was opened or used.
    var wasRebuilt: Bool { get }
    /// `onPartial` (optional) receives the documents of the first batch early, once (spec 1.1 §5).
    func search(_ q: ParsedQuery, sort: SortMode, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit]
    func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport
    func deleteIndex() throws
    /// Every document for browsing without a search term (spec 1.1 §12): the stored documents, or
    /// the scan result (page count 0 = not read yet) while the folder was never indexed.
    func browse() throws -> [DocumentHit]
    /// Phase 2 alone (spec 1.2 §3): recognizes every page still waiting; `update` is phase 1 only.
    func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport
    /// New OCR settings (spec 1.2 §7): the next `update` lists images or not.
    func configure(_ settings: OCRSettings)
    /// Recognized pages and images (spec 1.2 §7 „Anzahl erkannter Seiten/Bilder“).
    func ocrCounts() throws -> (pages: Int, images: Int)
    /// „Texterkennung für diese Quelle neu ausführen“: every recognized page waits again.
    func resetOCR() throws
    /// Stored text and word boxes of a recognized page (nil: a page with a text layer).
    func ocrPage(relativePath: String, pageIndex: Int) throws -> OCRPageText?
}

extension FolderIndexing {
    public func search(_ q: ParsedQuery, sort: SortMode) throws -> [DocumentHit] { try search(q, sort: sort, onPartial: nil) }
}

/// `IndexStore` + `Indexer` + `SearchService` for one folder.
///
/// Exactly one instance per folder and process (`shared`): a damage rebuild by one `IndexStore`
/// would leave a second instance on the deleted file (docs/decisions.md, Phase 1).
public final class FolderIndex: FolderIndexing {
    public let root: URL
    private let store: IndexStore
    /// Rebuilt by `configure` (an Indexer's OCR settings are fixed, decisions „1.2 OCR-Index“).
    private let indexerState: Mutex<(indexer: Indexer, settings: OCRSettings)>
    private var indexer: Indexer { indexerState.withLock { $0.indexer } }
    private var includeImages: Bool { indexerState.withLock { $0.settings.includeImages } }
    private let service: SearchService

    private static let registry = Mutex<[String: FolderIndex]>([:])

    /// The index of `root`, created on first use. `indexURL` defaults to
    /// `IndexStore.location(forFolder:)`; tests pass a file in a temp directory.
    public static func shared(root: URL, indexURL: URL? = nil) throws -> FolderIndex {
        let root = root.standardizedFileURL
        return try registry.withLock { indexes in
            if let existing = indexes[root.path] { return existing }
            let created = try FolderIndex(root: root, indexURL: indexURL ?? IndexStore.location(forFolder: root))
            indexes[root.path] = created
            return created
        }
    }

    /// Internal for tests: a second instance on the same file stands for the next app start.
    init(root: URL, indexURL: URL) throws {
        self.root = root
        store = try IndexStore(fileURL: indexURL, root: root)
        indexerState = Mutex((Self.makeIndexer(root: root, store: store, settings: .default), .default))
        service = SearchService(index: store, root: root)
    }

    public var wasRebuilt: Bool { store.wasRebuilt }

    /// Phase 1 lists images when wanted; recognition runs only through `recognize` (the AppModel queue
    /// runs phase 1 of every folder first).
    private static func makeIndexer(root: URL, store: IndexStore, settings: OCRSettings) -> Indexer {
        Indexer(root: root, store: store, ocr: VisionOCRSource(),
                ocrSettings: OCRSettings(recognizeText: false, includeImages: settings.includeImages))
    }

    /// Replaces the Indexer for new settings. Callers start no run before the previous one has returned
    /// (the AppModel queue runs one at a time): a run on the old Indexer would not wait for the new one.
    public func configure(_ settings: OCRSettings) {
        indexerState.withLock { state in
            guard state.settings != settings else { return }
            state = (Self.makeIndexer(root: root, store: store, settings: settings), settings)
        }
    }

    public func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        try await indexer.recognizePending(progress: progress)
    }

    public func ocrCounts() throws -> (pages: Int, images: Int) { try store.ocrCounts() }

    public func resetOCR() throws { try store.resetOCR() }

    public func ocrPage(relativePath: String, pageIndex: Int) throws -> OCRPageText? {
        try store.ocrPage(relativePath: relativePath, pageIndex: pageIndex).map { OCRPageText(text: $0.text, words: $0.words) }
    }

    public func search(_ q: ParsedQuery, sort: SortMode, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        try service.search(q, sort: sort, onPartial: onPartial)
    }

    private let updating = Mutex(false)
    /// The folder scan for browsing during one `update` (scanning again on every refresh would compete
    /// with the indexer's own I/O; final review of 1.1).
    private let scanCache = Mutex<[ScannedFile]?>(nil)
    private let scans = Mutex(0)

    /// An `update` is running: files not stored yet are listed from a scan when browsing.
    public var isUpdating: Bool { updating.withLock { $0 } }
    /// Number of folder scans done for browsing (tests).
    var scanCount: Int { scans.withLock { $0 } }

    public func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        updating.withLock { $0 = true }
        scanCache.withLock { $0 = nil }
        defer {
            updating.withLock { $0 = false }
            scanCache.withLock { $0 = nil }
        }
        return try await indexer.update(progress: progress)
    }

    /// The scan for browsing: cached while an update runs, fresh otherwise.
    private func scanForBrowsing() -> [ScannedFile] {
        if isUpdating, let cached = scanCache.withLock({ $0 }) { return cached }
        scans.withLock { $0 += 1 }
        let scanned = (try? FolderScanner(includeImages: includeImages).scan(root: root)) ?? []      // unreachable: nothing to add
        if isUpdating { scanCache.withLock { $0 = scanned } }
        return scanned
    }

    public func deleteIndex() throws {
        try store.deleteIndex()
    }

    /// The stored documents; while the folder is being indexed or was never indexed, plus the files a
    /// scan finds that are not stored yet (page count 0 = not read yet).
    public func browse() throws -> [DocumentHit] {
        let stored = try store.documents()
        return try browse(stored: stored, includingScan: stored.isEmpty || isUpdating)
    }

    func browse(includingScan: Bool) throws -> [DocumentHit] {
        try browse(stored: store.documents(), includingScan: includingScan)
    }

    private func browse(stored: [StoredDocument], includingScan: Bool) throws -> [DocumentHit] {
        var entries = stored.map { doc in
            DocumentHit(url: root.appendingPathComponent(doc.relativePath, isDirectory: false), relativePath: doc.relativePath,
                        modifiedAt: doc.modifiedAt, pageHits: [], totalMatches: 0, relevance: 0,
                        sourceRoot: root, pageCount: doc.status == .error ? 0 : doc.pageCount,
                        isUnreadable: doc.status == .error, isImage: doc.kind == .image)
        }
        guard includingScan else { return entries }
        let known = Set(stored.map(\.relativePath))
        for file in scanForBrowsing() where !known.contains(file.relativePath) {
            entries.append(DocumentHit(url: root.appendingPathComponent(file.relativePath, isDirectory: false),
                                       relativePath: file.relativePath, modifiedAt: file.modifiedAt, pageHits: [],
                                       totalMatches: 0, relevance: 0, sourceRoot: root, pageCount: 0,
                                       isImage: DocumentKind(fileExtension: file.url.pathExtension) == .image))
        }
        return entries
    }
}
