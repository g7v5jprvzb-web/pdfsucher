// AppModel.swift — Task 5.1 (wiring of the kits, debounce, state); 1.1 Task 2 (several sources)
import AppKit
import Foundation
import IndexKit
import Observation
import os
import OCRKit
import OfficeKit
import OutputKit
import PDFKit
import SearchKit
import Synchronization
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
            lastTyping = .now                     // defers a font registration start (fonts-start c)
            historyTask?.cancel()                 // a pause only counts once typing stopped (1.2.2 §1)
            historyArmed = true                   // only a typed term arms the pause (not a refresh, review I2)
            scheduleSearch(debounced: true)
        }
    }
    /// The shown documents: `allHits` through the grid filters (spec 1.3 §8a): the folder filter
    /// (Ordnerleiste), further filters (`extraFilters`) and the file types, ANDed.
    public private(set) var hits: [DocumentHit] = []
    /// Every document of the last search or browse, sorted, before the grid filters. Gives ticked pages of
    /// hidden documents their place in the output (`orderedSelection`).
    @ObservationIgnored var allHits: [DocumentHit] = []
    /// How `summary` is made from the shown documents.
    enum SummaryStyle { case empty, search, browse }
    @ObservationIgnored var summaryStyle = SummaryStyle.empty
    /// Documents inside the chosen folders that the file types hide (spec 1.3 §8a: the empty grid and the summary
    /// say so). Files outside the chosen folders are not counted: the folder header says „x von y“.
    public private(set) var hiddenByFilter = 0
    /// Ordnerleiste: folders of the sources (from the document list) and the chosen folders.
    public internal(set) var folderTree: [FolderNode] = []
    public var folderFilter = FolderFilter() {
        didSet {
            if folderFilter != oldValue {
                publishFiltered(keepFocus: false)
                updateWorkPriority()
            }
        }
    }
    public let folderBar: FolderBarSettings
    /// Further filters on the grid, combined with the folder filter and the file types (AND).
    public var extraFilters: [any DocumentFilter] = [] {
        didSet { publishFiltered(keepFocus: false) }
    }
    /// The files of the last browse list (the tree's source).
    @ObservationIgnored var browseFiles: [URL] = []
    /// Watches the folder sources on disk (FSEvents in the app; nil in tests unless a fake is set).
    @ObservationIgnored public var folderWatcher: (any FolderWatching)? {
        didSet {
            folderWatcher?.onChange = { [weak self] roots, urgent, scopes in self?.foldersChangedOnDisk(roots, urgent: urgent, scopes: scopes) }
            updateWatchedFolders()
        }
    }
    /// Sources changed on disk whose run has not succeeded yet.
    @ObservationIgnored var changedOnDisk: Set<String> = []
    /// Sources whose run after a change on disk succeeded: at the next tree, chosen folders below them that
    /// the tree no longer has leave the filter.
    @ObservationIgnored var checkFilterAfterTree: Set<String> = []
    /// A source changed on disk is indexed again at most once per cooldown (a long copy into Downloads must
    /// not index it every 1.5 s and keep the text recognition from running); later reports wait for its end.
    @ObservationIgnored var diskChangeCooldown: Duration = .seconds(10)
    @ObservationIgnored private var lastDiskRun: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var diskChangeDue: Set<String> = []
    @ObservationIgnored private var diskChangeTask: Task<Void, Never>?
    /// A place clicked while it was not loaded: filtered to once it is (after the add prompt).
    @ObservationIgnored var pendingPlaceFilter: URL?
    public private(set) var query = ParsedQuery(terms: [])
    /// A tick or a tile chosen with the mouse or the arrows means the search arrived (1.2.2 §1).
    /// Only a single tick or untick counts; clearing or pruning several at once does not (review M1).
    public var selection = PageSelection() {
        didSet { if abs(selection.count - oldValue.count) == 1 { noteSearchArrived() } }
    }
    /// The tile shown in the large preview. Set by the user (click, arrows, ‹ ›) or, during a search, by the model
    /// itself: the first hit page (1.3.3, `show` and `refillEmptyPreview`).
    public var focusedPage: PageRef? {
        didSet {
            guard !settingFocus else { return }
            // Any page the user sets is their choice, even the one already shown (it was the automatic one).
            focusChosenByUser = focusedPage != nil
            if focusedPage != nil, focusedPage != oldValue { noteSearchArrived() }
        }
    }
    /// The user chose the focused page for the current search term: new results of that term keep it (1.3.3).
    @ObservationIgnored private(set) var focusChosenByUser = false
    /// The shown page is the search's first hit, set by the model (1.3.3): the first ↓ from the search field enters
    /// the grid on it (`KeyRouterApplier`). Not while browsing: there ↓ moves on as before.
    public var focusIsAutomatic: Bool {
        focusedPage != nil && !focusChosenByUser && summaryStyle == .search && !query.isEmpty
    }
    /// A new term waits for its final result to show the first hit (1.3.3; early rows do not, review 2).
    @ObservationIgnored private var firstHitPending = false
    /// The model sets `focusedPage` itself: neither the user's choice nor an arrival for the history.
    @ObservationIgnored private var settingFocus = false

    /// Every write of `focusedPage` inside the model goes through here; a direct write counts as the user's
    /// choice and as an arrival for the search history (review 5).
    private func setFocusByModel(_ page: PageRef?) {
        if page == nil { focusChosenByUser = false }      // nothing shown: nobody's choice (review 3)
        guard focusedPage != page else { return }
        settingFocus = true
        focusedPage = page
        settingFocus = false
    }
    /// Tiles on disk of the window's grid (spec 1.2.4 §3: cleaned after indexing and „Index löschen“);
    /// the app sets it, tests leave it nil.
    public var tileDisk: TileDiskCache?
    /// The folder of the index files (settings „Verwaiste Indexe“); the app sets it, UI tests and tests leave it nil.
    public var indexDirectory: URL?
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
    /// Rises when newly laid-out Word/PowerPoint pages are stored: at most once a second during a layout
    /// run, and at the end of every run (spec 1.3).
    public private(set) var layoutRevision = 0
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
        /// Word/PowerPoint single files (1.3 Teil B Task 5).
        case layoutUnreadable, noTextOffice
        case ignoredDrops(Int), alreadyContained(String, in: String), missingSources([String])
        var text: String {
            switch self {
            case .corruptIndex: Text.corruptIndex
            case .noText: Text.noText
            case .unreadable: Text.unreadable
            case .unreadableImage: Text.unreadableImage
            case .noTextImage: "Im Bild wurde kein Text erkannt"
            case .noTextPDF: "Im PDF wurde kein Text erkannt"
            case .layoutUnreadable: "Word- oder PowerPoint-Datei kann nicht gelesen werden"
            case .noTextOffice: "Im Dokument wurde kein Text gefunden"
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
    @ObservationIgnored var indexes: [String: any FolderIndexing] = [:]   // internal: AppModel+Storage
    /// One search per single-PDF source (its page cache is per file), by path.
    @ObservationIgnored private var singleSearches: [String: SingleDocumentSearch] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: any AppEnvironment
    /// Fixed delay for tests; `nil` follows `settings.debounceMs`.
    @ObservationIgnored private let debounce: Duration?
    @ObservationIgnored private let openIndex: @Sendable (URL) throws -> any FolderIndexing
    /// Lays out Word/PowerPoint single files (in memory, spec 1.3).
    @ObservationIgnored private let officeLayout: any PageLayoutSource
    /// Rendered slides of PowerPoint files (one cache for all sources; tests pass their own).
    @ObservationIgnored let slideCache: SlideCache   // internal: AppModel+Storage
    /// „PowerPoint-Darstellung“ / „Fehlende Schriften“ as the layout sources read it (1.3 Teil B Task 12).
    @ObservationIgnored private let officeRendering: PowerPointDisplaySetting
    @ObservationIgnored private var lastRendering = OfficeRendering.default
    /// The last display switch (stop layout, reset PowerPoint, queue); each waits for the one before.
    @ObservationIgnored private var renderingTask: Task<Void, Never>?
    /// Prepares Office's fonts (`OfficeDisplay.prewarmFonts()`; reading Office's font cache may bring up the macOS
    /// prompt „Daten anderer Apps“) and answers whether that succeeded. Started lazily, once (`officeFonts`), on a GCD
    /// queue: with the first Word/PowerPoint layout, the first Word document or SlideKit deck shown
    /// (`officeDocumentShown`), or at launch after an earlier success (`startOfficeFontsIfRegisteredBefore`); tests
    /// replace it.
    @ObservationIgnored public var prewarmFonts: @Sendable () -> Bool = { OfficeDisplay.prewarmFonts() }
    /// Calls its argument when a registration that missed `prewarmFonts`' answer (deadline passed, e.g. a prompt
    /// answered late) finishes complete later (`OfficeDisplay.whenFontsComplete`); tests replace it.
    @ObservationIgnored public var fontsCompleteLater: @Sendable (@escaping @Sendable () -> Void) -> Void = {
        OfficeDisplay.whenFontsComplete($0)
    }
    /// Starts `prewarmFonts` at most once for this model (the app has one; `FontResolver.prewarm()` itself is
    /// idempotent per process).
    @ObservationIgnored private let officeFonts = OfficeFontPrewarm()
    /// UserDefaults key: Office's font registration once succeeded in this app (set only on success, never on a
    /// timeout); then the next launches start it at once (`startOfficeFontsIfRegisteredBefore`).
    public nonisolated static let fontsRegisteredOnceKey = "office.fontsRegisteredOnce"
    /// How long the search field must be idle before a start asked for by a shown document runs (fonts-start c: the
    /// prompt never pops up mid-typing). Tests shorten it.
    @ObservationIgnored var typingIdleDelay: Duration = .seconds(1)
    /// The last change of `queryText` (typing, a history entry).
    @ObservationIgnored private var lastTyping: ContinuousClock.Instant?
    /// A start waiting for typing to pause.
    @ObservationIgnored private var fontStartWaiter: Task<Void, Never>?
    /// A Word document or a SlideKit deck was shown before the registration succeeded: its tiles/preview may carry
    /// substitute fonts.
    @ObservationIgnored private var wordShownBeforeFonts = false
    /// The registration succeeded in this process (`fontsRegistered`).
    @ObservationIgnored private var fontsAreRegistered = false
    /// Where Quick Look leaves preview folders of crashed runs (tests pass their own).
    @ObservationIgnored var quickLookLeftoverRoot = QuickLookHTML.leftoverRoot
    /// Test hook: awaited by the start maintenance before it touches anything.
    @ObservationIgnored var maintenanceGate: (@Sendable () async -> Void)?
    /// The last slide-cache job (start maintenance, „Folien-Cache leeren“); each waits for the one before. The queue
    /// waits for all of them before any layout step, so no slide is written while the cache is pruned or cleared.
    @ObservationIgnored private var cacheWork: Task<Void, Never>?
    /// Slide-cache jobs not finished yet.
    @ObservationIgnored private var cacheJobs = 0
    @ObservationIgnored private var maintenanceStarted = false
    /// Files whose missing slides or outdated index entry were already acted on, as "slides|…" / "index|…" with path
    /// and file version: at most once per file version and session (tiles report up to once a second).
    @ObservationIgnored private var requestedRelayouts: Set<String> = []
    /// Measurement log (1.3.9): why each folder waits for phase 1, the trigger of sources being added, and the start of
    /// the running queue step.
    @ObservationIgnored private var metricsTriggers: [String: [String]] = [:]
    @ObservationIgnored private var addTrigger = "added"
    @ObservationIgnored private var metricsRunStart = ContinuousClock.now
    /// The measurement log (tests use their own).
    @ObservationIgnored var metrics: IndexMetrics = .shared
    /// 1.4.3: `launch_phase` and the phase named by `main_hang` (tests use their own).
    @ObservationIgnored var hangWatch: MainHangWatch = .shared
    /// 1.4.3: when the running search showed its first early rows; `first_search_done` written.
    @ObservationIgnored private var searchFirstRows: ContinuousClock.Instant?
    @ObservationIgnored private var firstSearchLogged = false
    /// Paths with a check queued or running (`checkOfficeFile`); further reports meanwhile are dropped.
    @ObservationIgnored private var checksQueued: Set<String> = []
    /// The last of those checks; each waits for the one before.
    @ObservationIgnored private var officeCheckTask: Task<Void, Never>?
    /// Folders asked to lay out one more document while their layout runs: queued again when that run ends.
    @ObservationIgnored private var layoutAgain: Set<String> = []
    /// Longest layout of one single file; a longer one counts as unreadable.
    @ObservationIgnored var fileLayoutTimeout: Duration = .seconds(120)
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
    @ObservationIgnored private var currentFolder: String? { didSet { hangWatch.setPhase(metricsPhase) } }
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
    /// Folders waiting for the phase „layout“ (Word/PowerPoint, spec 1.3), after every phase 1 and
    /// before any phase 2; only while „office.include“ is on.
    @ObservationIgnored private var layoutPending: [String] = []
    /// Folders whose trigram index („Wortteil-Index“, 1.3.12) is filled after phase 1, before any folder layout and
    /// recognition (decisions „index-speed-2“).
    @ObservationIgnored private var wordPartsPending: [String] = []
    /// 1.4.0 P3: folders changed on disk per source since its last phase 1, and sources that need a full scan anyway.
    @ObservationIgnored private var diskScopes: [String: Set<String>] = [:]
    @ObservationIgnored private var needsFullScan: Set<String> = []
    @ObservationIgnored private var currentWordParts: Task<Result<Int, Error>, Never>?
    @ObservationIgnored private var currentLayout: Task<Result<LayoutReport, Error>, Never>?
    /// Word/PowerPoint single files by path (laid out in memory, kept for the session; 1.3 Teil B Task 5).
    @ObservationIgnored private var fileLayouts: [String: FileLayoutState] = [:]
    @ObservationIgnored private var currentFileLayout: Task<Result<FileLayoutState, Error>, Never>?
    /// Outcome of each folder's last finished layout run; its problem lists describe the whole index.
    @ObservationIgnored private var layoutReports: [String: LayoutReport] = [:]
    /// Throttles `layoutRevision` during a layout run (at most once a second).
    @ObservationIgnored private var layoutBumpTask: Task<Void, Never>?
    @ObservationIgnored private var lastLayoutBump = ContinuousClock.now - .seconds(1)
    private enum Phase { case text, layout, ocr, wordParts }
    @ObservationIgnored private var currentPhase = Phase.text { didSet { hangWatch.setPhase(metricsPhase) } }
    /// „Texterkennung anhalten“ until a new source, „neu ausführen“ or the next start.
    public private(set) var isRecognitionStopped = false
    private var recognitionStopped: Bool {
        get { isRecognitionStopped }
        set { isRecognitionStopped = newValue }
    }
    /// OCR settings (spec 1.2 §7).
    public let ocrPreferences: OCRPreferences
    /// Word/PowerPoint setting „office.include“ (spec 1.3).
    public let officePreferences: OfficePreferences
    /// Word/PowerPoint pages for tiles, preview, saving and printing (1.3 Teil B): built for the current display choice
    /// (`OfficeDisplay.pages`) and replaced when it changes, unless given to `init`.
    public private(set) var foreignPages: (any ForeignPageProvider)?
    /// Rises whenever `foreignPages` is replaced; views rebuild what holds the old provider (the tile cache).
    public private(set) var foreignPagesRevision = 0
    /// The layout source whose renderer names go into the Word/Quick Look tile versions; nil = `foreignPages` was given.
    @ObservationIgnored private let pageRenderers: (any PageLayoutSource)?
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
    @ObservationIgnored var rememberedMissing: [String] = []   // internal: AppModel+Storage
    @ObservationIgnored private var lastSort: SortMode
    @ObservationIgnored private var lastPartialWords: Bool
    @ObservationIgnored private var lastSearchFileNames: Bool
    @ObservationIgnored private var lastFileKinds: Set<DocumentKind>
    @ObservationIgnored private var lastOCR = OCRSettings.default
    @ObservationIgnored private var lastIncludeOffice = true
    @ObservationIgnored private var rerunTask: Task<Void, Never>?
    /// Indexes whose damage rebuild at open was already announced (`wasRebuilt` stays true).
    @ObservationIgnored private var announcedRebuilds: Set<ObjectIdentifier> = []

    private nonisolated static let log = Logger(subsystem: "local.pdfsucher", category: "app")

    public init(settings: GridSettings,
                defaults: UserDefaults = .standard,
                environment: any AppEnvironment,
                slideCache: SlideCache = .shared,
                debounce: Duration? = nil,
                openIndex: @escaping @Sendable (URL) throws -> any FolderIndexing = { try FolderIndex.shared(root: $0) },
                officeLayout: (any PageLayoutSource)? = nil,
                foreignPages: (any ForeignPageProvider)? = nil,
                officeRendering: PowerPointDisplaySetting = .shared) {
        self.settings = settings
        self.keyboard = KeyboardSettings(defaults: defaults)
        self.ocrPreferences = OCRPreferences(defaults: defaults)
        self.officePreferences = OfficePreferences(defaults: defaults)
        self.previewZoom = PreviewZoom(defaults: defaults)
        self.searchHistory = SearchHistory(defaults: defaults)
        self.folderBar = FolderBarSettings(defaults: defaults)
        self.defaults = defaults
        self.environment = environment
        self.debounce = debounce
        self.openIndex = openIndex
        self.slideCache = slideCache
        self.officeRendering = officeRendering
        let standardLayout = OfficeLayoutSource.standard(cache: slideCache, rendering: officeRendering)
        self.officeLayout = officeLayout ?? standardLayout
        lastRendering = OfficeRendering(officePreferences)
        officeRendering.value = lastRendering
        self.pageRenderers = foreignPages == nil ? standardLayout : nil
        self.foreignPages = foreignPages ?? OfficeDisplay.pages(for: lastRendering, cache: slideCache, renderers: standardLayout)
        lastSort = settings.sort
        lastPartialWords = settings.partialWords
        lastSearchFileNames = settings.searchFileNames
        lastFileKinds = settings.fileKinds
        lastOCR = OCRSettings(recognizeText: ocrPreferences.recognizeText, includeImages: ocrPreferences.includeImages)
        lastIncludeOffice = officePreferences.includeOffice
        observeSettings()
    }

    // MARK: Sources

    /// ⌘O: folders, PDFs, images and Word/PowerPoint files, several at once; they are added to the loaded sources.
    public func openSources() {
        let urls = environment.chooseSources()
        guard !urls.isEmpty else { return }
        addSources(urls)
    }

    /// Opened or dropped items: folders, PDFs, images and Word/PowerPoint files (each per its setting) are
    /// added, everything else is ignored with a hint.
    /// With sources loaded, asks first whether they are added or replace the loaded ones (1.2.1 §1).
    public func addSources(_ urls: [URL]) {
        let previous = addTask
        addTask = Task { await previous?.value; await requestAdd(urls) }
    }

    /// 1.2.1 §1: the „hinzufügen?“ sheet while it is shown.
    public private(set) var addPrompt: AddPrompt?
    @ObservationIgnored private var pendingAddURLs: [URL] = []
    @ObservationIgnored var addTask: Task<Void, Never>?
    /// Builds the folder tree from every source's document list, independent of the search (Ordnerleiste).
    @ObservationIgnored var treeTask: Task<Void, Never>?

    /// Drop or ⌘O: adds at once without loaded sources or when nothing new would come in (the hints show);
    /// otherwise asks, or follows „Beim Hinzufügen von Quellen“.
    /// - Parameter fromPlace: a click on a folder of „Orte“ (1.4.0 P2): with „Fragen“ it is added without the sheet.
    func requestAdd(_ dropped: [URL], fromPlace: Bool = false) async {
        // A drop while the prompt is open joins it (review I1); the sheet stays the same.
        let openPrompt = addPrompt?.id
        let urls = openPrompt == nil ? dropped : pendingAddURLs + dropped
        guard sourceList.items.count + rememberedMissing.count > 0 else { await add(urls); return }
        let includeImages = ocrPreferences.includeImages, includeOffice = officePreferences.includeOffice
        let (candidates, _) = await Task.detached(priority: .userInitiated) {
            SourceClassifier.classify(urls, includeImages: includeImages, includeOffice: includeOffice)
        }.value
        var trial = sourceList
        let newItems = candidates.filter { !trial.add([$0]).added.isEmpty }
        // Counted after the classification: „Alle entfernen“ may have run meanwhile (review M1).
        let loaded = sourceList.items.count + rememberedMissing.count
        guard loaded > 0, !newItems.isEmpty else { addPrompt = nil; pendingAddURLs = []; await add(urls); return }
        switch settings.addSourcesPolicy {
        case .add: await add(urls)
        case .replace: await replaceSources(with: urls)
        case .ask where fromPlace:
            await add(urls)                     // 1.4.0 P2: a click on a place means „this one too“ (decisions)
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
        if choice == .cancel { pendingPlaceFilter = nil }
        let previous = addTask
        switch choice {
        case .add: addTask = Task { await previous?.value; await add(urls); finishPendingPlace() }
        case .replace: addTask = Task { await previous?.value; await replaceSources(with: urls); finishPendingPlace() }
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
        addTrigger = "replace"
        defer { addTrigger = "added" }
        removeAllSources()
        await add(urls)
        guard !sourceList.items.isEmpty else {
            await add(previous)
            pendingPlaceFilter = nil                         // the place could not be loaded
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
        let includeImages = ocrPreferences.includeImages, includeOffice = officePreferences.includeOffice
        let (candidates, ignored) = await Task.detached(priority: .userInitiated) {
            SourceClassifier.classify(urls, includeImages: includeImages, includeOffice: includeOffice)
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
        requeueWaitingFileLayouts()
        startQueueIfNeeded()
        applyPendingPlaceFilter()
        refreshFolderTree()                              // new roots at once, also while a term is typed
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
        logSourceRemoved(path, isFolder: indexes[path] != nil, reason: "user")
        forget(path)
        persistSources()
        updateIndexStatus()
        sourcesChangedForFolders()
        scheduleSearch(debounced: false)
    }

    /// „Alle entfernen“.
    public func removeAllSources() {
        generation += 1
        openRequest += 1
        cancelQueue()
        for item in sourceList.items {
            logSourceRemoved(item.url.path, isFolder: item.isFolder, reason: addTrigger == "replace" ? "replace" : "remove_all")
        }
        resetSources()
        rememberedMissing.removeAll()
        persistSources()
        noticeKind = nil
        updateIndexStatus()
        sourcesChangedForFolders()
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
        addTrigger = "open"
        insert(LoadedSourceRef(url: root, isFolder: true), index: index)
        addTrigger = "added"
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
        guard let paths, !paths.isEmpty else {
            tileDisk?.dropTiles(notUnder: [])           // no sources: no tiles to keep
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        hangWatch.launchPhase("restore_begin", ["sources": urls.count])
        let token = generation
        let missing = await Task.detached(priority: .userInitiated) {
            urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        }.value
        guard token == generation else { return }
        addTrigger = "launch_restore"
        let failed = await add(urls.filter { !missing.contains($0) })
        addTrigger = "added"
        guard token == generation else { return }       // „Alle entfernen“ or another open meanwhile
        // Folders whose index cannot be opened now stay remembered like missing ones.
        rememberedMissing = missing.map(\.path) + failed.map(\.standardizedFileURL.path)
        if !missing.isEmpty { noticeKind = .missingSources(missing.map(\.lastPathComponent)) }
        persistSources()
        // 1.3.1: tiles of PDFs outside the sources go without asking those PDFs (no macOS access prompt for folders
        // that are no source); an unplugged disk that is remembered keeps its tiles.
        tileDisk?.dropTiles(notUnder: sourceList.items.map(\.url) + rememberedMissing.map { URL(fileURLWithPath: $0) })
        hangWatch.launchPhase("restore_end", ["missing": missing.count, "failed": failed.count])
        logSettings()
    }

    /// 1.5.0, at launch: the settings that change the work (numbers and switches only) and the files per type.
    private func logSettings() {
        guard metrics.isEnabled else { return }
        let metrics = metrics, folders = Array(indexes.values)
        let fields: [String: Any] = [
            "ocr": ocrPreferences.recognizeText, "images": ocrPreferences.includeImages, "office": officePreferences.includeOffice,
            "partial_words": settings.partialWords, "file_names": settings.searchFileNames, "debounce_ms": settings.debounceMs,
            "sources": sourceList.items.count, "folders": folders.count, "ocr_parallel": Indexer.ocrParallelism]
        Task.detached(priority: .utility) {
            var kinds: [String: Int] = [:]
            for index in folders { for hit in (try? index.browse()) ?? [] { kinds[hit.kind.rawValue, default: 0] += 1 } }
            metrics.log("settings", fields.merging(["files_by_kind": kinds]) { a, _ in a })
        }
    }

    /// 1.5.0: every 30 s while the log is on, `resource`: CPU of this process (percent of one core), memory, thermal
    /// state, the running phase and the queue lengths.
    public func startResourceLog(every interval: Duration = .seconds(30)) {
        Task { [weak self] in
            var lastCPU = ResourceUsage.cpuTime(), lastWall = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let cpu = ResourceUsage.cpuTime(), wall = ContinuousClock.now
                if self.metrics.isEnabled {
                    var fields: [String: Any] = [
                        "cpu_pct": (100 * IndexMetrics.ms(cpu - lastCPU) / max(IndexMetrics.ms(wall - lastWall), 1)).rounded(),
                        "thermal": ResourceUsage.thermalState, "phase": self.metricsPhase, "pending_text": self.pending.count,
                        "pending_ocr": self.recognitionPending.count, "pending_layout": self.layoutPending.count,
                        "searching": self.isSearching]
                    if let mb = ResourceUsage.footprintMB() { fields["memory_mb"] = mb }
                    self.metrics.log("resource", fields)
                }
                lastCPU = cpu
                lastWall = wall
            }
        }
    }

    private func openFolderIndex(_ root: URL) async -> (any FolderIndexing)? {
        let opener = openIndex
        let start = ContinuousClock.now
        let opened = await Task.detached(priority: .userInitiated) { Result { try opener(root) } }.value
        if addTrigger == "launch_restore" {
            hangWatch.launchPhase("index_open", ["source": IndexMetrics.hash(root), "open_ms": IndexMetrics.ms(since: start)])
        }
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
        for replaced in result.replaced {
            logSourceReplaced(replaced.url.path, by: source.url.path)
            forget(replaced.url.path)
        }
        guard !result.added.isEmpty else { return }
        let path = source.url.path
        let trigger = result.replaced.isEmpty ? addTrigger : "replaced_by_parent"
        if metrics.isEnabled {
            metrics.log("source_added", ["source": IndexMetrics.hash(path: path), "depth": source.url.pathComponents.count - 1,
                                                     "folder": source.isFolder, "ext": source.isFolder ? "" : source.url.pathExtension.lowercased(),
                                                     "trigger": trigger, "replaces": result.replaced.count])
            logSourceStorage(source.url)
        }
        if let index {
            index.configure(currentOCRSettings, includeOffice: officePreferences.includeOffice)
            indexes[path] = index
            restartedAfterDamage.remove(path)
            if index.wasRebuilt, announcedRebuilds.insert(ObjectIdentifier(index)).inserted {
                setIndexProblem(path, .corruptIndex)
            }
            pending.removeAll { $0 == path }
            recognitionStopped = false              // a new source resumes a stopped recognition
            updateWorkPriority()                     // a filter chosen before (a place clicked) applies at once
            enqueueIndexing(path, trigger: trigger)
        } else if let kind = SingleFileLayout.officeKind(source.url) {
            // Word/PowerPoint: laid out in memory, never recognized. It goes first (behind other single files)
            // and pre-empts a folder's recognition or layout, which resumes afterwards where it stopped.
            fileLayouts[path] = .pending
            singleSearches[path] = SingleFileLayout.search(source.url, kind: kind, state: .pending)
            if let current = currentFolder, indexes[current] != nil {
                if currentPhase == .ocr { preemptRecognition(reason: "single_file") } else if currentPhase == .layout { preemptLayout(reason: "single_file") } else if currentPhase == .wordParts { preemptWordParts(reason: "single_file") }
            }
            enqueueFileLayout(path)
        } else {
            let isImage = ImagePages.isImage(source.url)
            singleSearches[path] = SingleDocumentSearch(source: OverlayTextSource(isImage: isImage, recognized: fileOCR[path] ?? [:],
                                                                                  stamp: fileOCRStamps[path]), kind: isImage ? .image : .pdf)
            // Pages without text (or the image) are recognized in the background (spec 1.2 §2).
            recognitionStopped = false
            // A single file is small: it goes first and pre-empts a long folder recognition, which resumes
            // afterwards where it stopped (final review I1).
            // Also a folder's layout (core review I3): a dropped scan must not wait for all of the Office files.
            // With recognition off it has nothing to do: nothing is stopped for it.
            if canRecognize, let current = currentFolder, indexes[current] != nil {
                if currentPhase == .ocr { preemptRecognition(reason: "single_file") } else if currentPhase == .layout { preemptLayout(reason: "single_file") } else if currentPhase == .wordParts { preemptWordParts(reason: "single_file") }
            }
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
        metricsTriggers[path] = nil
        indexes[path] = nil
        singleSearches[path] = nil
        fileOCR[path] = nil
        fileOCRStamps[path] = nil
        reports[path] = nil
        unreachable.remove(path)
        changedOnDisk.remove(path)
        checkFilterAfterTree.remove(path)
        lastDiskRun[path] = nil
        diskChangeDue.remove(path)
        pending.removeAll { $0 == path }
        recognitionPending.removeAll { $0 == path }
        ocrReports[path] = nil
        layoutPending.removeAll { $0 == path }
        wordPartsPending.removeAll { $0 == path }
        diskScopes[path] = nil
        needsFullScan.remove(path)
        layoutReports[path] = nil
        fileLayouts[path] = nil
        layoutAgain.remove(path)
        clearIndexProblem(path)
        if currentFolder == path {
            // Its cancelled run may take a moment to end: from now on it no longer counts.
            currentWork?.cancel()
            currentWork = nil
            currentLayout?.cancel()
            currentLayout = nil
            currentFileLayout?.cancel()
            currentFileLayout = nil
            currentRecognition?.cancel()
            currentRecognition = nil
            currentWordParts?.cancel()
            currentWordParts = nil
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
        layoutPending.removeAll()
        wordPartsPending.removeAll()
        diskScopes.removeAll()
        needsFullScan.removeAll()
        layoutReports.removeAll()
        fileLayouts.removeAll()
        fileOCR.removeAll()
        fileOCRStamps.removeAll()
        restartedAfterDamage.removeAll()
        indexProblems.removeAll()
        changedOnDisk.removeAll()
        checkFilterAfterTree.removeAll()
        lastDiskRun.removeAll()
        diskChangeDue.removeAll()
        diskChangeTask?.cancel()
        diskChangeTask = nil
    }

    private func persistSources() {
        updateWatchedFolders()
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
            layoutReports[path] = nil
            tileDisk?.removeTiles(under: URL(fileURLWithPath: path, isDirectory: true))   // spec 1.2.4 §3
        }
        guard token == generation else { return }   // other sources are loaded now: no re-index here
        for (path, _) in targets {
            restartedAfterDamage.remove(path)        // a fresh index may be rebuilt again after damage
            if indexes[path] != nil { enqueueIndexing(path, trigger: "delete_index_rebuild") }
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
        wakeQueue()
        if let current = currentFolder, isLoaded(current) {
            // An unfinished run goes back to the front of its queue.
            if currentPhase == .ocr {
                if !recognitionPending.contains(current) { recognitionPending.insert(current, at: 0) }
            } else if currentPhase == .layout {
                if !layoutPending.contains(current) { layoutPending.insert(current, at: 0) }
            } else if currentPhase == .wordParts {
                if !wordPartsPending.contains(current) { wordPartsPending.insert(current, at: 0) }
            } else if !pending.contains(current) {
                pending.insert(current, at: 0)
            }
        }
        currentFolder = nil
        queueRunning = false
        indexRun += 1
    }

    /// Phase 1 for `path` (new folder, re-index): a running text recognition or layout makes way (spec 1.2: new
    /// files must not wait behind a long recognition; finished pages are kept, the folder continues later).
    private func enqueueIndexing(_ path: String, trigger: String) {
        if !pending.contains(path) { pending.append(path) }
        if trigger != "disk_change" { needsFullScan.insert(path) }        // P3: only a plain disk change may be scoped
        if metrics.isEnabled, metricsTriggers[path]?.contains(trigger) != true {
            metricsTriggers[path, default: []].append(trigger)
        }
        preemptRecognition(reason: trigger)
        preemptLayout(reason: trigger)
        preemptWordParts(reason: trigger)
    }

    /// A running „Wortteil-Index“ step stops after its current transaction (nothing moved is lost); the folder goes back
    /// to the front of `wordPartsPending`.
    private func preemptWordParts(reason: String) {
        guard currentPhase == .wordParts, let current = currentFolder, indexes[current] != nil else { return }
        logPreempt(current, phase: "wordparts", reason: reason)
        if !wordPartsPending.contains(current) { wordPartsPending.insert(current, at: 0) }
        currentWordParts?.cancel()
    }

    /// A running folder layout stops (documents already stored stay) and the folder goes back to the front of
    /// `layoutPending`.
    /// A single file's layout is not pre-empted (it is short and was asked for).
    private func preemptLayout(reason: String) {
        guard currentPhase == .layout, let current = currentFolder, let index = indexes[current] else { return }
        logPreempt(current, phase: "layout", reason: reason)
        if !layoutPending.contains(current) { layoutPending.insert(current, at: 0) }
        // 1.4.0 P3: for a change on disk the files being laid out are finished and kept; phase 1 follows right after.
        if reason == "disk_change" { index.stopLayoutGently() } else { currentLayout?.cancel() }
    }

    /// Each folder's last stored layout report (tests).
    var layoutReportsForTesting: [String: LayoutReport] { layoutReports }
    /// Something changed below these folder sources (renamed, deleted, new files): index them again,
    /// incrementally; the tree follows when the run ends (`finishIndexing`).
    /// `urgent`: the root went away or came back (an ejected volume shows „nicht erreichbar“ at once).
    ///
    /// A source cools down for `diskChangeCooldown` after each run for a change on disk ends (the first
    /// change after an add or launch is indexed at once); a report while it cools, waits in
    /// the queue or is being indexed (phase 1) waits for one trailing run (re-review: counted from the end,
    /// so a run longer than the cooldown is not followed at once by the next).
    ///
    /// `scopes` (1.4.0 P3): the changed folders per root from the watcher; a root without an entry is scanned whole. nil:
    /// nothing new is known (a held-back report runs now), what was collected stays.
    func foldersChangedOnDisk(_ roots: [String], urgent: Bool = false, scopes: [String: [String]]? = [:]) {
        let now = ContinuousClock.now
        var any = false
        for root in roots {
            let path = URL(fileURLWithPath: root).standardizedFileURL.path
            guard indexes[path] != nil else { continue }
            changedOnDisk.insert(path)
            if let scopes {
                if !urgent, let changed = scopes[root] ?? scopes[path] {
                    diskScopes[path, default: []].formUnion(changed)
                } else {
                    needsFullScan.insert(path)
                }
            }
            if pending.contains(path) { continue }                       // its run has not started: it sees this
            if urgent {
                diskChangeDue.remove(path)
                enqueueIndexing(path, trigger: "urgent_disk_change")
                any = true
                continue
            }
            let running = currentFolder == path && currentPhase == .text
            if running || lastDiskRun[path].map({ now < $0 + diskChangeCooldown }) == true {
                diskChangeDue.insert(path)
                continue
            }
            diskChangeDue.remove(path)
            enqueueIndexing(path, trigger: "disk_change")
            any = true
        }
        scheduleDiskChanges()
        if any { startQueueIfNeeded() }
    }

    /// One trailing run per waiting source once it has cooled down; sources still queued or being indexed
    /// are scheduled when their run ends (`finishIndexing`).
    private func scheduleDiskChanges() {
        diskChangeTask?.cancel()
        diskChangeTask = nil
        let ready = diskChangeDue.filter { !pending.contains($0) && !(currentFolder == $0 && currentPhase == .text) }
        guard let due = ready.map({ (lastDiskRun[$0] ?? .now) + diskChangeCooldown }).min() else { return }
        diskChangeTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.diskChangeTask = nil
            let waiting = self.diskChangeDue
            self.diskChangeDue = []
            self.foldersChangedOnDisk(waiting.sorted(), scopes: nil)      // still cooling ones wait again; scopes stay
        }
    }

    private func updateWatchedFolders() {
        folderWatcher?.watch(folderSources.map(\.path), includeImages: ocrPreferences.includeImages)
    }

    /// Pending recognitions in queue order (tests).
    var recognitionQueueForTesting: [String] { recognitionPending }

    private func preemptRecognition(reason: String) {
        guard currentPhase == .ocr, let current = currentFolder else { return }
        logPreempt(current, phase: "ocr", reason: reason)
        if !recognitionPending.contains(current) { recognitionPending.insert(current, at: 0) }
        currentRecognition?.cancel()
    }

    private var currentOCRSettings: OCRSettings {
        OCRSettings(recognizeText: ocrPreferences.recognizeText, includeImages: ocrPreferences.includeImages)
    }

    /// Spec 1.2 §7: OCR off stops phase 2 at once (finished pages stay), on resumes it; images on/off lists
    /// the folders again. Spec 1.3: Word/PowerPoint on/off („office.include“) lists the folders again too
    /// (off: their Office files leave the index; loaded single Office files stay).
    private func ocrSettingsChanged() {
        let now = currentOCRSettings
        let includeOffice = officePreferences.includeOffice
        guard now != lastOCR || includeOffice != lastIncludeOffice else { return }
        let rescan = now.includeImages != lastOCR.includeImages || includeOffice != lastIncludeOffice
        let ocrChanged = now != lastOCR
        lastOCR = now
        lastIncludeOffice = includeOffice
        for (_, index) in indexes { index.configure(now, includeOffice: includeOffice) }
        if rescan {
            for url in folderSources { enqueueIndexing(url.path, trigger: "settings_change") }
            updateWatchedFolders()
        }
        if !includeOffice {
            // Office off: a running layout was stopped above; none follows, and the Office files leave the
            // index with the rescan (their problems with them).
            // Loaded Word/PowerPoint single files stay loaded and are still laid out.
            layoutPending.removeAll { indexes[$0] != nil }
            layoutReports.removeAll()
        }
        if ocrChanged {               // the Office switch alone leaves a stopped recognition stopped
            if !now.recognizeText { preemptRecognition(reason: "settings_change") } else { recognitionStopped = false }   // on again: resume after ✕
        }
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
                preemptRecognition(reason: "rerun_ocr")
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

    /// Word/PowerPoint documents of one folder source by layout state (settings „Word/PowerPoint“; nil: not a loaded
    /// folder or unreadable).
    public func layoutCounts(for source: URL) async -> LayoutCounts? {
        let path = LoadedSourceRef(url: source, isFolder: true).url.path
        guard let index = indexes[path] else { return nil }
        return await Task.detached(priority: .userInitiated) { try? index.layoutCounts() }.value
    }

    /// Stored text and word boxes of an OCR page (spec 1.2 §5), nil for a page with a text layer.
    public func ocrText(for page: PageRef) async -> OCRPageText? {
        let path = page.url.standardizedFileURL.path
        if let state = fileLayouts[path] {
            // Word/PowerPoint single file: the laid-out page while the file is the version it was made from.
            guard case .laidOut(let result, let stamp) = state, result.pages.indices.contains(page.pageIndex) else { return nil }
            let url = page.url, laid = result.pages[page.pageIndex]
            let current = await Task.detached(priority: .userInitiated) { FileStamp.of(url) }.value
            guard current == stamp else { return nil }
            return OCRHighlights.usable(OCRPageText(text: laid.text, words: laid.words))
        }
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
        if DocumentKind(fileExtension: page.url.pathExtension)?.isOffice == true {
            // A Word/PowerPoint file edited since its layout: its stored word boxes belong to the old version (core
            // review I2). None are shown; the folder is indexed again (once per file version).
            let url = page.url
            let outdated = await Task.detached(priority: .userInitiated) {
                ((try? index.isOutdated(relativePath: relative)) ?? false) ? FileStamp.of(url) : nil
            }.value
            if let outdated {
                reindexOutdated(folder.path, index: index, path: path, stamp: outdated)
                return nil
            }
        }
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
        preemptRecognition(reason: "user_stop")
        updateIndexStatus()
    }

    private var hasQueuedWork: Bool {
        pending.contains { indexes[$0] != nil }
            || wordPartsPending.contains { indexes[$0] != nil }
            || (officePreferences.includeOffice && layoutPending.contains { indexes[$0] != nil })
            || layoutPending.contains(where: needsFileLayout)
            || (canRecognize && recognitionPending.contains(where: isLoaded))
    }

    private var canRecognize: Bool { ocrPreferences.recognizeText && !recognitionStopped }

    private func startQueueIfNeeded() {
        if queueRunning { wakeQueue() }              // a queue waiting for the slide cache looks at the new work
        guard !queueRunning, hasQueuedWork else { return }
        queueRunning = true
        let previous = indexTask
        previous?.cancel()
        indexTask = Task { [weak self] in
            await previous?.value
            // Phase 1 of every folder first, then the layout of Word/PowerPoint (spec 1.3), then phase 2
            // (spec 1.2 §3): a new folder is searchable at once.
            // Single files go before folders in both later phases (1.2 „single file first“, core review I3).
            while !Task.isCancelled, let self {
                if let path = self.nextPending() {
                    await self.indexFolder(path)
                } else if self.cacheJobs > 0, self.layoutWaiting {
                    // Slide-cache job running: only layout steps wait. A dropped scan is recognized meanwhile;
                    // otherwise sleep until the job ends or new work comes (`wakeQueue`), then look again.
                    if let path = self.nextFileRecognition() {
                        await self.recognizeFile(path)
                    } else if let path = self.nextWordParts() {
                        await self.buildWordParts(path)
                    } else {
                        await self.waitForWake()
                    }
                } else if let path = self.nextFileLayout() {
                    await self.layoutFile(path)
                } else if let path = self.nextFileRecognition() {
                    await self.recognizeFile(path)
                } else if let path = self.nextWordParts() {
                    // 1.3.12: after phase 1 of every folder and the single files, before folder layout and recognition.
                    await self.buildWordParts(path)
                } else if let path = self.nextLayout() {
                    await self.layoutFolder(path)
                } else if let path = self.nextRecognition() {
                    await self.recognizeFolder(path)
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

    private func nextWordParts() -> String? {
        while let path = wordPartsPending.first {
            wordPartsPending.removeFirst()
            if indexes[path] != nil { return path }
        }
        return nil
    }

    /// Wortteil-Index (1.3.12) of one folder, cancellable after each transaction without losing what moved.
    private func buildWordParts(_ path: String) async {
        guard let index = indexes[path] else { return }
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .wordParts
        setPreparingWordParts(path, done: 0, total: 0)
        let metricsRun = beginMetricsRun(path, phase: "wordparts")
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .utility) { () -> Result<Int, Error> in
            defer { continuation.finish() }
            do {
                return .success(try await IndexMetrics.$run.withValue(metricsRun.id) { try await index.buildWordParts { continuation.yield($0) } })
            } catch { return .failure(error) }
        }
        currentWordParts = work
        await withTaskCancellationHandler {
            for await progress in stream where !Task.isCancelled {
                guard self.indexRun == run, self.currentFolder == path else { continue }
                self.setPreparingWordParts(path, done: progress.done, total: progress.total)
            }
        } onCancel: {
            work.cancel()
        }
        let result = await work.value
        endMetricsRun(metricsRun, path: path, phase: "wordparts", result: result.map { _ in () })
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentWordParts = nil
        currentPhase = .text
        guard indexes[path] != nil else { return }
        switch result {
        case .success:
            wordPartsPending.removeAll { $0 == path }
            if summaryStyle == .search { publishFiltered(keepFocus: true) }      // the „langsamer“ hint goes
        case .failure(let error) where error is CancellationError:
            break                                    // pre-empted: queued again already
        case .failure(let error):
            if case IndexStoreError.corruptIndexRebuilt = error, !restartedAfterDamage.contains(path) {
                restartedAfterDamage.insert(path)
                reports[path] = nil
                ocrReports[path] = nil
                layoutReports[path] = nil
                setIndexProblem(path, .corruptIndex)
                enqueueIndexing(path, trigger: "corrupt_rebuild")
            } else {
                // Searches stay complete (pages without trigram entries are scanned); the next phase 1 tries again.
                Self.log.error("Wortteil-Index in \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A search uses the trigram index (infix/suffix terms) while a folder's trigram index is still being built: it
    /// scans the pages not in it yet, so it can be slower (1.3.12).
    private var wordPartsBusy: Bool {
        (currentPhase == .wordParts && currentFolder.map { indexes[$0] != nil } == true)
            || wordPartsPending.contains { indexes[$0] != nil }
    }

    /// The next folder layout (single files are taken first by `nextFileLayout`).
    /// Runs after `nextFileLayout` in the same loop pass, so no single file waiting for its layout is left here.
    private func nextLayout() -> String? {
        while let path = layoutPending.first {
            layoutPending.removeFirst()
            if indexes[path] != nil, officePreferences.includeOffice { return path }
        }
        return nil
    }

    /// The first Word/PowerPoint single file waiting in `layoutPending`, wherever it stands.
    private func nextFileLayout() -> String? {
        guard let slot = layoutPending.firstIndex(where: needsFileLayout) else { return nil }
        return layoutPending.remove(at: slot)
    }

    /// The first PDF/image single file waiting for recognition, before any folder's layout or recognition.
    private func nextFileRecognition() -> String? {
        guard canRecognize, let slot = recognitionPending.firstIndex(where: isSingleFile) else { return nil }
        return recognitionPending.remove(at: slot)
    }

    private func isSingleFile(_ path: String) -> Bool { indexes[path] == nil && singleSearches[path] != nil }

    /// A layout step (single file or folder) waits; it must not start while a slide-cache job runs.
    private var layoutWaiting: Bool {
        layoutPending.contains(where: needsFileLayout)
            || (officePreferences.includeOffice && layoutPending.contains { indexes[$0] != nil })
    }

    /// The queue sleeps here while only layout steps are left and a slide-cache job runs.
    @ObservationIgnored private var queueWake: CheckedContinuation<Void, Never>?

    private func waitForWake() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                queueWake = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeQueue() }
        }
    }

    /// Lets a sleeping queue look again: a slide-cache job ended, new work came, or the queue was cancelled.
    private func wakeQueue() {
        queueWake?.resume()
        queueWake = nil
    }

    /// A loaded Word/PowerPoint single file that waits for its layout.
    private func needsFileLayout(_ path: String) -> Bool {
        singleSearches[path] != nil && fileLayouts[path]?.isPending == true
    }

    /// Queues a single file's layout at the front, behind the single files already there (files dropped
    /// together keep their order).
    private func enqueueFileLayout(_ path: String) {
        layoutPending.removeAll { $0 == path }
        let slot = layoutPending.firstIndex { indexes[$0] != nil } ?? layoutPending.endIndex
        layoutPending.insert(path, at: slot)
    }

    /// Single files whose layout waits after an error (not „unreadable“) are tried again with the next add.
    private func requeueWaitingFileLayouts() {
        for source in sourceList.items where !source.isFolder {
            let path = source.url.path
            if needsFileLayout(path), currentFolder != path, !layoutPending.contains(path) { enqueueFileLayout(path) }
        }
    }

    /// A laid-out or unreadable single file changed on disk: it waits again and is laid out anew (its old
    /// words are gone; a file that was still being copied gets another chance).
    private func relayOutChangedFile(_ path: String) {
        guard fileLayouts[path]?.stamp != nil else { return }
        requeueFileLayout(path)
        startQueueIfNeeded()
    }

    /// A loaded Word/PowerPoint single file waits for a new layout (its old pages go; e.g. its slides left the cache).
    private func requeueFileLayout(_ path: String) {
        guard let source = sourceList.items.first(where: { $0.url.path == path && !$0.isFolder }),
              let kind = SingleFileLayout.officeKind(source.url), fileLayouts[path] != nil else { return }
        fileLayouts[path] = .pending
        singleSearches[path] = SingleFileLayout.search(source.url, kind: kind, state: .pending)
        if currentFolder != path { enqueueFileLayout(path) }
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
        // Changes reported until now are seen by this run; later ones stay marked for the next (re-review).
        let sawChange = changedOnDisk.remove(path) != nil
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .text
        setBuilding(path, done: 0, total: 0)
        // P3: only the changed folders when nothing else asked for this run; otherwise (and when unsure) the whole tree.
        let collected = diskScopes.removeValue(forKey: path)
        let scopes: [String]? = needsFullScan.remove(path) == nil && sawChange ? collected.map { $0.sorted() } : nil
        let metricsRun = beginMetricsRun(path, phase: "text", sawChange: sawChange, scopes: scopes?.count)
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .utility) { () -> Result<IndexReport, Error> in
            defer { continuation.finish() }
            do {
                return .success(try await IndexMetrics.$run.withValue(metricsRun.id) {
                    if let scopes { try await index.update(scopes: scopes) { continuation.yield($0) } }
                    else { try await index.update { continuation.yield($0) } }
                })
            } catch { return .failure(error) }
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
        endMetricsRun(metricsRun, path: path, phase: "text", result: result.map { _ in () })
        if scopes != nil, case .failure = result { needsFullScan.insert(path) }      // what it did not finish: all again
        guard !Task.isCancelled, indexRun == run else {
            if scopes != nil { needsFullScan.insert(path) }
            if sawChange, indexes[path] != nil { changedOnDisk.insert(path) }   // it runs again later
            return
        }
        currentFolder = nil
        currentWork = nil
        guard indexes[path] != nil else { return }          // removed while it ran
        finishIndexing(result, path: path, sawChange: sawChange)
    }

    /// One folder's text recognition (phase 2, spec 1.2 §3), cancellable without losing finished pages.
    private func recognizeFolder(_ path: String) async {
        guard let index = indexes[path] else { return }
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .ocr
        setRecognizing(path, done: 0, total: 0)
        let metricsRun = beginMetricsRun(path, phase: "ocr")
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .utility) { () -> Result<OCRReport, Error> in
            defer { continuation.finish() }
            do {
                return .success(try await IndexMetrics.$run.withValue(metricsRun.id) { try await index.recognize { continuation.yield($0) } })
            } catch { return .failure(error) }
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
        endMetricsRun(metricsRun, path: path, phase: "ocr", result: result.map { _ in () })
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
                layoutReports[path] = nil
                setIndexProblem(path, .corruptIndex)
                enqueueIndexing(path, trigger: "corrupt_rebuild")
            } else {
                Self.log.error("Recognition in \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                setIndexProblem(path, .indexFailed(error.localizedDescription))
            }
        }
    }

    /// One folder's layout of Word/PowerPoint documents (spec 1.3), cancellable without losing stored ones.
    /// No ✕ of its own: removing the source, the Word/PowerPoint switch or quitting stops it.
    private func layoutFolder(_ path: String) async {
        guard let index = indexes[path] else { return }
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .layout
        layoutAgain.remove(path)                     // this run takes every document waiting now
        setLayingOut(path, done: 0, total: 0)
        let metricsRun = beginMetricsRun(path, phase: "layout")
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let startFonts = fontStarter(), office = officePreferences.includeOffice
        let work = Task.detached(priority: .utility) { () -> Result<LayoutReport, Error> in
            defer { continuation.finish() }
            do {
                return .success(try await IndexMetrics.$run.withValue(metricsRun.id) { try await index.layOut { progress in
                    // The run's first progress counts its pending Word/PowerPoint documents, just before the layout
                    // source gets the first one: only then Office's fonts are needed (none for PDFs/images). The
                    // count has no kinds, so decks under Quick Look alone prewarm too (decisions „1.3.2“).
                    if office, progress.total > 0 { startFonts() }
                    continuation.yield(progress)
                } })
            } catch { return .failure(error) }
        }
        currentLayout = work
        var finished = 0
        await withTaskCancellationHandler {
            for await progress in stream where !Task.isCancelled {
                guard self.indexRun == run, self.currentFolder == path else { continue }
                self.setLayingOut(path, done: progress.done, total: progress.total)
                if progress.done > finished {
                    // New pages are stored: thumbnails and the browse list may show them.
                    finished = progress.done
                    self.bumpLayoutRevisionSoon()
                    self.refreshBrowseSoon()
                }
            }
        } onCancel: {
            work.cancel()
        }
        let result = await work.value
        endMetricsRun(metricsRun, path: path, phase: "layout", result: result.map { _ in () })
        bumpLayoutRevision()                         // what this run stored, also when it was stopped
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentLayout = nil
        currentPhase = .text
        guard indexes[path] != nil else { return }
        switch result {
        case .success(let report):
            // A run that ends just after „Word/PowerPoint“ was switched off adds no problems back.
            if officePreferences.includeOffice { layoutReports[path] = report }
            if layoutAgain.remove(path) != nil, officePreferences.includeOffice {
                // A document was asked for while this run had already fetched its work: one more run.
                if !layoutPending.contains(path) { layoutPending.append(path) }
            } else {
                layoutPending.removeAll { $0 == path }
            }
            // Only new pages need a new search (a folder without Office files must not search once more).
            if report.laidOut > 0 { scheduleRefreshAfterRecognition() }
        case .failure(let error) where error is CancellationError:
            break                                    // pre-empted: queued again already
        case .failure(let error):
            if case IndexStoreError.corruptIndexRebuilt = error, !restartedAfterDamage.contains(path) {
                restartedAfterDamage.insert(path)
                reports[path] = nil
                ocrReports[path] = nil
                layoutReports[path] = nil
                setIndexProblem(path, .corruptIndex)
                enqueueIndexing(path, trigger: "corrupt_rebuild")
            } else {
                Self.log.error("Layout in \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                setIndexProblem(path, .indexFailed(error.localizedDescription))
            }
        }
    }

    /// Layout of a Word/PowerPoint single file (in memory, 1.3 Teil B Task 5): off the main actor with a
    /// time limit; cancelled only by removing the file (or the whole queue).
    private func layoutFile(_ path: String) async {
        guard let source = sourceList.items.first(where: { $0.url.path == path && !$0.isFolder }),
              let kind = SingleFileLayout.officeKind(source.url), needsFileLayout(path) else { return }
        let url = source.url
        indexRun += 1
        let run = indexRun
        currentFolder = path
        currentPhase = .layout
        indexStatus = .layingOut(folder: 1, folders: 1, done: 0, total: 1)
        // Word always needs Office's fonts; a deck only under SlideKit (Quick Look draws it itself).
        if officePreferences.includeOffice, kind == .word || !OfficeDisplay.usesSlideCache(officeRendering.value) {
            fontStarter()()
        }
        let layout = officeLayout, timeout = fileLayoutTimeout
        let work = Task.detached(priority: .utility) {
            await SingleFileLayout.run(url, kind: kind, source: layout, timeout: timeout)
        }
        currentFileLayout = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, indexRun == run else { return }
        currentFolder = nil
        currentFileLayout = nil
        currentPhase = .text
        guard singleSearches[path] != nil else { return }        // removed while it ran
        switch result {
        case .success(.pending):
            enqueueFileLayout(path)                  // the file changed during its layout: once more
        case .success(let state):
            indexStatus = .layingOut(folder: 1, folders: 1, done: 1, total: 1)
            fileLayouts[path] = state
            singleSearches[path] = SingleFileLayout.search(url, kind: kind, state: state)
            layoutPending.removeAll { $0 == path }
            bumpLayoutRevision()
            scheduleRefreshAfterRecognition()
        case .failure(let error) where error is CancellationError:
            break                                    // the queue was stopped: queued again already
        case .failure(let error):
            // Not „unreadable“: it waits until the next add or launch.
            Self.log.error("Layout of \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            layoutPending.removeAll { $0 == path }
        }
    }

    /// `layoutRevision` once the last rise is a second ago.
    private func bumpLayoutRevisionSoon() {
        guard layoutBumpTask == nil else { return }
        let due = lastLayoutBump + .seconds(1)
        if due <= .now { bumpLayoutRevision(); return }
        layoutBumpTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.layoutBumpTask = nil
            self.bumpLayoutRevision()
        }
    }

    private func bumpLayoutRevision() {
        layoutBumpTask?.cancel()
        layoutBumpTask = nil
        lastLayoutBump = .now
        layoutRevision += 1
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
                        isImage: isImage, recognized: self.fileOCR[path] ?? [:], stamp: self.fileOCRStamps[path]), kind: isImage ? .image : .pdf)
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
        if QueryParser.parse(searchText, partialWords: settings.partialWords).isEmpty {
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

    private func setPreparingWordParts(_ path: String, done: Int, total: Int) {
        let folders = folderSources.map(\.path)
        let position = (folders.firstIndex(of: path) ?? 0) + 1
        indexStatus = .preparingWordParts(folder: position, folders: max(folders.count, 1), done: done, total: total)
    }

    private func setLayingOut(_ path: String, done: Int, total: Int) {
        let folders = folderSources.map(\.path)
        let position = (folders.firstIndex(of: path) ?? 0) + 1
        indexStatus = .layingOut(folder: position, folders: max(folders.count, 1), done: done, total: total)
    }

    // MARK: Measurement log (1.3.9)

    private struct MetricsRun { let id: Int; let start: ContinuousClock.Instant }

    /// `run_start` of one queue step; phase 1 takes the triggers collected since the folder was queued.
    private func beginMetricsRun(_ path: String, phase: String, sawChange: Bool = false, scopes: Int? = nil) -> MetricsRun {
        metricsRunStart = .now
        var triggers = phase == "text" ? (metricsTriggers.removeValue(forKey: path) ?? []) : []
        guard metrics.isEnabled else { return MetricsRun(id: 0, start: metricsRunStart) }
        if sawChange, !triggers.contains(where: { $0.hasSuffix("disk_change") }) { triggers.append("disk_change") }
        let run = metrics.nextRun()
        metrics.log("run_start", ["run": run, "source": IndexMetrics.hash(path: path), "phase": phase,
                                  "trigger": triggers.isEmpty ? (phase == "text" ? "unknown" : "queue") : triggers.joined(separator: "+"),
                                  "pending": pending.count, "recognitionPending": recognitionPending.count, "scopes": scopes ?? 0,
                                  "layoutPending": layoutPending.count])
        return MetricsRun(id: run, start: metricsRunStart)
    }

    private func endMetricsRun(_ run: MetricsRun, path: String, phase: String, result: Result<Void, Error>) {
        guard run.id > 0 else { return }
        let outcome = switch result {
        case .success: "ok"
        case .failure(let error) where error is CancellationError: "cancelled"
        case .failure: "failed"
        }
        metrics.log("run_end", ["run": run.id, "source": IndexMetrics.hash(path: path), "phase": phase,
                                            "outcome": outcome, "ms": IndexMetrics.ms(since: run.start)])
    }

    /// A running layout or recognition makes way; `elapsed_ms` is how long the step had run.
    private func logPreempt(_ path: String, phase: String, reason: String) {
        metrics.log("preempt", ["source": IndexMetrics.hash(path: path), "phase": phase, "reason": reason,
                                            "elapsed_ms": IndexMetrics.ms(since: metricsRunStart)])
    }

    private func logSourceRemoved(_ path: String, isFolder: Bool, reason: String) {
        metrics.log("source_removed", ["source": IndexMetrics.hash(path: path), "folder": isFolder, "reason": reason])
    }

    /// A loaded child replaced by its parent folder: the documents of the child's index are indexed again for the parent
    /// (counted off the main actor).
    private func logSourceReplaced(_ old: String, by new: String) {
        guard metrics.isEnabled else { return }
        let index = indexes[old], metrics = metrics
        Task.detached(priority: .utility) {
            let documents = (try? index?.browse().count) ?? 0
            metrics.log("source_replaced", ["source": IndexMetrics.hash(path: new), "old_source": IndexMetrics.hash(path: old),
                                                        "old_documents": documents, "old_folder": index != nil])
        }
    }

    /// 1.4.3: where a source lies (local/internal disk, file system, iCloud Drive), asked off the main actor.
    private func logSourceStorage(_ url: URL) {
        let metrics = metrics
        Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeTypeNameKey, .isUbiquitousItemKey])
            metrics.log("source_storage", ["source": IndexMetrics.hash(url), "volume_local": values?.volumeIsLocal ?? false,
                                           "volume_internal": values?.volumeIsInternal ?? false,
                                           "volume_type": values?.volumeTypeName ?? "?", "ubiquitous": values?.isUbiquitousItem ?? false])
        }
    }

    /// The indexing phase running now, for the measurement log.
    private var metricsPhase: String {
        guard currentFolder != nil else { return "none" }
        return switch currentPhase {
        case .text: "text"
        case .ocr: "ocr"
        case .layout: "layout"
        case .wordParts: "wordparts"
        }
    }

    private func finishIndexing(_ result: Result<IndexReport, Error>, path: String, sawChange: Bool = false) {
        if case .failure(let error) = result, error is CancellationError {
            if sawChange { changedOnDisk.insert(path) }
        } else if sawChange {
            lastDiskRun[path] = .now                         // the cooldown counts from the end of a disk-change run
        }
        defer { scheduleDiskChanges() }                      // a change reported during the run
        switch result {
        case .success(let report):
            restartedAfterDamage.remove(path)
            unreachable.remove(path)
            reports[path] = report
            clearIndexProblem(path)
            if officePreferences.includeOffice {
                if !layoutPending.contains(path) { layoutPending.append(path) }
            } else {
                layoutReports[path] = nil                // its Office files left the index
            }
            if sawChange { checkFilterAfterTree.insert(path) }
            refreshFolderTree()                              // the folder's files are listed now
            // Tiles of documents that left the folder or changed (spec 1.2.4 §3).
            tileDisk?.pruneStale(under: URL(fileURLWithPath: path, isDirectory: true))
            if !recognitionPending.contains(path) { recognitionPending.append(path) }
            if !wordPartsPending.contains(path) { wordPartsPending.append(path) }
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
                if sawChange { changedOnDisk.insert(path) }  // the rebuild run checks the filter then
                pending.insert(path, at: 0)
                needsFullScan.insert(path)
                metricsTriggers[path, default: []].append("corrupt_rebuild")
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
        // A single file being laid out or recognized keeps the status its run sets (also without folders).
        if queueRunning, let current = currentFolder, indexes[current] == nil, currentPhase != .text { return }
        let folders = folderSources.map(\.path)
        if folders.isEmpty { indexStatus = .none; return }
        if queueRunning {
            // The folder being worked on (keeping its progress), or the next one while a run ends.
            if let current = currentFolder {
                switch (currentPhase, indexStatus) {
                case (.text, .building(_, _, let done, let total)): setBuilding(current, done: done, total: total)
                case (.ocr, .recognizing(_, _, let done, let total)): setRecognizing(current, done: done, total: total)
                case (.layout, .layingOut(_, _, let done, let total)): setLayingOut(current, done: done, total: total)
                case (.wordParts, .preparingWordParts(_, _, let done, let total)): setPreparingWordParts(current, done: done, total: total)
                case (.wordParts, _): setPreparingWordParts(current, done: 0, total: 0)
                case (.text, _): setBuilding(current, done: 0, total: 0)
                case (.ocr, _): setRecognizing(current, done: 0, total: 0)
                case (.layout, _): setLayingOut(current, done: 0, total: 0)
                }
                return
            } else if let next = pending.first(where: { indexes[$0] != nil }) {
                setBuilding(next, done: 0, total: 0)
                return
            } else if let next = wordPartsPending.first(where: { indexes[$0] != nil }) {
                setPreparingWordParts(next, done: 0, total: 0)
                return
            } else if officePreferences.includeOffice, let next = layoutPending.first(where: { indexes[$0] != nil }) {
                setLayingOut(next, done: 0, total: 0)
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
            // Word/PowerPoint: „nicht lesbar“ and „ohne Text“ of the whole index (its last layout run).
            let layout = layoutReports[path] ?? LayoutReport()
            // With recognition on, phase 1's „ohne Text“ (scans waiting for OCR) does not count: only what
            // recognition found no text in (review of 1.2 Task 1).
            let withoutText = ocrPreferences.recognizeText ? ocr.noText : report.noText
            failed += Self.unique(report.failed + ocr.failed + layout.failed).map { prefix + $0 }
            noText += Self.unique(withoutText + layout.noText).map { prefix + $0 }
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
            if self.isBrowsing, QueryParser.parse(self.searchText, partialWords: self.settings.partialWords).isEmpty {
                self.scheduleSearch(debounced: false, background: true)
            }
        }
    }

    /// Every file of every target, off the main actor. Unreadable single PDFs are listed as such;
    /// a folder whose list cannot be read contributes nothing.
    /// The list comes back sorted by `mode` (sorting 10,000 entries takes long enough to stutter on the
    /// main actor, final review of 1.1), each entry with its source path.
    private nonisolated static func browse(_ targets: [SearchTarget], sortedBy mode: SortMode) async -> (sorted: [(target: String, hit: DocumentHit)], stale: [String]) {
        let found = await browse(targets)
        return (sortedPairs(found.map { ($0.target, $0.hits) }, by: mode), found.filter(\.stale).map(\.target))
    }

    /// All hits of all targets, sorted together, each with its target.
    private nonisolated static func sortedPairs(_ found: [(target: String, hits: [DocumentHit])], by mode: SortMode) -> [(target: String, hit: DocumentHit)] {
        var targetOf: [String: String] = [:]
        for (target, hits) in found { for hit in hits { targetOf[hit.id] = target } }
        return sortHits(found.flatMap(\.hits), by: mode).map { (targetOf[$0.id] ?? "", $0) }
    }

    /// The folder tree from every source's document list, off the main actor; does not depend on the search.
    func refreshFolderTree() {
        treeTask?.cancel()
        let targets: [SearchTarget] = sourceList.items.compactMap { source in
            let path = source.url.path
            if source.isFolder { return indexes[path].map { .folder(path, $0) } }
            return singleSearches[path].map { .file(source.url, $0, fileLayouts[path]) }
        }
        treeTask = Task { [weak self] in
            let found = await Self.browse(targets)
            guard !Task.isCancelled, let self else { return }
            self.rebuildFolderTree(files: found.flatMap { $0.hits.map(\.url) }, checkFilter: true)
        }
    }

    /// `stale`: a laid-out Word/PowerPoint single file that changed since (listed as waiting, laid out again).
    private nonisolated static func browse(_ targets: [SearchTarget]) async -> [(target: String, hits: [DocumentHit], stale: Bool)] {
        let work = Task.detached(priority: .userInitiated) { () -> [(target: String, hits: [DocumentHit], stale: Bool)] in
            await withTaskGroup(of: (String, [DocumentHit], Bool).self) { group in
                for target in targets {
                    group.addTask {
                        switch target {
                        case .folder(let path, let index):
                            do { return (path, try index.browse(), false) } catch {
                                log.error("Browsing \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                                return (path, [], false)
                            }
                        case .file(let url, _, let layout):
                            let stale = SingleFileLayout.isStale(url, layout)
                            return (url.path, [singleEntry(url, layout: stale ? .pending : layout)], stale)
                        }
                    }
                }
                var all: [(target: String, hits: [DocumentHit], stale: Bool)] = []
                for await (path, found, stale) in group { all.append((path, found, stale)) }
                return all
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private nonisolated static func singleEntry(_ url: URL, layout: FileLayoutState?) -> DocumentHit {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        if let layout, let kind = SingleFileLayout.officeKind(url) {
            // Word/PowerPoint: waiting → no pages yet; unreadable; laid out → its pages (spec 1.3).
            let pages: Int, unreadable: Bool
            switch layout {
            case .pending: (pages, unreadable) = (0, false)
            case .failed: (pages, unreadable) = (0, true)
            case .laidOut(let result, _): (pages, unreadable) = (result.pages.count, false)
            }
            return DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
                               pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: url,
                               pageCount: pages, isUnreadable: unreadable, kind: kind, isSimplified: SingleFileLayout.isSimplified(layout),
                               fileSize: fileSize)
        }
        if ImagePages.isImage(url) {
            let readable = ImagePages.isReadable(url)
            return DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
                               pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: url,
                               pageCount: readable ? 1 : 0, isUnreadable: !readable, kind: .image, fileSize: fileSize)
        }
        let document = PDFDocument(url: url)
        let readable = document.map { !$0.isLocked } ?? false
        return DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
                           pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: url,
                           pageCount: readable ? document?.pageCount ?? 0 : 0, isUnreadable: !readable, fileSize: fileSize)
    }

    private func applyBrowse(_ sorted: [(target: String, hit: DocumentHit)], mode: SortMode, for parsed: ParsedQuery) {
        let start = ContinuousClock.now
        defer { lastMainApply = ContinuousClock.now - start }
        let loaded = Set(sourceList.items.map(\.url.path))
        var entries = sorted.filter { loaded.contains($0.target) }.map(\.hit)
        let current = ViewerText.browseSortMode(settings.sort)
        if current != mode { entries = sortHits(entries, by: current) }     // the sort changed meanwhile
        isBrowsing = true
        rebuildFolderTree(files: entries.map(\.url))
        show(entries, for: parsed, summary: .browse)
    }

    /// Test hook: main-actor time of the last browse list applied.
    @ObservationIgnored var lastMainApply: Duration = .zero

    // MARK: Search

    /// Delay after the last keystroke before searching.
    var typingDelay: Duration { debounce ?? .milliseconds(settings.debounceMs) }

    /// What one search runs over: every folder index and every single PDF.
    private enum SearchTarget: Sendable {
        case folder(String, any FolderIndexing)
        /// The layout state of a Word/PowerPoint single file; nil = PDF or image.
        case file(URL, SingleDocumentSearch, FileLayoutState?)
    }

    private struct SearchOutcome: Sendable {
        /// Hits per target path.
        var hits: [(target: String, hits: [DocumentHit])] = []
        /// All hits sorted by `sort` off the main actor, each with its target.
        var sorted: [(target: String, hit: DocumentHit)] = []
        var sort: SortMode = .matchCount
        var errors: [(target: String, error: Error)] = []
        /// Single files whose text failed but whose name matched: shown by their name, no notice for their error.
        var foundByName: Set<String> = []
    }

    /// - Parameter background: a browse refresh while indexing: no „Suche läuft…“.
    private func scheduleSearch(debounced: Bool, background: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        browseRunning = false
        let parsed = QueryParser.parse(searchText, partialWords: settings.partialWords)
        let targets: [SearchTarget] = sourceList.items.compactMap { source in
            let path = source.url.path
            if source.isFolder { return indexes[path].map { .folder(path, $0) } }
            return singleSearches[path].map { .file(source.url, $0, fileLayouts[path]) }
        }
        if targets.isEmpty {
            isBrowsing = false
            show([], for: parsed, summary: .empty)
            return
        }
        let sort = settings.sort
        let searchNames = settings.searchFileNames      // spec 1.3.2 §4
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
                self.applyBrowse(found.sorted, mode: mode, for: parsed)
                for path in found.stale { self.relayOutChangedFile(path) }
                if self.browseRefreshWanted {
                    self.browseRefreshWanted = false
                    self.refreshBrowseSoon()
                }
            }
            return
        }
        searchToken += 1
        let token = searchToken
        searchFirstRows = nil
        let metrics = metrics
        searchTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let started = ContinuousClock.now, phase = self?.metricsPhase ?? "none"
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
                await Self.run(parsed, sort: sort, searchNames: searchNames, over: targets, early: collector, metrics: metrics)
            } onCancel: { early.cancel() }
            collector.finish()
            early.cancel()
            guard !Task.isCancelled else {
                self?.logSearch(parsed, sources: targets.count, started: started, debounce: delay, phase: phase, outcome: nil)
                return
            }
            self?.isSearching = false
            self?.apply(outcome, for: parsed)
            self?.logSearch(parsed, sources: targets.count, started: started, debounce: delay, phase: phase, outcome: outcome)
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
        guard !filtered(early).isEmpty else { return }     // hidden early rows: keep the shown list (no empty flash)
        isBrowsing = false
        show(sortHits(early, by: settings.sort), for: parsed, summary: .search, keepFocus: true)
        searchFirstRows = .now
    }

    /// 1.4.3: `search` in the measurement log (nil outcome = cancelled by a newer search); the first finished one
    /// also writes `launch_phase` `first_search_done`.
    private func logSearch(_ parsed: ParsedQuery, sources: Int, started: ContinuousClock.Instant, debounce: Duration,
                           phase: String, outcome: SearchOutcome?) {
        guard metrics.isEnabled else { return }
        var fields: [String: Any] = ["terms": parsed.terms.count, "sources": sources, "total_ms": IndexMetrics.ms(since: started),
                                     "cancelled": outcome == nil, "indexing": phase, "debounce_ms": IndexMetrics.ms(debounce)]
        if let outcome {
            fields["hits"] = outcome.sorted.count
            fields["first_rows_ms"] = IndexMetrics.ms((searchFirstRows ?? .now) - started)
        }
        metrics.log("search", fields)
        if outcome != nil, !firstSearchLogged {
            firstSearchLogged = true
            hangWatch.launchPhase("first_search_done")
        }
    }

    /// Runs the search over all targets in parallel, off the main actor; cancelling the caller cancels
    /// the work. A failing target does not drop the others' hits.
    private nonisolated static func run(_ q: ParsedQuery, sort: SortMode, searchNames: Bool, over targets: [SearchTarget],
                                        early: EarlyResults? = nil, metrics: IndexMetrics = .shared) async -> SearchOutcome {
        let work = Task.detached(priority: .userInitiated) { () -> SearchOutcome in
            await withTaskGroup(of: (String, Result<[DocumentHit], Error>, DocumentHit?).self) { group in
                for target in targets {
                    group.addTask {
                        switch target {
                        case .folder(let path, let index):
                            var report: (@Sendable ([DocumentHit]) -> Void)?
                            if let early { report = { hits in early.add(path, hits) } }
                            let onPartial = report
                            return (path, Result { try index.search(q, sort: sort, searchNames: searchNames, onPartial: onPartial) }, nil)
                        case .file(let url, let single, let layout):
                            // A Word/PowerPoint file that changed since its layout throws `StaleFileLayout`.
                            let started = ContinuousClock.now
                            let result = Result { try single.search(url: url, query: q, searchNames: searchNames).map { [$0] } ?? [] }
                            // 1.5.0: each single file's search (Word/PowerPoint are searched in their layout).
                            metrics.log("search_file", ["file": IndexMetrics.hash(url), "ext": url.pathExtension.lowercased(),
                                                        "layout": Self.layoutName(layout),
                                                        "ms": IndexMetrics.ms(since: started), "outcome": Self.outcome(result)])
                            // Text not readable (locked, damaged, not laid out yet, changed): still found by its name,
                            // shown as when browsing (Chris, 2026-11-14); the error is handled as before.
                            guard case .failure(let error) = result, !(error is CancellationError), searchNames,
                                  SingleDocumentSearch.nameMatches(url, q) else { return (url.path, result, nil) }
                            let state: FileLayoutState? = error is StaleFileLayout ? .pending : layout
                            return (url.path, result, singleEntry(url, layout: state).withNameMatch())
                        }
                    }
                }
                var outcome = SearchOutcome()
                for await (path, result, byName) in group {
                    switch result {
                    case .success(let found): outcome.hits.append((path, found))
                    case .failure(let error): outcome.errors.append((path, error))
                    }
                    if let byName {
                        outcome.hits.append((path, [byName]))
                        outcome.foundByName.insert(path)
                    }
                }
                outcome.sorted = sortedPairs(outcome.hits, by: sort)
                outcome.sort = sort
                return outcome
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// `search_file`: the layout state of a Word/PowerPoint single file ("none" for PDFs and images).
    private nonisolated static func layoutName(_ state: FileLayoutState?) -> String {
        switch state {
        case nil: "none"
        case .pending: "pending"
        case .laidOut: "laid_out"
        case .failed: "failed"
        }
    }

    /// `search_file`: what one single file's search gave.
    private nonisolated static func outcome(_ result: Result<[DocumentHit], Error>) -> String {
        switch result {
        case .success(let hits): hits.isEmpty ? "no_hit" : "hit"
        case .failure(let error) where error is StaleFileLayout: "stale_layout"
        case .failure(let error) where error is CancellationError: "cancelled"
        case .failure(let error): String(describing: type(of: error))
        }
    }

    private func apply(_ outcome: SearchOutcome, for parsed: ParsedQuery) {
        // A changed Word/PowerPoint single file is laid out again; until then it has no hits and no hint.
        for (target, error) in outcome.errors where error is StaleFileLayout { relayOutChangedFile(target) }
        let errors = outcome.errors.filter { !($0.error is CancellationError) && !($0.error is StaleFileLayout)
            && !outcome.foundByName.contains($0.target) }
        if errors.isEmpty, outcome.errors.contains(where: { $0.error is CancellationError }) { return }
        // Hits of sources removed (or replaced) while the search ran are dropped.
        let loaded = Set(sourceList.items.map(\.url.path))
        var found = outcome.sorted.filter { loaded.contains($0.target) }.map(\.hit)
        if outcome.sort != settings.sort { found = sortHits(found, by: settings.sort) }   // changed meanwhile
        if errors.isEmpty {
            if let kind = noticeKind, [.noText, .unreadable, .unreadableImage, .noTextImage, .noTextPDF, .ocrOff, .layoutUnreadable, .noTextOffice].contains(kind) || Self.isSearchFailure(kind) { noticeKind = nil }
        }
        isBrowsing = false
        show(found, for: parsed, summary: .search)
        for (target, error) in errors where loaded.contains(target) {
            switch error {
            case IndexStoreError.corruptIndexRebuilt:
                setIndexProblem(target, .corruptIndex)
                // A running phase 1 of the folder restarts itself after a wipe; a recognition does not, and
                // a recognition of another folder must not delay the rebuild (review of 1.2 Task 1).
                if indexes[target] != nil, currentFolder != target || currentPhase == .ocr {
                    enqueueIndexing(target, trigger: "corrupt_rebuild")
                    startQueueIfNeeded()
                }
            case SingleDocumentSearchError.noText where fileLayouts[target] != nil:
                // Word/PowerPoint: waiting for its layout shows nothing yet; laid out without text says so.
                if case .laidOut? = fileLayouts[target] { noticeKind = .noTextOffice }
            case is TextSourceError where fileLayouts[target] != nil:
                noticeKind = .layoutUnreadable
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

    /// The folder filter and `extraFilters` (Ordnerleiste).
    private func folderFiltered(_ documents: [DocumentHit]) -> [DocumentHit] {
        var filters = DocumentFilters()
        filters.folder = folderFilter
        filters.others = extraFilters
        return filters.apply(documents)
    }

    /// Every grid filter, ANDed.
    private func filtered(_ documents: [DocumentHit]) -> [DocumentHit] {
        FileKindFilter(kinds: shownKinds).apply(folderFiltered(documents))
    }

    /// The kinds shown: those of a `typ:` shortcut in the search field (`KindQuery`) for this search,
    /// else „Dateitypen“. The menu setting is left as it is.
    private var shownKinds: Set<DocumentKind> { KindQuery.split(queryText).kinds ?? settings.fileKinds }

    /// The search field text without its `typ:` shortcut: what is searched.
    private var searchText: String { KindQuery.split(queryText).rest }

    /// Shows a new search or browse result (through the grid filters).
    private func show(_ newHits: [DocumentHit], for parsed: ParsedQuery, summary style: SummaryStyle, keepFocus: Bool = false) {
        allHits = newHits
        summaryStyle = style
        if parsed != query {                                  // another term: its first hit again (1.3.3)
            focusChosenByUser = false
            firstHitPending = true
        }
        query = parsed
        publishFiltered(keepFocus: keepFocus)
        // The term's final result (early rows keep the focus): its first hit, once.
        if style == .search, !keepFocus, firstHitPending {
            firstHitPending = false
            if !focusChosenByUser, let first = FocusNavigator.firstHit(in: hits) { setFocusByModel(first) }
        }
        scheduleHistoryCommit()
    }

    /// `hits` and `summary` from `allHits` through the grid filters, ANDed (the one place they apply, spec 1.3
    /// §8a): the folder filter and `extraFilters` (Ordnerleiste), then the file types. Counts are of the shown
    /// documents. A focused page no longer shown loses the focus. The selection is never filtered.
    func publishFiltered(keepFocus: Bool = false) {
        let inFolders = folderFiltered(allHits)
        let shown = FileKindFilter(kinds: shownKinds).apply(inFolders)
        hits = shown
        // Hidden by „Dateitypen“ only: a typed `typ:` asked for just those kinds (and its empty grid would
        // offer the menu's „Alle Dateitypen zeigen“, which cannot undo the typed shortcut).
        hiddenByFilter = KindQuery.split(queryText).kinds == nil ? inFolders.count - shown.count : 0
        switch summaryStyle {
        case .empty: summary = ""
        case .search:
            summary = ViewerText.withHidden(ViewerText.summary(hits: shown), hidden: hiddenByFilter)
            if wordPartsBusy, case .fts(_, .trigram)? = FTSQueryBuilder.plan(for: query) {
                summary += " · " + ViewerText.wordPartsSlow
            }
        case .browse:
            summary = ViewerText.withHidden(ViewerText.browseSummary(files: shown.count, pages: shown.reduce(0) { $0 + $1.pageCount }),
                                            hidden: hiddenByFilter)
        }
        onHitsPublished?(shown)
        if !keepFocus, focusedPage != nil, !FocusNavigator.contains(focusedPage, in: shown, showAllPages: settings.showAllPages) {
            setFocusByModel(nil)
        }
        refillEmptyPreview()
    }

    /// 1.3.3: a search with hits shows its first hit page in the large preview at once (the first document in
    /// the shown order and filters), as ↓ did before; the keyboard focus stays where it is (the search field).
    /// `show` sets it once per term, when the term's final result arrives (early rows of a slow search would
    /// swap the preview twice, review 2). Later results of the same term (indexing, recognition, the Finder,
    /// sort) leave a shown page alone, so the grid does not scroll away under the reader (review 1); only when
    /// the shown page is gone (filtered out, file removed) does the first hit fill the empty preview here.
    /// Each shown result is already debounced by the search (`typingDelay`). Browsing and no hits: as before.
    private func refillEmptyPreview() {
        guard focusedPage == nil, !firstHitPending, summaryStyle == .search, !query.isEmpty,
              let first = FocusNavigator.firstHit(in: hits) else { return }
        setFocusByModel(first)
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
        let typed = KindQuery.split(text)
        return !SearchHistory.clean(text).isEmpty
            && (typed.kinds != nil || !QueryParser.parse(typed.rest, partialWords: settings.partialWords).isEmpty)
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
        // Hidden hits count: a term whose hits the „Dateitypen“ filter hides is still a real search.
        guard historyArmed, !query.isEmpty, isQuery(term), !allHits.isEmpty, searchHistory.isEnabled else { return }
        historyTask?.cancel()
        let delay = historyDelay
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.queryText == term, !self.allHits.isEmpty else { return }
            self.historyArmed = false
            self.searchHistory.commit(term, viaPause: true)
        }
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.sort
            _ = settings.partialWords
            _ = settings.searchFileNames
            _ = settings.showAllPages
            _ = settings.fileKinds
            _ = ocrPreferences.recognizeText
            _ = ocrPreferences.includeImages
            _ = officePreferences.includeOffice
            _ = officePreferences.powerPointRenderer
            _ = officePreferences.fontSubstitution
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
        if OfficeRendering(officePreferences) != lastRendering {
            lastRendering = OfficeRendering(officePreferences)
            let previous = renderingTask, rendering = lastRendering
            renderingTask = Task { [weak self] in
                await previous?.value
                await self?.renderingChanged(to: rendering)
            }
        }
        // „Dateitypen“ (spec 1.3 §8a): the shown documents change at once, without a new search or indexing.
        if settings.fileKinds != lastFileKinds {
            lastFileKinds = settings.fileKinds
            rebuildFolderTree(files: browseFiles)          // the folder counts follow the filter
            publishFiltered()
        }
        // „Alle Seiten“ off: a focused page that is no longer shown moves to the nearest hit page.
        if let focused = focusedPage, !FocusNavigator.contains(focused, in: hits, showAllPages: settings.showAllPages) {
            setFocusByModel(FocusNavigator.nearestShown(to: focused, hits: hits, showAllPages: settings.showAllPages))
        }
        if settings.partialWords != lastPartialWords || settings.searchFileNames != lastSearchFileNames {
            lastPartialWords = settings.partialWords
            lastSearchFileNames = settings.searchFileNames
            lastSort = settings.sort
            scheduleSearch(debounced: false)
        } else if settings.sort != lastSort {
            lastSort = settings.sort
            // Same hits, no new query; sorted before the folder filter so a later filter change keeps the order.
            allHits = sortHits(allHits, by: isBrowsing ? ViewerText.browseSortMode(lastSort) : lastSort)
            publishFiltered(keepFocus: true)
        }
    }

// MARK: Output

    private var orderedSelection: [PageRef] {
        // Every document, also hidden ones: a ticked page of a hidden kind keeps its place (spec 1.3 §8a).
        selection.ordered(documentOrder: allHits.map(\.url))
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
            let foreign = self?.foreignPages
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Merger(foreign: foreign).write(refs, to: url) }
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
            let foreign = self.foreignPages
            // Built off the main actor: Word layout and slide decoding are slow (`Printer` doc comment).
            let built = await Task.detached(priority: .userInitiated) {
                Result { try PrintDocument.build(refs, foreign: foreign) }
            }.value
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
        let foreign = foreignPages
        saveTask = Task { [weak self] in
            await previous?.value
            let missing = await Task.detached(priority: .userInitiated) { Merger.unavailable(refs, foreign: foreign) }.value
            self?.selection.remove(missing)
        }
    }

    /// Double-click or „Original öffnen“: PDFs and images in Preview; Word/PowerPoint originals with the
    /// app macOS assigns to them (1.3 Teil B), never Microsoft Office by name.
    public func openInPreview(_ r: PageRef) {
        if DocumentKind(fileExtension: r.url.pathExtension)?.isOffice == true {
            environment.openWithDefaultApp(r.url)
        } else {
            environment.openInPreview(r.url)
        }
    }

    /// A laid-out PowerPoint tile without a slide picture. Checked off the main actor: a deck edited since it was
    /// indexed → its folder runs phase 1 again (which lays the changed deck out); otherwise, when the slide cache
    /// really has no entry → this deck is laid out again (`requestLayout(relativePath:)`, a single file waits again);
    /// the latter only under Quick Look (SlideKit has no slide cache).
    /// At most once per path and file version and session (tiles report up to once a second), so nothing loops.
    public func slidesMissing(for ref: PageRef) {
        guard DocumentKind(fileExtension: ref.url.pathExtension) == .powerpoint else { return }
        checkOfficeFile(ref.url.standardizedFileURL)
    }

    private static func relayoutKey(_ kind: String, _ path: String, _ stamp: FileStamp?) -> String {
        "\(kind)|\(path)|\(stamp?.size ?? -1)|\(stamp?.modifiedAt?.timeIntervalSince1970 ?? -1)"
    }

    /// See `slidesMissing(for:)`. Checks run one after another; a path already waiting for its check is skipped.
    private func checkOfficeFile(_ url: URL) {
        let path = url.path
        guard checksQueued.insert(path).inserted else { return }
        let previous = officeCheckTask
        let foreign = foreignPages
        officeCheckTask = Task { [weak self] in
            await previous?.value
            await self?.runOfficeCheck(url, foreign: foreign)
            self?.checksQueued.remove(path)
        }
    }

    private func runOfficeCheck(_ url: URL, foreign: (any ForeignPageProvider)?) async {
        let path = url.path
        // SlideKit draws slides on demand (no slide cache): a tile without a picture is an unreadable or changed deck,
        // not a cache miss; a new layout would not help. Only the changed-file check below applies.
        let slideCacheMiss = pageRenderers == nil || OfficeDisplay.usesSlideCache(officeRendering.value)
        if fileLayouts[path] != nil {
            // A single file: its own stamp says whether it changed (then it is laid out again anyway).
            let (stamp, slides) = await Task.detached(priority: .utility) { (FileStamp.of(url), slideCacheMiss ? foreign?.pageCount(of: url) : nil) }.value
            guard case .laidOut(_, let laidOut)? = fileLayouts[path], singleSearches[path] != nil else { return }
            if stamp != laidOut { relayOutChangedFile(path); return }
            guard slideCacheMiss, foreign != nil, slides == nil,
                  requestedRelayouts.insert(Self.relayoutKey("slides", path, stamp)).inserted else { return }
            requeueFileLayout(path)
            startQueueIfNeeded()
            return
        }
        guard let folder = folderSources.first(where: { path.hasPrefix($0.path + "/") }),
              let index = indexes[folder.path], foreign != nil else { return }
        let relative = String(path.dropFirst(folder.path.count + 1))
        // Under SlideKit only the changed-file check is left: once per path and file version (a stat first, so repeated
        // reports of an unreadable deck do not query the index each time).
        var checkedKey: String?
        if !slideCacheMiss {
            let current = await Task.detached(priority: .utility) { FileStamp.of(url) }.value
            let key = Self.relayoutKey("checked", path, current)
            guard !requestedRelayouts.contains(key) else { return }
            checkedKey = key
        }
        let (stamp, outdated, slides) = await Task.detached(priority: .utility) { () -> (FileStamp?, Bool, Int?) in
            let outdated = (try? index.isOutdated(relativePath: relative)) ?? false
            return (FileStamp.of(url), outdated, outdated || !slideCacheMiss ? nil : foreign?.pageCount(of: url))
        }.value
        guard indexes[folder.path] === index else { return }          // removed or replaced meanwhile
        if outdated {
            reindexOutdated(folder.path, index: index, path: path, stamp: stamp)
            return
        }
        if let checkedKey { requestedRelayouts.insert(checkedKey); return }    // SlideKit: unchanged, nothing to lay out
        let key = Self.relayoutKey("slides", path, stamp)
        guard slideCacheMiss, slides == nil, !requestedRelayouts.contains(key) else { return }   // checks run one at a time
        let requested = await Task.detached(priority: .utility) { Result { try index.requestLayout(relativePath: relative) } }.value
        guard indexes[folder.path] === index else { return }
        if case .failure(let error) = requested {
            // Not remembered: the next report of this version tries again.
            Self.log.error("Cannot queue \(path, privacy: .private) for layout: \(String(describing: error), privacy: .public)")
            return
        }
        requestedRelayouts.insert(key)
        guard officePreferences.includeOffice else { return }
        if currentFolder == folder.path, currentPhase == .layout {
            layoutAgain.insert(folder.path)          // the running layout fetched its work already
        } else if !layoutPending.contains(folder.path) {
            layoutPending.append(folder.path)
        }
        startQueueIfNeeded()
    }

    /// A file in `folder` differs from its stored version (folders are not watched): phase 1 again, which reads it
    /// anew and lays it out (Word: new word boxes, PowerPoint: new slides). Once per file version and session.
    private func reindexOutdated(_ folder: String, index: any FolderIndexing, path: String, stamp: FileStamp?) {
        guard indexes[folder] === index,
              requestedRelayouts.insert(Self.relayoutKey("index", path, stamp)).inserted else { return }
        enqueueIndexing(folder, trigger: "reindex_outdated")
        startQueueIfNeeded()
    }

    // MARK: Slide cache (1.3 Teil B Task 9)

    // MARK: Office's fonts (1.3.2 fonts-start)

    /// Starts the registration once (`officeFonts`, GCD utility queue); a success comes back as `fontsRegistered()`.
    /// Callable from any thread.
    private func fontStarter() -> @Sendable () -> Void {
        let fonts = officeFonts, prewarm = prewarmFonts, later = fontsCompleteLater
        return { [weak self] in
            let succeeded: @Sendable () -> Void = { Task { @MainActor in self?.fontsRegistered() } }
            fonts.start(prewarm, then: succeeded, otherwise: { later(succeeded) })
        }
    }

    /// A Word document or a deck under the own viewer (SlideKit) is shown in the grid or the preview (views call it
    /// on the main actor, never render threads): starts Office's font registration in the background, once, with
    /// „Word/PowerPoint“ on – after a restart with nothing to lay out nobody else would, and Word would be drawn with
    /// substitute fonts. While the user types, the start waits until the search field has been idle for
    /// `typingIdleDelay`, so the macOS prompt never comes mid-typing. PDFs, images and decks under Quick Look (it
    /// draws them itself) start nothing.
    public func officeDocumentShown(_ url: URL) {
        guard officePreferences.includeOffice, let kind = DocumentKind(fileExtension: url.pathExtension) else { return }
        switch kind {
        case .word:
            if !fontsAreRegistered { wordShownBeforeFonts = true }
        case .powerpoint:
            guard !OfficeDisplay.usesSlideCache(officeRendering.value) else { return }
            // office-speed: SlideKit tiles no longer wait for the registration either (substitutes until it is done).
            if !fontsAreRegistered { wordShownBeforeFonts = true }
        case .pdf, .image:
            return
        }
        guard !officeFonts.hasStarted, fontStartWaiter == nil else { return }
        guard typingIdleRemaining() != nil else { fontStarter()(); return }
        fontStartWaiter = Task { [weak self] in
            while let wait = self?.typingIdleRemaining() {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.fontStartWaiter = nil
            if self.officePreferences.includeOffice { self.fontStarter()() }
        }
    }

    /// How much longer the search field must stay idle; nil when it has been idle long enough (or never typed in).
    private func typingIdleRemaining() -> Duration? {
        guard let lastTyping else { return nil }
        let left = typingIdleDelay - (ContinuousClock.now - lastTyping)
        return left > .zero ? left : nil
    }

    /// At launch (the app, not its UI-test mode): when a registration once succeeded, start it now in the background
    /// – the prompt was answered before, and Word tiles need the fonts from the first one on.
    public func startOfficeFontsIfRegisteredBefore() {
        guard officePreferences.includeOffice, defaults.bool(forKey: Self.fontsRegisteredOnceKey) else { return }
        fontStarter()()
    }

    /// The registration succeeded (done in time, cloud fonts read): remembered for the next launches; Word tiles and
    /// the preview shown before are drawn again once (`foreignPagesRevision`: their tile keys carry the font state,
    /// `OfficePages.contentVersion`); Word documents laid out with substitute fonts are laid out again – single
    /// files at once, folders by a layout run (the Indexer requeues `TextKitWordSource.substituteRenderer`).
    func fontsRegistered() {
        guard !fontsAreRegistered else { return }
        fontsAreRegistered = true
        defaults.set(true, forKey: Self.fontsRegisteredOnceKey)
        if wordShownBeforeFonts, foreignPages != nil { foreignPagesRevision += 1 }
        guard officePreferences.includeOffice else { return }
        for source in sourceList.items where !source.isFolder && SingleFileLayout.officeKind(source.url) == .word {
            if case .laidOut(let result, _)? = fileLayouts[source.url.path], result.renderer == TextKitWordSource.substituteRenderer {
                requeueFileLayout(source.url.path)
            }
        }
        startQueueIfNeeded()
        let folders = folderSources.compactMap { url in indexes[url.path].map { (url.path, $0) } }
        guard !folders.isEmpty else { return }
        Task { [weak self] in
            let stale = await Task.detached(priority: .utility) {
                folders.filter { (try? $0.1.hasLayouts(byRenderer: TextKitWordSource.substituteRenderer)) ?? false }.map(\.0)
            }.value
            guard let self, self.officePreferences.includeOffice else { return }
            for path in stale where self.indexes[path] != nil {
                if self.currentFolder == path, self.currentPhase == .layout {
                    self.layoutAgain.insert(path)    // the running layout fetched its work already
                } else if !self.layoutPending.contains(path) {
                    self.layoutPending.append(path)
                }
            }
            self.startQueueIfNeeded()
        }
    }

    /// Unused slides are kept this long (use = a tile, preview or output read the entry).
    nonisolated static let slideCacheMaxAge: TimeInterval = 180 * 86_400
    /// A writer's `.tmp` folder unchanged this long belongs to a crashed run.
    nonisolated static let abandonedWriteAge: TimeInterval = 86_400
    /// Beyond this the least recently used slides go at app start, whatever their age (audit 2026-11-15).
    nonisolated static let slideCacheMaxBytes = 2 * 1024 * 1024 * 1024

    /// Once at app start (before `restoreSources`): removes Quick Look leftovers of crashed runs
    /// (`QuickLookHTML.sweepLeftovers()`), slide-cache entries unused for 180 days and `.tmp` folders of crashed
    /// writers, off the main actor. The queue starts no layout step before it is done. Errors are only logged.
    /// No Office font prewarm here (1.3.2): it starts with the first Word/PowerPoint layout or shown document
    /// (`prewarmFonts`), or at launch after an earlier success (`startOfficeFontsIfRegisteredBefore`, the app only).
    public func startMaintenance() {
        guard !maintenanceStarted else { return }
        maintenanceStarted = true
        let cache = slideCache, leftovers = quickLookLeftoverRoot, gate = maintenanceGate
        runCacheJob {
            await gate?()
            let now = Date()
            let swept = QuickLookHTML.sweepLeftovers(in: leftovers)
            do {
                let pruned = try cache.prune(notUsedSince: now.addingTimeInterval(-Self.slideCacheMaxAge))
                let oversize = try cache.prune(keepingAtMostBytes: Self.slideCacheMaxBytes)
                let abandoned = try cache.pruneAbandonedWrites(notChangedSince: now.addingTimeInterval(-Self.abandonedWriteAge))
                Self.log.info("Maintenance: \(swept) Quick Look leftovers, \(pruned) old and \(oversize) least recently used slide entries, \(abandoned) abandoned writes removed")
            } catch {
                Self.log.error("Slide cache maintenance failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// „Folien-Cache leeren“: stops a running layout (folder or single file) and waits for it, empties the slide
    /// cache off the main actor, then lays out every PowerPoint again (each folder `requestLayout(kind: .powerpoint)`,
    /// PowerPoint single files wait again, first) and starts the queue. A failure shows an alert.
    /// Under the own viewer (SlideKit) it only empties the cache.
    public func clearSlideCache() async {
        // Own viewer (SlideKit): the cache only holds old Quick Look pictures; clearing frees disk space and no layout
        // depends on it (no stop, no relayout).
        guard OfficeDisplay.usesSlideCache(officeRendering.value) else {
            let cache = slideCache
            if let failure = await runCacheJob({ do { try cache.clear(); return nil } catch { return error } }).value {
                Self.log.error("Clearing the slide cache failed: \(String(describing: failure), privacy: .public)")
                alertMessage = "Folien-Cache kann nicht geleert werden: \(failure.localizedDescription)"
            }
            return
        }
        // Reserved first: a queue started while the running layout stops must not begin a new layout (open writer).
        cacheJobs += 1
        if currentFolder != nil, currentPhase == .layout { await stopQueue() }   // no writer may be open
        let cache = slideCache
        let cleared = runCacheJob(reserved: true) {
            do { try cache.clear(); return nil } catch { return error }
        }
        var failure = await cleared.value
        let folders = folderSources.compactMap { url in indexes[url.path].map { (url.path, $0) } }
        let requested = await Task.detached(priority: .userInitiated) { () -> Error? in
            var first: Error?
            for (_, index) in folders {
                do { try index.requestLayout(kind: .powerpoint) } catch { first = first ?? error }
            }
            return first
        }.value
        failure = failure ?? requested
        if let failure {
            Self.log.error("Clearing the slide cache failed: \(String(describing: failure), privacy: .public)")
            alertMessage = "Folien-Cache kann nicht geleert werden: \(failure.localizedDescription)"
        }
        relayOutPowerPoint(folders)
    }

    /// „PowerPoint-Darstellung“ or „Fehlende Schriften“ changed (1.3 Teil B Task 12): hands the choice to the layout
    /// sources and, when the pages differ, replaces `foreignPages` (same `FontSubstitution` as the layout; the tile cache
    /// is rebuilt by the view) and drops SlideKit's open decks – only after the old PowerPoint words are gone (below).
    /// Only when that changes the PowerPoint renderer identity (`officeLayout.renderer(for: .powerpoint)`, name and version: SlideKit 101/102 by font, Quick Look's
    /// own): stops a running layout (its result belongs to the old renderer) and waits for it, removes the old pages of every
    /// PowerPoint in each folder (`adoptPowerPointRenderer()`: records the new renderer and drops the old pages in one
    /// transaction, so the next run does not reset again; no old word stays searchable, decks wait like new
    /// files), lets PowerPoint single files wait again (first) and starts the queue. Word is not affected (yet).
    private func renderingChanged(to rendering: OfficeRendering) async {
        let before = officeLayout.renderer(for: .powerpoint)
        let previous = officeRendering.value
        officeRendering.value = rendering
        let after = officeLayout.renderer(for: .powerpoint)
        guard before != after else { replacePages(from: previous, to: rendering); return }
        if currentFolder != nil, currentPhase == .layout { await stopQueue() }
        let folders = folderSources.compactMap { url in indexes[url.path].map { (url.path, $0) } }
        let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
            var first: Error?
            for (_, index) in folders {
                do { try index.adoptPowerPointRenderer() } catch { first = first ?? error }
            }
            return first
        }.value
        if let failure {
            Self.log.error("Resetting PowerPoint layouts failed: \(String(describing: failure), privacy: .public)")
            alertMessage = "PowerPoint-Dateien können nicht neu eingelesen werden: \(failure.localizedDescription)"
        }
        // Only now, with the old words gone: new drawing never pairs with old word boxes (same main-actor turn as the
        // single files' requeue in `relayOutPowerPoint`).
        replacePages(from: previous, to: rendering)
        relayOutPowerPoint(folders)
    }

    /// New `foreignPages` when `rendering` draws differently from `previous` (unless they were given to `init`); the
    /// views rebuild the tile cache and reload, SlideKit's open decks are dropped.
    private func replacePages(from previous: OfficeRendering, to rendering: OfficeRendering) {
        guard let pageRenderers, !OfficeDisplay.samePages(previous, rendering) else { return }
        foreignPages = OfficeDisplay.pages(for: rendering, cache: slideCache, renderers: pageRenderers)
        foreignPagesRevision += 1
        OfficeDisplay.releaseOpenDecks()
    }

    /// After the PowerPoint pages were dropped or reset: every folder (when Office is on) and every PowerPoint single
    /// file waits for its layout again; the tiles and the shown documents follow.
    private func relayOutPowerPoint(_ folders: [(String, any FolderIndexing)]) {
        if officePreferences.includeOffice {
            for (path, index) in folders where indexes[path] === index && !layoutPending.contains(path) {
                layoutPending.append(path)
            }
        }
        for source in sourceList.items where !source.isFolder && SingleFileLayout.officeKind(source.url) == .powerpoint {
            requeueFileLayout(source.url.path)
        }
        startQueueIfNeeded()
        bumpLayoutRevision()
        scheduleRefreshAfterRecognition()            // reset decks have no pages until laid out again
    }

    /// Runs `body` off the main actor after the previous slide-cache job; the queue's layout steps wait for it.
    /// - Returns: its error (nil = fine).
    @discardableResult
    /// - Parameter reserved: the caller already counted it in `cacheJobs`.
    private func runCacheJob(reserved: Bool = false, _ body: @escaping @Sendable () async -> Error?) -> Task<Error?, Never> {
        let previous = cacheWork
        let job = Task.detached(priority: .utility) { () -> Error? in
            await previous?.value
            return await body()
        }
        if !reserved { cacheJobs += 1 }
        cacheWork = Task { [weak self] in
            _ = await job.value
            self?.cacheJobs -= 1
            self?.wakeQueue()
        }
        return job
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
            let s = settingsTask, q = searchTask, i = indexTask, w = saveTask, r = rerunTask, a = addTask, t = treeTask
            let c = cacheWork, o = officeCheckTask, g = renderingTask, d = diskChangeTask
            await d?.value
            await a?.value
            await t?.value
            await g?.value
            await s?.value
            await r?.value
            await c?.value
            await o?.value
            await q?.value
            await i?.value
            await w?.value
            if s == settingsTask, q == searchTask, i == indexTask, w == saveTask, r == rerunTask, a == addTask, t == treeTask,
               c == cacheWork, o == officeCheckTask, g == renderingTask, d == diskChangeTask { return }
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

extension OfficeRendering {
    /// The settings UI's choices (ViewerUI's own enums, same raw values) as main's types (SlideKit wiring, 1.3.0).
    @MainActor init(_ preferences: OfficePreferences) {
        self.init(powerPointRawValue: preferences.powerPointRenderer.rawValue,
                  fontsRawValue: preferences.fontSubstitution.rawValue)
    }
}

/// Starts the Office font prewarm at most once, from any thread, on a GCD utility queue: not the main thread (a
/// macOS access prompt may hold it), not Swift's cooperative pool (`FontResolver.prewarm()` blocks). `succeeded`
/// runs (on that queue) when the prewarm answers true.
final class OfficeFontPrewarm: Sendable {
    private let started = Mutex(false)

    var hasStarted: Bool { started.withLock { $0 } }

    /// `otherwise` runs (on that queue) when it answers false.
    func start(_ prewarm: @escaping @Sendable () -> Bool, then succeeded: @escaping @Sendable () -> Void = {},
               otherwise: @escaping @Sendable () -> Void = {}) {
        let first = started.withLock { started in
            defer { started = true }
            return !started
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async { if prewarm() { succeeded() } else { otherwise() } }
    }
}
