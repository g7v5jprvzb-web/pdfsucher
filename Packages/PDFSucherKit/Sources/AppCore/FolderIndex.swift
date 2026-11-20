// FolderIndex.swift — Task 5.1
import Foundation
import IndexKit
import OCRKit
import OfficeKit
import os
import SearchKit
import Synchronization

/// What `AppModel` needs from the index of one folder: search it, bring it up to date, empty it.
/// The real implementation is `FolderIndex`; tests use a fake.
public protocol FolderIndexing: AnyObject, Sendable {
    /// Whether the index file was found damaged and recreated (empty) when it was opened or used.
    var wasRebuilt: Bool { get }
    /// `onPartial` (optional) receives the documents of the first batch early, once (spec 1.1 §5).
    func search(_ q: ParsedQuery, sort: SortMode, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit]
    /// With `searchNames` the file names count too (spec 1.3.2 §1); `nameWithExtension`: with their extension.
    func search(_ q: ParsedQuery, sort: SortMode, searchNames: Bool, nameWithExtension: Bool, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit]
    func update(progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport
    func deleteIndex() throws
    /// Every document for browsing without a search term (spec 1.1 §12): the stored documents, or
    /// the scan result (page count 0 = not read yet) while the folder was never indexed.
    func browse() throws -> [DocumentHit]
    /// Phase 2 alone (spec 1.2 §3): recognizes every page still waiting; `update` is phase 1 only.
    func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport
    /// New OCR settings (spec 1.2 §7) and „office.include“ (spec 1.3): the next `update` lists images
    /// and Word/PowerPoint files or not.
    func configure(_ settings: OCRSettings, includeOffice: Bool)
    /// Recognized pages and images (spec 1.2 §7 „Anzahl erkannter Seiten/Bilder“).
    func ocrCounts() throws -> (pages: Int, images: Int)
    /// „Texterkennung für diese Quelle neu ausführen“: every recognized page waits again.
    func resetOCR() throws
    /// Stored text and word boxes of a recognized page (nil: a page with a text layer).
    func ocrPage(relativePath: String, pageIndex: Int) throws -> OCRPageText?
    /// Phase „layout“ alone (spec 1.3): lays out every Word/PowerPoint document waiting for it. The report's
    /// problem lists describe the whole index; cancelling keeps every document already stored.
    func layOut(progress: @Sendable (IndexProgress) -> Void) async throws -> LayoutReport
    /// Word/PowerPoint documents by layout state (settings).
    func layoutCounts() throws -> LayoutCounts
    /// Every document of `kind` waits for a new layout (e.g. after „Folien-Cache leeren“).
    func requestLayout(kind: DocumentKind) throws
    /// Records the PowerPoint renderer the layout source uses now as expected; when it differs from the recorded one,
    /// every PowerPoint waits for a new layout with its old text removed, in one transaction (renderer switch,
    /// 1.3 Teil B Task 12). A write: call it off the main actor.
    func adoptPowerPointRenderer() throws
    /// This Word/PowerPoint document waits for a new layout („Neu einlesen“).
    func requestLayout(relativePath: String) throws
    /// The file on disk is not the version stored (other size or date, or not stored at all): a phase-1 run
    /// would read it again (1.3 Teil B: folders are not watched, a file edited during the session is found here).
    func isOutdated(relativePath: String) throws -> Bool
    /// Whether any document is stored as laid out by `renderer` (1.3.2: Word with substitute fonts).
    func hasLayouts(byRenderer renderer: String) throws -> Bool
    /// The index file on disk (settings „Speicher“: its size); nil for test doubles without a file.
    var indexFileURL: URL? { get }
    /// „Wortteil-Index“ (1.3.12): moves the pages phase 1 stored into the trigram index; cancellable without loss.
    func buildWordParts(progress: @Sendable (IndexProgress) -> Void) async throws -> Int
    /// 1.4.0 P2: relative path prefixes (ending in "/") whose files go first in layout, recognition and Wortteil-Index.
    func setPriority(_ prefixes: [String])
    /// 1.4.0 P3: phase 1 only for these folders (relative paths, changed on disk); the rest of the index stays.
    func update(scopes: [String], progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport
    /// 1.4.0 P3: the running layout starts no further file, finishes the ones in progress, then ends as cancelled.
    func stopLayoutGently()
}

extension FolderIndexing {
    /// Test doubles without a trigram index: nothing to build.
    public func buildWordParts(progress: @Sendable (IndexProgress) -> Void) async throws -> Int { 0 }
    /// Test doubles: no order to change.
    public func setPriority(_ prefixes: [String]) {}
    /// Test doubles: always the whole folder.
    public func update(scopes: [String], progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        try await update(progress: progress)
    }
    /// Test doubles: nothing to stop gently.
    public func stopLayoutGently() {}
    /// Test doubles without a file: none.
    public var indexFileURL: URL? { nil }
    /// Test doubles without layouts: none.
    public func hasLayouts(byRenderer renderer: String) throws -> Bool { false }
    public func search(_ q: ParsedQuery, sort: SortMode) throws -> [DocumentHit] { try search(q, sort: sort, onPartial: nil) }
    /// Indexes without file name search (older test doubles) search the content only.
    public func search(_ q: ParsedQuery, sort: SortMode, searchNames: Bool, nameWithExtension: Bool,
                       onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        try search(q, sort: sort, onPartial: onPartial)
    }
}

/// `IndexStore` + `Indexer` + `SearchService` for one folder.
///
/// Exactly one instance per folder and process (`shared`): a damage rebuild by one `IndexStore`
/// would leave a second instance on the deleted file (docs/decisions.md, Phase 1).
public final class FolderIndex: FolderIndexing {
    public let root: URL
    private let store: IndexStore
    /// Rebuilt by `configure` (an Indexer's OCR settings are fixed, decisions „1.2 OCR-Index“).
    private let indexerState: Mutex<(indexer: Indexer, settings: OCRSettings, includeOffice: Bool)>
    private var indexer: Indexer { indexerState.withLock { $0.indexer } }
    private var includeImages: Bool { indexerState.withLock { $0.settings.includeImages } }
    private var includeOffice: Bool { indexerState.withLock { $0.includeOffice } }
    /// Makes the layout source for Word/PowerPoint (tests pass a fake).
    private let makeLayout: @Sendable () -> any PageLayoutSource
    private let service: SearchService

    private static let registry = Mutex<[String: FolderIndex]>([:])
    private static let log = Logger(subsystem: "local.pdfsucher", category: "index")
    /// The layout source of the current Indexer (nil with Word/PowerPoint off); its PowerPoint renderer is adopted
    /// at the start of each run, not in `configure` (main actor, no SQLite there).
    private let currentLayout: Mutex<(any PageLayoutSource)?>
    /// `name:version` adopted last by this instance; equal → `adoptPowerPointRenderer` skips the transaction.
    private let adoptedIdentity = Mutex<String?>(nil)
    private let adoptions = Mutex(0)
    /// 1.4.0 P1: indexes of subfolders were looked at (once per instance, in the first `update`'s turn).
    private let childrenImported = Mutex(false)
    /// 1.4.0 P2: shared with every Indexer of this folder (also after `configure` rebuilt it).
    private let priority = PriorityBox()
    /// Where the index files lie (the subfolders' indexes are looked for there).
    private let indexDirectory: URL

    /// The index of `root`, created on first use. `indexURL` defaults to
    /// `IndexStore.location(forFolder:)`; tests pass a file in a temp directory.
    /// `slideCache` receives the slides of its PowerPoint files (tests pass a temp one; used when it is created).
    public static func shared(root: URL, indexURL: URL? = nil, slideCache: SlideCache = .shared) throws -> FolderIndex {
        let root = root.standardizedFileURL
        return try registry.withLock { indexes in
            if let existing = indexes[root.path] { return existing }
            let created = try FolderIndex(root: root, indexURL: indexURL ?? IndexStore.location(forFolder: root),
                                          slideCache: slideCache)
            indexes[root.path] = created
            return created
        }
    }

    /// Internal for tests: a second instance on the same file stands for the next app start.
    /// Word/PowerPoint are listed until `configure` says otherwise („office.include“ is on by default).
    /// Without `makeLayout` the layout source is `OfficeLayoutSource.standard` (slides in `slideCache`, the shared
    /// „PowerPoint-Darstellung“ choice).
    init(root: URL, indexURL: URL, slideCache: SlideCache = .shared,
         makeLayout: (@Sendable () -> any PageLayoutSource)? = nil) throws {
        self.root = root
        indexDirectory = indexURL.deletingLastPathComponent()
        let make = makeLayout ?? { OfficeLayoutSource.standard(cache: slideCache) }
        self.makeLayout = make
        store = try IndexStore(fileURL: indexURL, root: root)
        let layout = make()
        indexerState = Mutex((Self.makeIndexer(root: root, store: store, settings: .default,
                                               layout: layout, priority: priority), .default, true))
        service = SearchService(index: store, root: root)
        currentLayout = Mutex(layout)
        // 1.3 Teil B Task 12: another PowerPoint renderer than the index expects (a display switch while this folder was
        // not loaded, the SlideKit merge): the old slide text goes at once. Opening runs off the main actor.
        adoptPowerPointRendererLogged()
    }

    public var wasRebuilt: Bool { store.wasRebuilt }

    public var indexFileURL: URL? { store.fileURL }

    /// The index files of every `FolderIndex` created in this process, open or of a removed source (their store
    /// stays open): „Verwaiste Indexe löschen“ never touches them.
    public static func openIndexFiles() -> Set<String> {
        registry.withLock { Set($0.values.map { $0.store.fileURL.standardizedFileURL.path }) }
    }

    /// Phase 1 lists images when wanted and Word/PowerPoint with a layout source (stored as waiting);
    /// recognition and layout run only through `recognize` / the layout phase (the AppModel queue runs
    /// phase 1 of every folder first). Without a layout source Office files leave the index.
    private static func makeIndexer(root: URL, store: IndexStore, settings: OCRSettings,
                                    layout: (any PageLayoutSource)?, priority: PriorityBox) -> Indexer {
        var wordPreview: (@Sendable (URL) -> String?)?
        if layout != nil { wordPreview = { @Sendable url in WordPreviewText.text(of: url) } }
        return Indexer(root: root, store: store, ocr: VisionOCRSource(),
                ocrSettings: OCRSettings(recognizeText: false, includeImages: settings.includeImages),
                layout: layout, layoutDuringUpdate: false, priority: { priority.prefixes }, stopRequests: { priority.stops },
                wordPreview: wordPreview)
    }

    public func setPriority(_ prefixes: [String]) { priority.prefixes = prefixes }

    public func stopLayoutGently() { priority.requestStop() }

    /// Replaces the Indexer for new settings. Callers start no run before the previous one has returned
    /// (the AppModel queue runs one at a time): a run on the old Indexer would not wait for the new one.
    /// Called on the main actor: touches no SQLite. A changed PowerPoint renderer is adopted (old slide text removed) at
    /// the start of the folder's next `update`/`layOut`; until then a search may still find the old text (short: the
    /// AppModel queues the folder again on a switch).
    public func configure(_ settings: OCRSettings, includeOffice: Bool) {
        indexerState.withLock { state in
            guard state.settings != settings || state.includeOffice != includeOffice else { return }
            let layout = includeOffice ? makeLayout() : nil
            currentLayout.withLock { $0 = layout }
            state = (Self.makeIndexer(root: root, store: store, settings: settings, layout: layout, priority: priority), settings, includeOffice)
        }
    }

    public func recognize(progress: @Sendable (IndexProgress) -> Void) async throws -> OCRReport {
        try await indexer.recognizePending(progress: progress)
    }

    public func ocrCounts() throws -> (pages: Int, images: Int) { try store.ocrCounts() }

    public func buildWordParts(progress: @Sendable (IndexProgress) -> Void) async throws -> Int {
        try await indexer.buildWordParts(progress: progress)
    }

    public func layOut(progress: @Sendable (IndexProgress) -> Void) async throws -> LayoutReport {
        try await indexer.layOutPending(progress: progress, atTurnStart: { [self] in adoptPowerPointRendererLogged() })
    }

    public func layoutCounts() throws -> LayoutCounts { try store.layoutCounts() }

    public func requestLayout(kind: DocumentKind) throws { try store.requestLayout(kind: kind) }

    public func adoptPowerPointRenderer() throws {
        guard let layout = currentLayout.withLock({ $0 }) else { return }
        let renderer = layout.renderer(for: .powerpoint)
        let identity = "\(renderer.name):\(renderer.version)"
        guard adoptedIdentity.withLock({ $0 }) != identity else { return }      // unchanged: no transaction at all
        try store.adoptLayoutRenderer(name: renderer.name, version: renderer.version, for: .powerpoint, clearingPages: true)
        adoptedIdentity.withLock { $0 = identity }
        adoptions.withLock { $0 += 1 }
    }

    /// Store transactions of `adoptPowerPointRenderer` (tests).
    var powerPointAdoptions: Int { adoptions.withLock { $0 } }

    /// At index open and at the start of every `update`/`layOut`, inside the Indexer's turn (`atTurnStart`, off the main
    /// actor, before any phase-1 or layout work; a still running layout of the old renderer finishes first).
    /// Errors are only logged; the Indexer adopts again before its layout phase.
    private func adoptPowerPointRendererLogged() {
        do { try adoptPowerPointRenderer() } catch {
            Self.log.error("Cannot adopt the PowerPoint renderer: \(String(describing: error), privacy: .public)")
        }
    }

    /// 1.4.0 P1: before the first phase 1 of this folder in the session, the indexes of its subfolders on disk (sources
    /// it replaced, or loaded earlier) hand over what they hold, so phase 1 finds those files unchanged instead of reading
    /// them again. Each child index once per parent index; a failure only costs the time to read the files.
    private func importChildIndexesOnce() {
        guard childrenImported.withLock({ done in defer { done = true }; return !done }) else { return }
        let metrics = IndexMetrics.shared
        for child in IndexStore.childIndexes(of: root, in: indexDirectory, excluding: store.fileURL) {
            let start = ContinuousClock.now
            do {
                let result = try store.importChild(child)
                guard result.documents + result.layoutDropped > 0 else { continue }
                Self.log.notice("Took over \(result.documents) documents from a subfolder's index")
                metrics.log("source_import", ["source": IndexMetrics.hash(root), "child": IndexMetrics.hash(path: child.folderPath),
                                              "documents": result.documents, "pages": result.pages,
                                              "layout_dropped": result.layoutDropped, "ms": IndexMetrics.ms(since: start)])
            } catch {
                Self.log.error("Cannot take over a subfolder's index: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Paths from file URLs may be decomposed (`a` + `¨`); the index stores them precomposed (`FolderScanner`).
    public func requestLayout(relativePath: String) throws {
        try store.requestLayout(relativePath: relativePath.precomposedStringWithCanonicalMapping)
    }

    public func hasLayouts(byRenderer renderer: String) throws -> Bool { try store.hasLayouts(byRenderer: renderer) }

    public func isOutdated(relativePath: String) throws -> Bool {
        let path = relativePath.precomposedStringWithCanonicalMapping
        guard let stored = try store.document(relativePath: path) else { return true }
        return !Indexer.isUnchanged(fileSize: stored.fileSize, modifiedAt: stored.modifiedAt,
                                    at: root.appendingPathComponent(path, isDirectory: false))
    }

    public func resetOCR() throws { try store.resetOCR() }

    public func ocrPage(relativePath: String, pageIndex: Int) throws -> OCRPageText? {
        try store.ocrPage(relativePath: relativePath.precomposedStringWithCanonicalMapping, pageIndex: pageIndex).map { OCRPageText(text: $0.text, words: $0.words) }
    }

    public func search(_ q: ParsedQuery, sort: SortMode, onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        try service.search(q, sort: sort, onPartial: onPartial)
    }

    public func search(_ q: ParsedQuery, sort: SortMode, searchNames: Bool, nameWithExtension: Bool,
                       onPartial: (@Sendable ([DocumentHit]) -> Void)?) throws -> [DocumentHit] {
        try service.search(q, sort: sort, searchNames: searchNames, nameWithExtension: nameWithExtension, onPartial: onPartial)
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
        try await update(scopes: nil, progress: progress)
    }

    public func update(scopes: [String], progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        try await update(scopes: Optional(scopes), progress: progress)
    }

    private func update(scopes: [String]?, progress: @Sendable (IndexProgress) -> Void) async throws -> IndexReport {
        updating.withLock { $0 = true }
        scanCache.withLock { $0 = nil }
        defer {
            updating.withLock { $0 = false }
            scanCache.withLock { $0 = nil }
        }
        // Inside the Indexer's turn, before phase 1: no old slide text after a renderer switch, and no layout of the
        // old renderer can store a deck after the clear (it holds the turn until it is done).
        return try await indexer.update(scopes: scopes, progress: progress, atTurnStart: { [self] in
            adoptPowerPointRendererLogged()
            importChildIndexesOnce()
        })
    }

    /// The scan for browsing: cached while an update runs, fresh otherwise.
    private func scanForBrowsing() -> [ScannedFile] {
        if isUpdating, let cached = scanCache.withLock({ $0 }) { return cached }
        scans.withLock { $0 += 1 }
        let scanned = (try? FolderScanner(includeImages: includeImages, includeOffice: includeOffice).scan(root: root)) ?? []      // unreachable: nothing to add
        if isUpdating { scanCache.withLock { $0 = scanned } }
        return scanned
    }

    public func deleteIndex() throws {
        adoptedIdentity.withLock { $0 = nil }          // the record goes with the index
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
                        isUnreadable: doc.status == .error, kind: doc.kind, isSimplified: doc.isSimplified,
                        fileSize: doc.fileSize)
        }
        guard includingScan else { return entries }
        let known = Set(stored.map(\.relativePath))
        for file in scanForBrowsing() where !known.contains(file.relativePath) {
            entries.append(DocumentHit(url: root.appendingPathComponent(file.relativePath, isDirectory: false),
                                       relativePath: file.relativePath, modifiedAt: file.modifiedAt, pageHits: [],
                                       totalMatches: 0, relevance: 0, sourceRoot: root, pageCount: 0,
                                       kind: file.kind, fileSize: file.fileSize))
        }
        return entries
    }
}

/// The folder filter's path prefixes for one folder's Indexers (1.4.0 P2).
/// Also the gentle stop of a running layout (P3).
final class PriorityBox: Sendable {
    private let value = Mutex<[String]>([])
    private let stopCount = Mutex(0)
    var prefixes: [String] {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
    var stops: Int { stopCount.withLock { $0 } }
    func requestStop() { stopCount.withLock { $0 += 1 } }
}
