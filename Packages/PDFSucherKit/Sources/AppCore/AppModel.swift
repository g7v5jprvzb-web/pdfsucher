// AppModel.swift — Task 5.1 (wiring of the kits, debounce, state); 1.1 Task 2 (several sources)
import AppKit
import Foundation
import IndexKit
import Observation
import os
import OCRKit
import OutputKit
import PDFKit
import SearchKit
import ViewerUI

/// The app's `ViewerModel`: holds the loaded sources (folders with their index, single PDFs), indexes
/// the folders one after another in the background, searches all sources as the user types (debounced),
/// keeps the selection across searches, saves and prints.
@MainActor @Observable public final class AppModel: ViewerModel {
    public enum Text {
        public static let corruptIndex = "Index war beschädigt und wird neu aufgebaut"
        public static let noText = "PDF enthält keinen Text (Scan)"
        public static let unreadable = "PDF kann nicht gelesen werden (beschädigt oder passwortgeschützt)"
        public static let unreadableImage = "Bild kann nicht gelesen werden"
    }
    /// 1.0 key, read once to migrate to `sourcesKey`.
    static let lastFolderKey = "lastFolderPath"
    static let sourcesKey = "sources"

    public var queryText = "" {
        didSet {
            guard queryText != oldValue else { return }
            historyTask?.cancel()                 // a pause only counts once typing stopped (1.2.2 §1)
            historyArmed = true                   // only a typed term arms the pause (not a refresh, review I2)
            scheduleSearch(debounced: true)
        }
    }
    public private(set) var hits: [DocumentHit] = []
    public private(set) var query = ParsedQuery(terms: [])
    /// A tick or a tile chosen with the mouse or the arrows means the search arrived (1.2.2 §1).
    /// Only a single tick or untick counts; clearing or pruning several at once does not (review M1).
    public var selection = PageSelection() {
        didSet { if abs(selection.count - oldValue.count) == 1 { noteSearchArrived() } }
    }
    public var focusedPage: PageRef? {
        didSet { if focusedPage != nil, focusedPage != oldValue { noteSearchArrived() } }
    }
    /// The last search terms (1.2.2 §1).
    public let searchHistory: SearchHistory
    /// A finished search with hits is remembered after this pause without typing.
    var historyDelay: Duration = .milliseconds(1500)
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyArmed = false
    public let settings: GridSettings
    /// Remembered between launches (1.2.1 §2).
    public let previewZoom: PreviewZoom
    public let keyboard: KeyboardSettings
    public private(set) var indexStatus: IndexStatus = .none
    public private(set) var summary = ""
    /// True from the start of a search (after the typing delay) until its result is shown.
    public private(set) var isSearching = false
    /// The search field is empty: `hits` lists every file of every source (spec 1.1 §12).
    public private(set) var isBrowsing = false
    public var notice: String? { noticeKind?.text }
    public var alertMessage: String? {
        // Any new or closed alert ends the offer; `showAlert` sets it again for its own message.
        didSet { alertOffersRemovingMissingPages = false }
    }
    /// The current alert is about ticked pages whose file is gone or shorter; it offers
    /// „Fehlende Seiten aus Auswahl entfernen“ (Chris, Task 5.6).
    public private(set) var alertOffersRemovingMissingPages = false
    /// The print document is being built („Druck wird vorbereitet…“); „Drucken …“ is disabled.
    public private(set) var isPreparingPrint = false

    /// The loaded sources in the order they were added (spec 1.1 §4).
    public var sources: [LoadedSourceRef] { sourceList.items }
    /// Folder sources, for „Index löschen …“.
    public var folderSources: [URL] { sourceList.items.filter(\.isFolder).map(\.url) }
    /// „Index löschen …“ is available: at least one folder (with its index) is loaded.
    public var canDeleteIndex: Bool { !folderSources.isEmpty }

    /// Kinds of hint, so each can be cleared by the event that makes it obsolete.
    enum Notice: Equatable {
        case corruptIndex, noText, unreadable, unreadableImage, noTextImage, noTextPDF, ocrOff, searchFailed(String), indexFailed(String)
        case ignoredDrops(Int), alreadyContained(String, in: String), missingSources([String])
        var text: String {
            switch self {
            case .corruptIndex: Text.corruptIndex
            case .noText: Text.noText
            case .unreadable: Text.unreadable
            case .unreadableImage: Text.unreadableImage
            case .noTextImage: "Im Bild wurde kein Text erkannt"
            case .noTextPDF: "Im PDF wurde kein Text erkannt"
            case .ocrOff: "Texterkennung ist aus: Bilder und Scans werden nicht durchsucht"
            case .searchFailed(let reason): "Suche fehlgeschlagen: \(reason)"
            case .indexFailed(let reason): "Indexieren fehlgeschlagen: \(reason)"
            case .ignoredDrops(let n): (n == 1 ? "1 Datei" : "\(n) Dateien") + " ignoriert (nur Ordner und PDFs)"
            case .alreadyContained(let name, let container): "„\(name)“ ist bereits enthalten in „\(container)“"
            case .missingSources(let names): "Nicht gefunden, übersprungen: " + names.joined(separator: ", ")
            }
        }
    }
    private(set) var noticeKind: Notice?

    private var sourceList = SourceList()
    /// Index of every folder source, by standardized path.
    @ObservationIgnored private var indexes: [String: any FolderIndexing] = [:]
    /// One search per single-PDF source (its page cache is per file), by path.
    @ObservationIgnored private var singleSearches: [String: SingleDocumentSearch] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: any AppEnvironment
    /// Fixed delay for tests; `nil` follows `settings.debounceMs`.
    @ObservationIgnored private let debounce: Duration?
    @ObservationIgnored private let openIndex: @Sendable (URL) throws -> any FolderIndexing
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Identifies the current search; early results of an older one are dropped.
    @ObservationIgnored private var searchToken = 0
    /// Test hook: every list of hits shown.
    @ObservationIgnored var onHitsPublished: (([DocumentHit]) -> Void)?
    /// Refreshes the browse list while indexing finds files, at most once per second.
    @ObservationIgnored private var browseRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastBrowse = ContinuousClock.now
    /// A browse is running; progress during it asks for one more refresh afterwards.
    @ObservationIgnored private var browseRunning = false
    @ObservationIgnored private var browseRefreshWanted = false
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Indexing queue: folders are indexed one after another (spec 1.1 §4 „Index“).
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var queueRunning = false
    @ObservationIgnored private var pending: [String] = []
    /// Folder being indexed right now and the detached work doing it (cancelled when it is removed).
    @ObservationIgnored private var currentFolder: String?
    @ObservationIgnored private var currentWork: Task<Result<IndexReport, Error>, Never>?
    /// Outcome of each folder's last finished run.
    @ObservationIgnored private var reports: [String: IndexReport] = [:]
    /// Outcome of each folder's last text recognition (spec 1.2 §3, §8).
    @ObservationIgnored private var ocrReports: [String: OCRReport] = [:]
    /// Folders waiting for phase 2 (text recognition), after every phase 1.
    @ObservationIgnored private var recognitionPending: [String] = []
    @ObservationIgnored private var currentRecognition: Task<Result<OCRReport, Error>, Never>?
    /// Recognized pages of single-file sources, by path and page (kept for the session).
    @ObservationIgnored private var fileOCR: [String: [Int: OCRPageText]] = [:]
    /// The file version each `fileOCR` entry was recognized from.
    @ObservationIgnored private var fileOCRStamps: [String: FileStamp] = [:]
    private enum Phase { case text, ocr }
    @ObservationIgnored private var currentPhase = Phase.text
    /// „Texterkennung anhalten“ until a new source, „neu ausführen“ or the next start.
    public private(set) var isRecognitionStopped = false
    private var recognitionStopped: Bool {
        get { isRecognitionStopped }
        set { isRecognitionStopped = newValue }
    }
    /// OCR settings (spec 1.2 §7).
    public let ocrPreferences: OCRPreferences
    @ObservationIgnored private var unreachable: Set<String> = []
    /// Folders whose indexing failed or whose index is being rebuilt, with their hint; the hint stays
    /// until that folder succeeds or is removed (another folder's success does not hide it).
    @ObservationIgnored private var indexProblems: [String: Notice] = [:]
    /// Folders whose damaged index was rebuilt by one extra run; a second damage report in a row is
    /// shown as an indexing failure instead of looping.
    @ObservationIgnored private var restartedAfterDamage: Set<String> = []
    /// Bumped by every replacing open and by „Alle entfernen“; work that resumes after an `await` with
    /// an older value was overtaken and stops there.
    @ObservationIgnored private var generation = 0
    /// Bumped by every replacing open request (before the index is opened off the main thread).
    @ObservationIgnored private var openRequest = 0
    /// Identifies the current folder run; progress of older runs is ignored.
    @ObservationIgnored private var indexRun = 0
    @ObservationIgnored private var restoredSources = false
    /// Saved sources that were missing at launch: still remembered (an unplugged disk comes back next
    /// time) until „Alle entfernen“.
    @ObservationIgnored private var rememberedMissing: [String] = []
    @ObservationIgnored private var lastSort: SortMode
    @ObservationIgnored private var lastPartialWords: Bool
    @ObservationIgnored private var lastOCR = OCRSettings.default
    @ObservationIgnored private var rerunTask: Task<Void, Never>?
    /// Indexes whose damage rebuild at open was already announced (`wasRebuilt` stays true).
    @ObservationIgnored private var announcedRebuilds: Set<ObjectIdentifier> = []

    private nonisolated static let log = Logger(subsystem: "local.pdfsucher", category: "app")

    public init(settings: GridSettings,
                defaults: UserDefaults = .standard,
                environment: any AppEnvironment,
                debounce: Duration? = nil,
                openIndex: @escaping @Sendable (URL) throws -> any FolderIndexing = { try FolderIndex.shared(root: $0) }) {
        self.settings = settings
        self.keyboard = KeyboardSettings(defaults: defaults)
        self.ocrPreferences = OCRPreferences(defaults: defaults)
        self.previewZoom = PreviewZoom(defaults: defaults)
        self.searchHistory = SearchHistory(defaults: defaults)
        self.defaults = defaults
        self.environment = environment
        self.debounce = debounce
        self.openIndex = openIndex
        lastSort = settings.sort
        lastPartialWords = settings.partialWords
        lastOCR = OCRSettings(recognizeText: ocrPreferences.recognizeText, includeImages: ocrPreferences.includeImages)
        observeSettings()
    }

    // MARK: Sources

    /// ⌘O: folders and PDFs, several at once; they are added to the loaded sources.
    public func openSources() {
        let urls = environment.chooseSources()
        guard !urls.isEmpty else { return }
        addSources(urls)
    }

    /// Opened or dropped items: folders, PDFs and images are added, everything else is ignored with a hint.
    /// With sources loaded, asks first whether they are added or replace the loaded ones (1.2.1 §1).
    public func addSources(_ urls: [URL]) {
        let previous = addTask
        addTask = Task { await previous?.value; await requestAdd(urls) }
    }

    /// 1.2.1 §1: the „hinzufügen?“ sheet while it is shown.
    public private(set) var addPrompt: AddPrompt?
    @ObservationIgnored private var pendingAddURLs: [URL] = []
    @ObservationIgnored private var addTask: Task<Void, Never>?

    /// Drop or ⌘O: adds at once without loaded sources or when nothing new would come in (the hints show);
    /// otherwise asks, or follows „Beim Hinzufügen von Quellen“.
    func requestAdd(_ dropped: [URL]) async {
        // A drop while the prompt is open joins it (review I1); the sheet stays the same.
        let openPrompt = addPrompt?.id
        let urls = openPrompt == nil ? dropped : pendingAddURLs + dropped
        guard sourceList.items.count + rememberedMissing.count > 0 else { await add(urls); return }
        let includeImages = ocrPreferences.includeImages
        let (candidates, _) = await Task.detached(priority: .userInitiated) {
            SourceClassifier.classify(urls, includeImages: includeImages)
        }.value
        var trial = sourceList
        let newItems = candidates.filter { !trial.add([$0]).added.isEmpty }
        // Counted after the classification: „Alle entfernen“ may have run meanwhile (review M1).
        let loaded = sourceList.items.count + rememberedMissing.count
        guard loaded > 0, !newItems.isEmpty else { addPrompt = nil; pendingAddURLs = []; await add(urls); return }
        switch settings.addSourcesPolicy {
        case .add: await add(urls)
        case .replace: await replaceSources(with: urls)
        case .ask:
            pendingAddURLs = urls
            addPrompt = AddPrompt(newItems: newItems.map(\.url.lastPathComponent), existing: loaded, id: openPrompt ?? UUID())
        }
    }

    /// The sheet's answer; „Nicht mehr fragen“ remembers „Zusätzlich“ or „Ersetzen“ (never „Abbrechen“).
    public func answerAddPrompt(_ choice: AddChoice, remember: Bool) {
        guard addPrompt != nil else { return }
        let urls = pendingAddURLs
        addPrompt = nil
        pendingAddURLs = []
        if remember, choice != .cancel { settings.addSourcesPolicy = choice == .add ? .add : .replace }
        let previous = addTask
        switch choice {
        case .add: addTask = Task { await previous?.value; await add(urls) }
        case .replace: addTask = Task { await previous?.value; await replaceSources(with: urls) }
        case .cancel: break
        }
    }

    /// „Ersetzen“: the loaded and remembered sources leave the search (their index files stay), their
    /// indexing and recognition stop, ticks on their pages go; the query stays and runs again.
    /// When none of the new items can be added (an index that cannot be opened), the old sources, the
    /// remembered ones and the ticks come back (review I2; like ⌘O of one folder in 1.0).
    func replaceSources(with urls: [URL]) async {
        let previous = sourceList.items.map(\.url)
        let previousMissing = rememberedMissing
        let previousSelection = selection
        removeAllSources()
        await add(urls)
        guard !sourceList.items.isEmpty else {
            await add(previous)
            rememberedMissing = previousMissing
            persistSources()
            selection = previousSelection
            return
        }
        let ticked = Set(selection.ordered(documentOrder: []).map(\.url))
        let outside = Set(ticked.filter(isOutsideSources))           // once per document (review M8)
        selection.remove(Set(selection.ordered(documentOrder: []).filter { outside.contains($0.url) }))
    }

    /// `url` (a file) lies in no loaded source.
    private func isOutsideSources(_ url: URL) -> Bool {
        let path = SourceList.components(url)
        return !sourceList.items.contains { source in
            let own = SourceList.components(source.url)
            return own == path || (source.isFolder && SourceList.isPrefix(own, of: path))
        }
    }

    /// Adds folders and PDFs (classified off the main thread). A folder's index is opened first; if
    /// that fails the folder is not added (alert). Sources inside a loaded folder are not added (hint),
    /// a folder replaces the loaded sources inside it.
    /// - Returns: folders whose index could not be opened (alert shown; the other items are still added).
    @discardableResult
    public func add(_ urls: [URL]) async -> [URL] {
        let token = generation
        clearTransientNotice()
        let includeImages = ocrPreferences.includeImages
        let (candidates, ignored) = await Task.detached(priority: .userInitiated) {
            SourceClassifier.classify(urls, includeImages: includeImages)
        }.value
        guard token == generation else { return [] }
        if !ignored.isEmpty { noticeKind = .ignoredDrops(ignored.count) }
        var failed: [URL] = []
        for candidate in candidates {
            var trial = sourceList
            let check = trial.add([candidate])
            if let contained = check.alreadyContained.first {
                noticeKind = .alreadyContained(contained.url.lastPathComponent, in: contained.container.lastPathComponent)
                continue
            }
            guard !check.added.isEmpty else { continue }       // already loaded
            if candidate.isFolder {
                let index = await openFolderIndex(candidate.url)
                guard token == generation else { return failed }
                guard let index else { failed.append(candidate.url); continue }
                insert(candidate, index: index)
            } else {
                insert(candidate, index: nil)
            }
        }
        startQueueIfNeeded()
        scheduleSearch(debounced: false)
        return failed
    }

    /// Hints about the last add or launch („ignoriert“, „bereits enthalten“, „nicht gefunden“) end with
    /// the next change of the sources.
    private func clearTransientNotice() {
        switch noticeKind {
        case .ignoredDrops, .alreadyContained, .missingSources:
            // A lasting index problem of a loaded folder shows again.
            noticeKind = folderSources.lazy.compactMap { self.indexProblems[$0.path] }.first
        default: break
        }
    }

    /// Removes one source; indexing of it stops, the queue goes on with the next folder.
    public func removeSource(_ url: URL) {
        let path = LoadedSourceRef(url: url, isFolder: true).url.path
        guard sourceList.remove(url) else { return }
        clearTransientNotice()
        forget(path)
        persistSources()
        updateIndexStatus()
        scheduleSearch(debounced: false)
    }

    /// „Alle entfernen“.
    public func removeAllSources() {
        generation += 1
        openRequest += 1
        cancelQueue()
        resetSources()
        rememberedMissing.removeAll()
        persistSources()
        noticeKind = nil
        updateIndexStatus()
        scheduleSearch(debounced: false)
    }

    /// Replaces all sources with one folder (UI-test launch, tests). Opens its index off the main
    /// thread; a newer open supersedes this one while it waits, and a failure to open the index
    /// keeps the current sources (and their indexing) as they were.
    public func open(folder root: URL) async {
        openRequest += 1
        let request = openRequest
        let opener = openIndex
        let opened = await Task.detached(priority: .userInitiated) { Result { try opener(root) } }.value
        guard request == openRequest else { return }
        let index: any FolderIndexing
        do {
            index = try opened.get()
        } catch {
            reportOpenFailure(root, error)
            return
        }
        generation += 1
        let token = generation
        await stopQueue()
        guard token == generation else { return }   // a newer open came in while we waited
        resetSources()
        noticeKind = nil
        insert(LoadedSourceRef(url: root, isFolder: true), index: index)
        startQueueIfNeeded()
        scheduleSearch(debounced: false)
    }

    /// Replaces all sources with one PDF (searched directly, no index).
    public func open(file url: URL) {
        openRequest += 1
        generation += 1
        cancelQueue()      // handle kept: a later stopQueue still waits for it
        resetSources()
        noticeKind = nil
        insert(LoadedSourceRef(url: url, isFolder: false), index: nil)
        startQueueIfNeeded()                   // its pages without text are recognized (spec 1.2)
        scheduleSearch(debounced: false)
    }

    /// Loads the sources of the last session (missing ones skipped with a hint). Runs once per model:
    /// reopening the window keeps what the user loaded since.
    public func restoreSources() async {
        guard !restoredSources else { return }
        restoredSources = true
        var paths = defaults.stringArray(forKey: Self.sourcesKey)
        if paths == nil, let last = defaults.string(forKey: Self.lastFolderKey), !last.isEmpty { paths = [last] }
        guard let paths, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let token = generation
        let missing = await Task.detached(priority: .userInitiated) {
            urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        }.value
        guard token == generation else { return }
        let failed = await add(urls.filter { !missing.contains($0) })
        guard token == generation else { return }       // „Alle entfernen“ or another open meanwhile
        // Folders whose index cannot be opened now stay remembered like missing ones.
        rememberedMissing = missing.map(\.path) + failed.map(\.standardizedFileURL.path)
        if !missing.isEmpty { noticeKind = .missingSources(missing.map(\.lastPathComponent)) }
        persistSources()
    }

    private func openFolderIndex(_ root: URL) async -> (any FolderIndexing)? {
        let opener = openIndex
        let opened = await Task.detached(priority: .userInitiated) { Result { try opener(root) } }.value
        do {
            return try opened.get()
        } catch {
            reportOpenFailure(root, error)
            return nil
        }
    }

    private func reportOpenFailure(_ root: URL, _ error: Error) {
        Self.log.error("Cannot open index for \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
        alertMessage = "Index für „\(root.lastPathComponent)“ kann nicht geöffnet werden: \(error.localizedDescription)"
    }

    /// Adds a checked source (and drops the loaded sources it replaces).
    private func insert(_ source: LoadedSourceRef, index: (any FolderIndexing)?) {
        let result = sourceList.add([source])
        for replaced in result.replaced { forget(replaced.url.path) }
        guard !result.added.isEmpty else { return }
        let path = source.url.path
        if let index {
            index.configure(currentOCRSettings)
            indexes[path] = index
            restartedAfterDamage.remove(path)
            if index.wasRebuilt, announcedRebuilds.insert(ObjectIdentifier(index)).inserted {
                setIndexProblem(path, .corruptIndex)
            }
            pending.removeAll { $0 == path }
            recognitionStopped = false              // a new source resumes a stopped recognition
            enqueueIndexing(path)
        } else {
            let isImage = ImagePages.isImage(source.url)
            singleSearches[path] = SingleDocumentSearch(source: OverlayTextSource(isImage: isImage, recognized: fileOCR[path] ?? [:],
                                                                                  stamp: fileOCRStamps[path]), isImage: isImage)
            // Pages without text (or the image) are recognized in the background (spec 1.2 §2).
            recognitionStopped = false
            // A single file is small: it goes first and pre-empts a long folder recognition, which resumes
            // afterwards where it stopped (final review I1).
            if let current = currentFolder, currentPhase == .ocr, indexes[current] != nil { preemptRecognition() }
            recognitionPending.removeAll { $0 == path }
            // After the single files already at the front: files dropped together keep their order.
            let slot = recognitionPending.firstIndex { indexes[$0] != nil } ?? recognitionPending.endIndex
            recognitionPending.insert(path, at: slot)
        }
        persistSources()
        updateIndexStatus()
    }

    /// Drops everything kept for a source that is no longer loaded; its indexing stops.
    private func forget(_ path: String) {
        indexes[path] = nil
        singleSearches[path] = nil
        fileOCR[path] = nil
        fileOCRStamps[path] = nil
        reports[path] = nil
        unreachable.remove(path)
        pending.removeAll { $0 == path }
        recognitionPending.removeAll { $0 == path }
        ocrReports[path] = nil
        clearIndexProblem(path)
        if currentFolder == path {
            // Its cancelled run may take a moment to end: from now on it no longer counts.
            currentWork?.cancel()
            currentWork = nil
            currentRecognition?.cancel()
            currentRecognition = nil
            currentFolder = nil
            indexRun += 1
        }
    }

    private func setIndexProblem(_ path: String, _ notice: Notice) {
        indexProblems[path] = notice
        noticeKind = notice
    }

    /// Clears `path`'s problem; the hint shows another folder's remaining problem, if any.
    private func clearIndexProblem(_ path: String) {
        guard indexProblems.removeValue(forKey: path) != nil else { return }
        if let kind = noticeKind, kind == .corruptIndex || Self.isIndexFailure(kind) {
            noticeKind = folderSources.lazy.compactMap { self.indexProblems[$0.path] }.first
        }
    }

    private func resetSources() {
        sourceList.removeAll()
        indexes.removeAll()
        singleSearches.removeAll()
        reports.removeAll()
        unreachable.removeAll()
        pending.removeAll()
        recognitionPending.removeAll()
        ocrReports.removeAll()
        fileOCR.removeAll()
        fileOCRStamps.removeAll()
        restartedAfterDamage.removeAll()
        indexProblems.removeAll()
    }

    private func persistSources() {
        let loaded = sourceList.items.map(\.url.path)
        defaults.set(loaded + rememberedMissing.filter { !loaded.contains($0) }, forKey: Self.sourcesKey)
    }

    // MARK: Index

    /// Settings „Index löschen …“ for one folder source or (nil) all of them: asks first.
    /// A folder that is no longer loaded does nothing (never „all folders“ instead).
    public func requestDeleteIndex(for source: URL?) {
        let folders = folderSources
        let question: String
        if let source {
            let path = LoadedSourceRef(url: source, isFolder: true).url.path
            guard let folder = folders.first(where: { $0.path == path }) else { return }
            question = "Index von „\(folder.lastPathComponent)“ löschen?"
        } else if folders.count == 1 {
            question = "Index von „\(folders[0].lastPathComponent)“ löschen?"
        } else {
            guard !folders.isEmpty else { return }
            question = "Index aller \(folders.count) Ordner löschen?"
        }
        guard environment.confirmDeleteIndex(question: question) else { return }
        Task { await deleteIndex(for: source) }
    }

    public func requestDeleteIndex() { requestDeleteIndex(for: nil) }

    /// Stops the queue and waits for it, empties the chosen indexes, then indexes again.
    public func deleteIndex(for source: URL? = nil) async {
        let targets: [(String, any FolderIndexing)] = folderSources.compactMap { url in
            guard source == nil || LoadedSourceRef(url: source!, isFolder: true).url.path == url.path,
                  let index = indexes[url.path] else { return nil }
            return (url.path, index)
        }
        guard !targets.isEmpty else { return }
        let token = generation
        await stopQueue()
        // The confirmed delete always happens (spec §10: the stored text must go). If the sources were
        // replaced meanwhile, their own runs notice the wipe and start over.
        // DROP, VACUUM and checkpoint can take seconds: off the main thread.
        for (path, index) in targets {
            let deleted = await Task.detached(priority: .userInitiated) { Result { try index.deleteIndex() } }.value
            do {
                try deleted.get()
            } catch {
                Self.log.error("Deleting the index failed: \(String(describing: error), privacy: .public)")
                alertMessage = "Index konnte nicht gelöscht werden: \(error.localizedDescription)"
            }
            reports[path] = nil
            ocrReports[path] = nil
        }
        guard token == generation else { return }   // other sources are loaded now: no re-index here
        for (path, _) in targets {
            restartedAfterDamage.remove(path)        // a fresh index may be rebuilt again after damage
            if indexes[path] != nil { enqueueIndexing(path) }
        }
        startQueueIfNeeded()
        scheduleSearch(debounced: false)
    }

    /// 1.0 form: all folder sources.
    public func deleteIndex() async { await deleteIndex(for: nil) }

    /// Cancels the queue and waits for it (each queue first waits for its predecessor, so this also
    /// covers queues cancelled earlier). Folders not finished are queued again by the next start.
    private func stopQueue() async {
        guard let task = indexTask else { return }
        cancelQueue()
        await task.value
    }

    /// Cancels the queue without waiting; the handle is kept so a later `stopQueue` waits for it.
    /// Folders whose run did not finish go back to the front of `pending`.
    private func cancelQueue() {
        indexTask?.cancel()
        if let current = currentFolder, isLoaded(current) {
            // An unfinished run goes back to the front of its queue.
            if currentPhase == .ocr {
                if !recognitionPending.contains(current) { recognitionPending.insert(current, at: 0) }
            } else if !pending.contains(current) {
                pending.insert(current, at: 0)
            }
        }
        currentFolder = nil
        queueRunning = false
        indexRun += 1
    }

    /// Phase 1 for `path` (new folder, re-index): a running text recognition makes way (spec 1.2: new files
    /// must not wait behind a long recognition; finished pages are kept, the folder is recognized again later).
    private func enqueueIndexing(_ path: String) {
        if !pending.contains(path) { pending.append(path) }
        preemptRecognition()
    }

    /// Pending recognitions in queue order (tests).
    var recognitionQueueForTesting: [String] { recognitionPending }

    private func preemptRecognition() {
        guard currentPhase == .ocr, let current = currentFolder else { return }
        if !recognitionPending.contains(current) { recognitionPending.insert(current, at: 0) }
        currentRecognition?.cancel()
    }

    private var currentOCRSettings: OCRSettings {
        OCRSettings(recognizeText: ocrPreferences.recognizeText, includeImages: ocrPreferences.includeImages)
    }

    /// Spec 1.2 §7: OCR off stops phase 2 at once (finished pages stay), on resumes it; images on/off lists
    /// the folders again.
    private func ocrSettingsChanged() {
        let now = currentOCRSettings
        guard now != lastOCR else { return }
        let imagesChanged = now.includeImages != lastOCR.includeImages
        lastOCR = now
        for (_, index) in indexes { index.configure(now) }
        if imagesChanged {
            for url in folderSources { enqueueIndexing(url.path) }
        }
        if !now.recognizeText { preemptRecognition() } else { recognitionStopped = false }   // on again: resume after ✕
        startQueueIfNeeded()
        updateIndexStatus()
    }

    /// Settings „Texterkennung für diese Quelle neu ausführen“: every recognized page of the folder waits again.
    public func rerunRecognition(for source: URL) {
        let path = LoadedSourceRef(url: source, isFolder: true).url.path
        guard let index = indexes[path] else { return }
        let previous = rerunTask
        rerunTask = Task {
            await previous?.value
            let reset = await Task.detached(priority: .userInitiated) { Result { try index.resetOCR() } }.value
            if case .failure(let error) = reset {
                alertMessage = "Texterkennung kann nicht neu gestartet werden: \(error.localizedDescription)"
                return
            }
            guard indexes[path] != nil else { return }
            recognitionStopped = false
            if currentFolder == path, currentPhase == .ocr {
                // The running recognition fetched its pages before the reset: start it again.
                preemptRecognition()
            } else {
                recognitionPending.removeAll { $0 == path }
                recognitionPending.insert(path, at: 0)
            }
            startQueueIfNeeded()
        }
    }

    /// Recognized pages and images of one folder source (nil: not a loaded folder or unreadable).
    public func ocrCounts(for source: URL) async -> (pages: Int, images: Int)? {
        let path = LoadedSourceRef(url: source, isFolder: true).url.path
        guard let index = indexes[path] else { return nil }
        return await Task.detached(priority: .userInitiated) { try? index.ocrCounts() }.value
    }

    /// Stored text and word boxes of an OCR page (spec 1.2 §5), nil for a page with a text layer.
    public func ocrText(for page: PageRef) async -> OCRPageText? {
        let path = page.url.standardizedFileURL.path
        if let recognized = fileOCR[path] {
            // A file changed since its recognition shows no old word boxes until it is recognized again.
            let stamp = fileOCRStamps[path], url = page.url
            let current = await Task.detached(priority: .userInitiated) { FileStamp.of(url) }.value
            guard current == stamp else { return nil }
            return OCRHighlights.usable(recognized[page.pageIndex])
        }
        // A folder source: the stored page, by its path inside the folder.
        guard let folder = folderSources.first(where: { path.hasPrefix($0.path + "/") }),
              let index = indexes[folder.path] else { return nil }
        let relative = String(path.dropFirst(folder.path.count + 1))
        return await Task.detached(priority: .userInitiated) {
            OCRHighlights.usable((try? index.ocrPage(relativePath: relative, pageIndex: page.pageIndex)) ?? nil)
        }.value
    }

    /// „Fortsetzen“ after ✕.
    public func resumeRecognition() {
        recognitionStopped = false
        startQueueIfNeeded()
        updateIndexStatus()
    }

    /// Status ✕ „Texterkennung anhalten“: stops phase 2 until a new source, „neu ausführen“ or the next start.
    public func stopRecognition() {
        recognitionStopped = true
        preemptRecognition()
        updateIndexStatus()
    }

    private var hasQueuedWork: Bool {
        pending.contains { indexes[$0] != nil } || (canRecognize && recognitionPending.contains(where: isLoaded))
    }

    private var canRecognize: Bool { ocrPreferences.recognizeText && !recognitionStopped }

    private func startQueueIfNeeded() {
        guard !queueRunning, hasQueuedWork else { return }
        queueRunning = true
        let previous = indexTask
        previous?.cancel()
        indexTask = Task { [weak self] in
            await previous?.value
            // Phase 1 of every folder first, then phase 2 (spec 1.2 §3): a new folder is searchable at once.
            while !Task.isCancelled, let self {
                if let path = self.nextPending() {
                    await self.indexFolder(path)
                } else if let path = self.nextRecognition() {
                    if self.indexes[path] != nil { await self.recognizeFolder(path) } else { await self.recognizeFile(path) }
                } else {
                    break
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.queueRunning = false
            self.updateIndexStatus()
        }
        updateIndexStatus()
    }

    private func nextPending() -> String? {
        while let path = pending.first {
            pending.removeFirst()
            if indexes[path] != nil { return path }
        }
        return nil
    }

    private func nextRecognition() -> String? {
        guard canRecognize else { return nil }
        while let path = recognitionPending.first {
            recognitionPending.removeFirst()
            if isLoaded(path) { return path }
        }
        return nil
    }

    /// A loaded folder (with its index) or single file.
    private func isLoaded(_ path: String) -> Bool { indexes[path] != nil || singleSearches[path] != nil }

    /// One folder's run: progress into `indexStatus`, then its result.
    private func indexFolder(_ path: String) async {
        guard let index = indexes[path] else { return }
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .text
        setBuilding(path, done: 0, total: 0)
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .utility) { () -> Result<IndexReport, Error> in
            defer { continuation.finish() }
            do { return .success(try await index.update { continuation.yield($0) }) } catch { return .failure(error) }
        }
        currentWork = work
        await withTaskCancellationHandler {
            for await progress in stream where !Task.isCancelled {
                guard self.indexRun == run, self.currentFolder == path else { continue }
                self.setBuilding(path, done: progress.done, total: progress.total)
                self.refreshBrowseSoon()
            }
        } onCancel: {
            work.cancel()
        }
        let result = await work.value
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentWork = nil
        guard indexes[path] != nil else { return }          // removed while it ran
        finishIndexing(result, path: path)
    }

    /// One folder's text recognition (phase 2, spec 1.2 §3), cancellable without losing finished pages.
    private func recognizeFolder(_ path: String) async {
        guard let index = indexes[path] else { return }
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .ocr
        setRecognizing(path, done: 0, total: 0)
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .utility) { () -> Result<OCRReport, Error> in
            defer { continuation.finish() }
            do { return .success(try await index.recognize { continuation.yield($0) }) } catch { return .failure(error) }
        }
        currentRecognition = work
        await withTaskCancellationHandler {
            for await progress in stream where !Task.isCancelled {
                guard self.indexRun == run, self.currentFolder == path else { continue }
                self.setRecognizing(path, done: progress.done, total: progress.total)
            }
        } onCancel: {
            work.cancel()
        }
        let result = await work.value
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentRecognition = nil
        currentPhase = .text
        guard indexes[path] != nil else { return }
        switch result {
        case .success(let report):
            ocrReports[path] = report
            recognitionPending.removeAll { $0 == path }
            scheduleRefreshAfterRecognition()
        case .failure(let error) where error is CancellationError:
            break                                    // pre-empted or stopped: queued again already
        case .failure(let error):
            if case IndexStoreError.corruptIndexRebuilt = error, !restartedAfterDamage.contains(path) {
                // The recognition met a damaged (wiped) index: rebuild it, like after phase 1.
                restartedAfterDamage.insert(path)
                reports[path] = nil
                ocrReports[path] = nil
                setIndexProblem(path, .corruptIndex)
                enqueueIndexing(path)
            } else {
                Self.log.error("Recognition in \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                setIndexProblem(path, .indexFailed(error.localizedDescription))
            }
        }
    }

    /// Text recognition of a single-file source (spec 1.2 §2): its pages without text, one after another;
    /// each recognized page is searchable at once. Cancellable like a folder's recognition.
    private func recognizeFile(_ path: String) async {
        guard let source = sourceList.items.first(where: { $0.url.path == path }), !source.isFolder else { return }
        let url = source.url
        let isImage = ImagePages.isImage(url)
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .ocr
        indexStatus = .recognizing(folder: 1, folders: 1, done: 0, total: 0)
        let known = fileOCRStamps[path]
        let previous = fileOCR[path] ?? [:]
        enum Event: Sendable { case stamp(FileStamp?), total(Int), page(Int, OCRPageText), unreadable }
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let work = Task.detached(priority: .utility) { () -> Result<OCRReport, Error> in
            defer { continuation.finish() }
            do {
                // A changed file is recognized again from scratch (spec 1.2 §3).
                let stamp = FileStamp.of(url)
                continuation.yield(.stamp(stamp))
                let done = stamp == known ? previous : [:]
                let pages = try SingleFileOCR.pagesToRecognize(url, isImage: isImage).filter { done[$0] == nil }
                continuation.yield(.total(pages.count))
                for page in pages {
                    try Task.checkCancellation()
                    do {
                        continuation.yield(.page(page, try await SingleFileOCR.recognizeOnThread(url, pageIndex: page, isImage: isImage)))
                    } catch OCRSourceError.unreadable where isImage {
                        continuation.yield(.unreadable)
                        return .success(OCRReport())
                    } catch OCRSourceError.unreadable {
                        continue                       // one page of a PDF that cannot be rendered: the others go on
                    }
                }
                return .success(OCRReport(recognized: pages.count))
            } catch is TextSourceError {
                continuation.yield(.unreadable)
                return .success(OCRReport())
            } catch {
                return .failure(error)
            }
        }
        currentRecognition = work
        var total = 0, count = 0
        await withTaskCancellationHandler {
            for await event in stream where !Task.isCancelled {
                guard self.indexRun == run, self.currentFolder == path, self.singleSearches[path] != nil else { continue }
                switch event {
                case .stamp(let stamp):
                    if stamp != self.fileOCRStamps[path] { self.fileOCR[path] = [:] }
                    self.fileOCRStamps[path] = stamp
                case .total(let n):
                    total = n
                case .page(let page, let text):
                    count += 1
                    // Kept at once (a cancelled run loses nothing finished) and searchable at once.
                    self.fileOCR[path, default: [:]][page] = text
                    self.singleSearches[path] = SingleDocumentSearch(source: OverlayTextSource(
                        isImage: isImage, recognized: self.fileOCR[path] ?? [:], stamp: self.fileOCRStamps[path]), isImage: isImage)
                case .unreadable:
                    break                          // the search reports „Bild kann nicht gelesen werden“
                }
                self.indexStatus = .recognizing(folder: 1, folders: 1, done: count, total: total)
            }
        } onCancel: {
            work.cancel()
        }
        let result = await work.value
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentRecognition = nil
        currentPhase = .text
        guard singleSearches[path] != nil else { return }
        switch result {
        case .success:
            recognitionPending.removeAll { $0 == path }
            scheduleRefreshAfterRecognition()
        case .failure(let error) where error is CancellationError:
            break
        case .failure(let error):
            // Vision failed or the file is away: tried again with the next recognition run.
            Self.log.error("Recognition of \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            recognitionPending.removeAll { $0 == path }
        }
    }

    /// Recognized pages become hits: search again (or refresh the browse list quietly).
    private func scheduleRefreshAfterRecognition() {
        if QueryParser.parse(queryText, partialWords: settings.partialWords).isEmpty {
            if isBrowsing { scheduleSearch(debounced: false, background: true) }
        } else {
            scheduleSearch(debounced: false)
        }
    }

    private func setBuilding(_ path: String, done: Int, total: Int) {
        let folders = folderSources.map(\.path)
        let position = (folders.firstIndex(of: path) ?? 0) + 1
        indexStatus = .building(folder: position, folders: max(folders.count, 1), done: done, total: total)
    }

    private func setRecognizing(_ path: String, done: Int, total: Int) {
        let folders = folderSources.map(\.path)
        let position = (folders.firstIndex(of: path) ?? 0) + 1
        indexStatus = .recognizing(folder: position, folders: max(folders.count, 1), done: done, total: total)
    }

    private func finishIndexing(_ result: Result<IndexReport, Error>, path: String) {
        switch result {
        case .success(let report):
            restartedAfterDamage.remove(path)
            unreachable.remove(path)
            reports[path] = report
            clearIndexProblem(path)
            if !recognitionPending.contains(path) { recognitionPending.append(path) }
            scheduleSearch(debounced: false)
        case .failure(let error) where error is CancellationError:
            break
        case .failure(let error):
            let root = URL(fileURLWithPath: path, isDirectory: true)
            if !Self.isReachableDirectory(root) {
                unreachable.insert(path)
            } else if case IndexStoreError.corruptIndexRebuilt = error, !restartedAfterDamage.contains(path) {
                // The indexer wiped the damaged index; rebuild it now, so the notice is true.
                restartedAfterDamage.insert(path)
                setIndexProblem(path, .corruptIndex)
                pending.insert(path, at: 0)
            } else {
                Self.log.error("Indexing \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                reports[path] = nil
                setIndexProblem(path, .indexFailed(error.localizedDescription))
            }
        }
    }

    /// Status when no folder is being indexed: unreachable if any folder is, otherwise the problems of
    /// all folders (paths prefixed with the folder name when there are several).
    private func updateIndexStatus() {
        let folders = folderSources.map(\.path)
        if folders.isEmpty { indexStatus = .none; return }
        if queueRunning {
            // The folder being worked on (keeping its progress), or the next one while a run ends.
            if let current = currentFolder {
                switch (currentPhase, indexStatus) {
                case (.text, .building(_, _, let done, let total)): setBuilding(current, done: done, total: total)
                case (.ocr, .recognizing(_, _, let done, let total)): setRecognizing(current, done: done, total: total)
                case (.text, _): setBuilding(current, done: 0, total: 0)
                case (.ocr, _): setRecognizing(current, done: 0, total: 0)
                }
                return
            } else if let next = pending.first(where: { indexes[$0] != nil }) {
                setBuilding(next, done: 0, total: 0)
                return
            } else if canRecognize, let next = recognitionPending.first(where: isLoaded) {
                setRecognizing(next, done: 0, total: 0)
                return
            }
        }
        if folders.contains(where: unreachable.contains) { indexStatus = .unreachable; return }
        let several = folders.count > 1
        var failed: [String] = [], noText: [String] = []
        var anyReport = false
        for path in folders {
            guard let report = reports[path] else { continue }
            anyReport = true
            let prefix = several ? (path as NSString).lastPathComponent + "/" : ""
            let ocr = ocrReports[path] ?? OCRReport()
            // With recognition on, phase 1's „ohne Text“ (scans waiting for OCR) does not count: only what
            // recognition found no text in (review of 1.2 Task 1).
            let withoutText = ocrPreferences.recognizeText ? ocr.noText : report.noText
            failed += Self.unique(report.failed + ocr.failed).map { prefix + $0 }
            noText += Self.unique(withoutText).map { prefix + $0 }
        }
        if !anyReport { indexStatus = .none; return }
        indexStatus = failed.isEmpty && noText.isEmpty ? .upToDate : .problems(failed: failed, noText: noText)
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func isIndexFailure(_ notice: Notice) -> Bool {
        if case .indexFailed = notice { return true }
        return false
    }

    private static func isSearchFailure(_ notice: Notice) -> Bool {
        if case .searchFailed = notice { return true }
        return false
    }

    private static func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Browse (spec 1.1 §12)

    /// While browsing, shows files found by the indexer: at most once per second.
    private func refreshBrowseSoon() {
        guard isBrowsing else { return }
        if browseRunning { browseRefreshWanted = true; return }
        guard browseRefreshTask == nil else { return }
        let due = lastBrowse + .seconds(1)
        browseRefreshTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.browseRefreshTask = nil
            if self.browseRunning { self.browseRefreshWanted = true; return }
            if self.isBrowsing, QueryParser.parse(self.queryText, partialWords: self.settings.partialWords).isEmpty {
                self.scheduleSearch(debounced: false, background: true)
            }
        }
    }

    /// Every file of every target, off the main actor. Unreadable single PDFs are listed as such;
    /// a folder whose list cannot be read contributes nothing.
    /// The list comes back sorted by `mode` (sorting 10,000 entries takes long enough to stutter on the
    /// main actor, final review of 1.1), each entry with its source path.
    private nonisolated static func browse(_ targets: [SearchTarget], sortedBy mode: SortMode) async -> [(target: String, hit: DocumentHit)] {
        let found = await browse(targets)
        return sortedPairs(found, by: mode)
    }

    /// All hits of all targets, sorted together, each with its target.
    private nonisolated static func sortedPairs(_ found: [(target: String, hits: [DocumentHit])], by mode: SortMode) -> [(target: String, hit: DocumentHit)] {
        var targetOf: [String: String] = [:]
        for (target, hits) in found { for hit in hits { targetOf[hit.id] = target } }
        return sortHits(found.flatMap(\.hits), by: mode).map { (targetOf[$0.id] ?? "", $0) }
    }

    private nonisolated static func browse(_ targets: [SearchTarget]) async -> [(target: String, hits: [DocumentHit])] {
        let work = Task.detached(priority: .userInitiated) { () -> [(target: String, hits: [DocumentHit])] in
            await withTaskGroup(of: (String, [DocumentHit]).self) { group in
                for target in targets {
                    group.addTask {
                        switch target {
                        case .folder(let path, let index):
                            do { return (path, try index.browse()) } catch {
                                log.error("Browsing \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                                return (path, [])
                            }
                        case .file(let url, _):
                            return (url.path, [singleEntry(url)])
                        }
                    }
                }
                var all: [(target: String, hits: [DocumentHit])] = []
                for await (path, found) in group { all.append((path, found)) }
                return all
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private nonisolated static func singleEntry(_ url: URL) -> DocumentHit {
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if ImagePages.isImage(url) {
            let readable = ImagePages.isReadable(url)
            return DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
                               pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: url,
                               pageCount: readable ? 1 : 0, isUnreadable: !readable, isImage: true)
        }
        let document = PDFDocument(url: url)
        let readable = document.map { !$0.isLocked } ?? false
        return DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
                           pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: url,
                           pageCount: readable ? document?.pageCount ?? 0 : 0, isUnreadable: !readable)
    }

    private func applyBrowse(_ sorted: [(target: String, hit: DocumentHit)], mode: SortMode, for parsed: ParsedQuery) {
        let start = ContinuousClock.now
        defer { lastMainApply = ContinuousClock.now - start }
        let loaded = Set(sourceList.items.map(\.url.path))
        var entries = sorted.filter { loaded.contains($0.target) }.map(\.hit)
        let current = ViewerText.browseSortMode(settings.sort)
        if current != mode { entries = sortHits(entries, by: current) }     // the sort changed meanwhile
        isBrowsing = true
        show(entries, for: parsed,
             summary: ViewerText.browseSummary(files: entries.count, pages: entries.reduce(0) { $0 + $1.pageCount }))
    }

    /// Test hook: main-actor time of the last browse list applied.
    @ObservationIgnored var lastMainApply: Duration = .zero

    // MARK: Search

    /// Delay after the last keystroke before searching.
    var typingDelay: Duration { debounce ?? .milliseconds(settings.debounceMs) }

    /// What one search runs over: every folder index and every single PDF.
    private enum SearchTarget: Sendable {
        case folder(String, any FolderIndexing)
        case file(URL, SingleDocumentSearch)
    }

    private struct SearchOutcome: Sendable {
        /// Hits per target path.
        var hits: [(target: String, hits: [DocumentHit])] = []
        /// All hits sorted by `sort` off the main actor, each with its target.
        var sorted: [(target: String, hit: DocumentHit)] = []
        var sort: SortMode = .matchCount
        var errors: [(target: String, error: Error)] = []
    }

    /// - Parameter background: a browse refresh while indexing: no „Suche läuft…“.
    private func scheduleSearch(debounced: Bool, background: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        browseRunning = false
        let parsed = QueryParser.parse(queryText, partialWords: settings.partialWords)
        let targets: [SearchTarget] = sourceList.items.compactMap { source in
            let path = source.url.path
            if source.isFolder { return indexes[path].map { .folder(path, $0) } }
            return singleSearches[path].map { .file(source.url, $0) }
        }
        if targets.isEmpty {
            isBrowsing = false
            show([], for: parsed, summary: "")
            return
        }
        let sort = settings.sort
        let delay = debounced ? typingDelay : .zero
        if parsed.isEmpty {
            browseRefreshTask?.cancel()
            browseRefreshTask = nil
            searchTask = Task { [weak self] in
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard !Task.isCancelled, let self else { return }
                // Throttle by start time; progress while this runs asks for one refresh afterwards.
                self.lastBrowse = .now
                self.browseRunning = true
                self.browseRefreshWanted = false
                if !background { self.isSearching = true }
                let mode = ViewerText.browseSortMode(sort)
                let found = await Self.browse(targets, sortedBy: mode)
                guard !Task.isCancelled else { return }
                self.browseRunning = false
                self.isSearching = false
                self.applyBrowse(found, mode: mode, for: parsed)
                if self.browseRefreshWanted {
                    self.browseRefreshWanted = false
                    self.refreshBrowseSoon()
                }
            }
            return
        }
        searchToken += 1
        let token = searchToken
        searchTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.isSearching = true
            // Spec 1.1 §5: a search still running after `earlyDelay` shows the documents its sources have
            // already checked; the final list replaces them once.
            let collector = EarlyResults()
            let early = Task { [weak self] in
                try? await Task.sleep(for: Self.earlyDelay)
                while !Task.isCancelled, !collector.isDone {
                    if let found = collector.take() {
                        self?.applyEarly(found, for: parsed, token: token)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            let outcome = await withTaskCancellationHandler {
                await Self.run(parsed, sort: sort, over: targets, early: collector)
            } onCancel: { early.cancel() }
            collector.finish()
            early.cancel()
            guard !Task.isCancelled else { return }
            self?.isSearching = false
            self?.apply(outcome, for: parsed)
        }
    }

    /// How long a search may run before its first checked documents are shown (with the 50 ms typing
    /// delay well within the 200 ms target).
    static let earlyDelay: Duration = .milliseconds(100)

    /// Early documents of the running search (sorted like the final list; focus kept).
    private func applyEarly(_ found: [(target: String, hits: [DocumentHit])], for parsed: ParsedQuery, token: Int) {
        guard token == searchToken, isSearching else { return }
        let loaded = Set(sourceList.items.map(\.url.path))
        let early = found.filter { loaded.contains($0.target) }.flatMap(\.hits)
        guard !early.isEmpty else { return }
        isBrowsing = false
        show(sortHits(early, by: settings.sort), for: parsed, summary: nil, keepFocus: true)
    }

    /// Runs the search over all targets in parallel, off the main actor; cancelling the caller cancels
    /// the work. A failing target does not drop the others' hits.
    private nonisolated static func run(_ q: ParsedQuery, sort: SortMode, over targets: [SearchTarget],
                                        early: EarlyResults? = nil) async -> SearchOutcome {
        let work = Task.detached(priority: .userInitiated) { () -> SearchOutcome in
            await withTaskGroup(of: (String, Result<[DocumentHit], Error>).self) { group in
                for target in targets {
                    group.addTask {
                        switch target {
                        case .folder(let path, let index):
                            var report: (@Sendable ([DocumentHit]) -> Void)?
                            if let early { report = { hits in early.add(path, hits) } }
                            let onPartial = report
                            return (path, Result { try index.search(q, sort: sort, onPartial: onPartial) })
                        case .file(let url, let single):
                            return (url.path, Result { try single.search(url: url, query: q).map { [$0] } ?? [] })
                        }
                    }
                }
                var outcome = SearchOutcome()
                for await (path, result) in group {
                    switch result {
                    case .success(let found): outcome.hits.append((path, found))
                    case .failure(let error): outcome.errors.append((path, error))
                    }
                }
                outcome.sorted = sortedPairs(outcome.hits, by: sort)
                outcome.sort = sort
                return outcome
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private func apply(_ outcome: SearchOutcome, for parsed: ParsedQuery) {
        let errors = outcome.errors.filter { !($0.error is CancellationError) }
        if errors.isEmpty, outcome.errors.contains(where: { $0.error is CancellationError }) { return }
        // Hits of sources removed (or replaced) while the search ran are dropped.
        let loaded = Set(sourceList.items.map(\.url.path))
        var found = outcome.sorted.filter { loaded.contains($0.target) }.map(\.hit)
        if outcome.sort != settings.sort { found = sortHits(found, by: settings.sort) }   // changed meanwhile
        if errors.isEmpty {
            if let kind = noticeKind, [.noText, .unreadable, .unreadableImage, .noTextImage, .noTextPDF, .ocrOff].contains(kind) || Self.isSearchFailure(kind) { noticeKind = nil }
        }
        isBrowsing = false
        show(found, for: parsed, summary: nil)
        for (target, error) in errors where loaded.contains(target) {
            switch error {
            case IndexStoreError.corruptIndexRebuilt:
                setIndexProblem(target, .corruptIndex)
                // A running phase 1 of the folder restarts itself after a wipe; a recognition does not, and
                // a recognition of another folder must not delay the rebuild (review of 1.2 Task 1).
                if indexes[target] != nil, currentFolder != target || currentPhase == .ocr {
                    enqueueIndexing(target)
                    startQueueIfNeeded()
                }
            case SingleDocumentSearchError.noText:
                let isImage = ImagePages.isImage(URL(fileURLWithPath: target))
                if !canRecognize {
                    noticeKind = isImage ? .ocrOff : .noText        // OCR off or halted: 1.0 scan hint for PDFs
                } else if recognitionPending.contains(target) || currentFolder == target {
                    break                          // waiting for (or in) recognition: no hint yet
                } else {
                    noticeKind = isImage ? .noTextImage : .noTextPDF     // recognition ran and found nothing (§8)
                }
            case is TextSourceError:
                noticeKind = ImagePages.isImage(URL(fileURLWithPath: target)) ? .unreadableImage : .unreadable
            default:
                Self.log.error("Search failed: \(String(describing: error), privacy: .public)")
                noticeKind = .searchFailed(error.localizedDescription)
            }
        }
    }

    /// `summary` nil = the usual „Gefunden in …“ text.
    private func show(_ newHits: [DocumentHit], for parsed: ParsedQuery, summary: String?, keepFocus: Bool = false) {
        hits = newHits
        query = parsed
        scheduleHistoryCommit()
        self.summary = summary ?? ViewerText.summary(hits: newHits)
        onHitsPublished?(newHits)
        if !keepFocus, focusedPage != nil, !FocusNavigator.contains(focusedPage, in: newHits, showAllPages: settings.showAllPages) {
            focusedPage = nil
        }
    }

    // MARK: Search history (1.2.2 §1)

    /// Return in the field, an arrow into the grid, a tile, a tick: the current term goes into the history.
    public func noteSearchArrived() {
        guard isQuery(queryText) else { return }
        historyTask?.cancel()
        historyArmed = false
        searchHistory.commit(queryText)
    }

    /// A text that is a real query (not empty, not only operators like „-“; review M3).
    private func isQuery(_ text: String) -> Bool {
        !SearchHistory.clean(text).isEmpty && !QueryParser.parse(text, partialWords: settings.partialWords).isEmpty
    }

    /// A term chosen from the history: searched at once (no typing delay) and moved to the top.
    public func chooseHistoryEntry(_ term: String) {
        queryText = term
        scheduleSearch(debounced: false)
        historyArmed = false
        searchHistory.commit(term)
    }

    /// A shown result with hits for a typed term is remembered after `historyDelay` without typing.
    private func scheduleHistoryCommit() {
        let term = queryText
        guard historyArmed, !query.isEmpty, isQuery(term), !hits.isEmpty, searchHistory.isEnabled else { return }
        historyTask?.cancel()
        let delay = historyDelay
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.queryText == term, !self.hits.isEmpty else { return }
            self.historyArmed = false
            self.searchHistory.commit(term, viaPause: true)
        }
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.sort
            _ = settings.partialWords
            _ = settings.showAllPages
            _ = ocrPreferences.recognizeText
            _ = ocrPreferences.includeImages
        } onChange: { [weak self] in
            // Called synchronously by the (main-actor) setter, before the new value is stored.
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.settingsTask
                self.settingsTask = Task { [weak self] in
                    await previous?.value
                    self?.settingsChanged()
                }
            }
        }
    }

    private func settingsChanged() {
        defer { observeSettings() }
        ocrSettingsChanged()
        // „Alle Seiten“ off: a focused page that is no longer shown moves to the nearest hit page.
        if let focused = focusedPage, !FocusNavigator.contains(focused, in: hits, showAllPages: settings.showAllPages) {
            focusedPage = FocusNavigator.nearestShown(to: focused, hits: hits, showAllPages: settings.showAllPages)
        }
        if settings.partialWords != lastPartialWords {
            lastPartialWords = settings.partialWords
            lastSort = settings.sort
            scheduleSearch(debounced: false)
        } else if settings.sort != lastSort {
            lastSort = settings.sort
            hits = sortHits(hits, by: isBrowsing ? ViewerText.browseSortMode(lastSort) : lastSort)   // same hits, no new query
        }
    }

// MARK: Output

    private var orderedSelection: [PageRef] {
        selection.ordered(documentOrder: hits.map(\.url))
    }

    private var defaultFileName: String {
        DefaultFileName.make(searchTerm: queryText.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
    }

    public func saveSelection() {
        // Not while printing is prepared: the print sheet would attach to the save panel.
        guard !isPreparingPrint, selection.count > 0,
              let url = environment.chooseSaveLocation(defaultName: defaultFileName) else { return }
        let previous = saveTask       // e.g. „Fehlende Seiten entfernen“ still checking files
        saveTask = Task { [weak self] in
            await previous?.value
            guard let refs = self?.orderedSelection, !refs.isEmpty else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Merger().write(refs, to: url) }
            }.value
            if case .failure(let error) = result {
                Self.log.error("Saving \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self?.showAlert(Self.message(forSaveError: error, url: url), for: error)
            }
        }
    }

    /// Builds the print document in the background („Druck wird vorbereitet…“), then shows the macOS
    /// print dialog on the main actor. While preparing, another click starts no second job. Waits for a
    /// running save or „Fehlende Seiten entfernen“ first, so it prints the cleaned selection.
    public func printSelection() {
        guard !isPreparingPrint, selection.count > 0 else { return }
        isPreparingPrint = true
        let previous = saveTask
        let jobTitle = String(defaultFileName.dropLast(".pdf".count))
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.isPreparingPrint = false }
            let refs = self.orderedSelection
            guard !refs.isEmpty else { return }
            let built = await Task.detached(priority: .userInitiated) { Result { try PrintDocument.build(refs) } }.value
            switch built {
            case .success(let print):
                let operation = Printer.printOperation(for: print.document)
                operation.jobTitle = jobTitle
                self.environment.runPrint(operation)
            case .failure(let error):
                Self.log.error("Printing failed: \(String(describing: error), privacy: .public)")
                self.showAlert("Drucken nicht möglich: \(Self.describe(error))", for: error)
            }
        }
    }

    private func showAlert(_ message: String, for error: Error) {
        alertMessage = message
        switch error {
        case OutputError.cannotOpen, OutputError.pageOutOfRange: alertOffersRemovingMissingPages = true
        default: alertOffersRemovingMissingPages = false
        }
    }

    /// Unticks every selected page whose file is gone, unreadable or now too short (checked off the
    /// main thread) and closes the alert; afterwards saving or printing can be tried again.
    public func removeMissingPagesFromSelection() {
        alertMessage = nil
        let refs = selection.ordered(documentOrder: [])
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            let missing = await Task.detached(priority: .userInitiated) { Merger.unavailable(refs) }.value
            self?.selection.remove(missing)
        }
    }

    public func openInPreview(_ r: PageRef) {
        environment.openInPreview(r.url)
    }

    static func message(forSaveError error: Error, url: URL) -> String {
        "Speichern fehlgeschlagen: \(url.lastPathComponent) – \(describe(error))"
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case OutputError.cannotOpen(let url): "„\(url.lastPathComponent)“ kann nicht geöffnet werden"
        case OutputError.pageOutOfRange(let ref): "Seite \(ref.pageIndex + 1) fehlt in „\(ref.url.lastPathComponent)“"
        case OutputError.emptySelection: "Keine Seiten ausgewählt"
        case OutputError.writeFailed(_, let reason): reason
        default: error.localizedDescription
        }
    }

    // MARK: Waiting (tests, UI-test launch)

    /// Waits until no search, settings change, indexing run or save is pending.
    func waitUntilIdle() async {
        while true {
            let s = settingsTask, q = searchTask, i = indexTask, w = saveTask, r = rerunTask, a = addTask
            await a?.value
            await s?.value
            await r?.value
            await q?.value
            await i?.value
            await w?.value
            if s == settingsTask, q == searchTask, i == indexTask, w == saveTask, r == rerunTask, a == addTask { return }
        }
    }

    /// Waits for the current search only (indexing may still be running).
    func waitForSearch() async {
        while let task = searchTask {
            await task.value
            if task == searchTask { return }
        }
    }
}

/// Early documents per source of the running search (written by the search tasks, read by the model).
final class EarlyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [(target: String, hits: [DocumentHit])] = []
    private var done = false

    func add(_ target: String, _ hits: [DocumentHit]) { lock.withLock { found.append((target, hits)) } }
    func finish() { lock.withLock { done = true } }
    var isDone: Bool { lock.withLock { done } }
    /// What has arrived so far (nil = nothing yet).
    func take() -> [(target: String, hits: [DocumentHit])]? { lock.withLock { found.isEmpty ? nil : found } }
}
