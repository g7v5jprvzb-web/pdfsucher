// ViewerModel.swift — Task 4.3 (protocol and status shared with the app)
import Foundation
import Observation
import OutputKit
import SearchKit

/// Class-bound so views holding `any ViewerModel` can mutate it; use `Binding(get:set:)` (not `@Bindable`) on the existential.
@MainActor public protocol ViewerModel: AnyObject, Observable {
    var queryText: String { get set }
    var hits: [DocumentHit] { get }
    var query: ParsedQuery { get }
    var selection: PageSelection { get set }
    var focusedPage: PageRef? { get set }
    /// The focused page was shown by the model itself (the first hit of a search, 1.3.3), not chosen by the user:
    /// the first ↓ from the search field enters the grid on it instead of moving on. Default false.
    var focusIsAutomatic: Bool { get }
    var settings: GridSettings { get }
    /// Zoom of the large page view (spec 1.1 §2, §13).
    var previewZoom: PreviewZoom { get }
    /// Type-to-search, Tab order and the chosen shortcuts (spec 1.1 §7, §9, §10).
    var keyboard: KeyboardSettings { get }
    /// Text recognition settings (spec 1.2 §7).
    var ocrPreferences: OCRPreferences { get }
    /// Word/PowerPoint setting „office.include“ (spec 1.3).
    var officePreferences: OfficePreferences { get }
    /// Pages of Word/PowerPoint files for tiles, preview and output (1.3 Teil B; the app passes `OfficeDisplay.pages`:
    /// SlideKit's or Quick Look's PowerPoint pages); nil = none.
    var foreignPages: (any ForeignPageProvider)? { get }
    /// Rises when `foreignPages` was replaced (another „PowerPoint-Darstellung“ / „Fehlende Schriften“): the tile cache
    /// holding the old provider is rebuilt and the shown preview loads again. Default 0 (never replaced).
    var foreignPagesRevision: Int { get }
    /// Status ✕ „Texterkennung anhalten“ (spec 1.2 §3: cancellable, finished pages kept).
    func stopRecognition()
    /// ✕ was pressed: phase 2 waits until „Fortsetzen“, a new source or the next start.
    var isRecognitionStopped: Bool { get }
    func resumeRecognition()
    /// Stored text and word boxes of an OCR page (spec 1.2 §5), nil for a page with a text layer.
    func ocrText(for page: PageRef) async -> OCRPageText?
    var indexStatus: IndexStatus { get }
    /// Rises when newly laid-out Word/PowerPoint pages are stored (at most once a second during a layout run,
    /// and at the end of every run), so views showing those documents can reload them (spec 1.3).
    var layoutRevision: Int { get }
    var summary: String { get }
    /// The search field is empty and `hits` lists every file of every source (spec 1.1 §12).
    var isBrowsing: Bool { get }
    /// Documents of the current result hidden by the „Dateitypen“ filter (spec 1.3 §8a); 0 = none.
    var hiddenByFilter: Int { get }
    /// A search is running (spec §4.2: „Suche läuft…“ for slow searches).
    var isSearching: Bool { get }
    /// A short hint shown next to the index status (e.g. damaged index, PDF without text); nil = none.
    var notice: String? { get }
    /// Text of an error alert (e.g. saving failed); the view sets it to nil when dismissed.
    var alertMessage: String? { get set }
    /// The alert offers „Fehlende Seiten aus Auswahl entfernen“ (ticked pages whose file is gone).
    var alertOffersRemovingMissingPages: Bool { get }
    func removeMissingPagesFromSelection()
    /// The print document is being built; „Drucken …“ is disabled and „Druck wird vorbereitet…“ shown.
    var isPreparingPrint: Bool { get }
    /// The loaded sources (spec 1.1 §4), in the order they were added.
    var sources: [LoadedSourceRef] { get }
    /// ⌘O: choose folders and PDFs (several at once) and add them.
    func openSources()
    /// Adds opened or dropped items; folders and PDFs become sources, other files are ignored with a hint.
    func addSources(_ urls: [URL])
    /// 1.2.2 §1: the last search terms; `noteSearchArrived` saves the current one, `chooseHistoryEntry` searches one.
    var searchHistory: SearchHistory { get }
    func noteSearchArrived()
    func chooseHistoryEntry(_ term: String)
    /// Ordnerleiste: the folders of the sources, the chosen ones, the header text, the bar's visibility/width.
    var folderTree: [FolderNode] { get }
    var folderFilter: FolderFilter { get }
    var filterHeader: String? { get }
    var folderBar: FolderBarSettings { get }
    func selectFolder(_ folder: URL, adding: Bool)
    func selectSingleFiles(adding: Bool)
    func clearFolderFilter()
    func setFolderFilter(_ filter: FolderFilter)
    func openPlace(_ folder: URL) async
    /// Context menu „Index neu aufbauen“ of a source folder (asks first, like „Index löschen …“).
    func requestDeleteIndex(for source: URL?)
    /// 1.2.1 §1: the „hinzufügen?“ sheet while it is shown.
    var addPrompt: AddPrompt? { get }
    func answerAddPrompt(_ choice: AddChoice, remember: Bool)
    func removeSource(_ url: URL)
    func removeAllSources()
    func printSelection()
    func saveSelection()
    func openInPreview(_ r: PageRef)
    /// A tile of a laid-out PowerPoint (page count > 0) shows „Vorschau wird vorbereitet …“: its slide pictures are
    /// missing from the slide cache (cleared, pruned). The app lays the file out again (1.3 Teil B Task 9). Called on
    /// every load of such a tile; the app must deduplicate.
    func slidesMissing(for ref: PageRef)
    /// A Word/PowerPoint document is shown in the grid (its row appeared) or the preview (1.3.2: the app starts
    /// Office's font registration in the background, deferred while the user types). Main actor; default nothing.
    func officeDocumentShown(_ url: URL)
}

extension ViewerModel {
    public var foreignPagesRevision: Int { 0 }
    public var focusIsAutomatic: Bool { false }
    public func officeDocumentShown(_ url: URL) {}
}

public enum IndexStatus: Equatable {
    /// `building`: folder `folder` of `folders` is being indexed (spec 1.1 §4), `done` of `total` files.
    /// `recognizing`: text recognition (spec 1.2 §3) of folder `folder` of `folders`, `done` of `total` pages.
    /// `layingOut`: layout of Word/PowerPoint documents (spec 1.3) of folder `folder` of `folders`, `done` of `total` files.
    case none, building(folder: Int, folders: Int, done: Int, total: Int), recognizing(folder: Int, folders: Int, done: Int, total: Int)
    case layingOut(folder: Int, folders: Int, done: Int, total: Int)
    /// `preparingWordParts` (1.3.12): the trigram index of folder `folder` of `folders` is filled, `done` of `total` pages.
    case preparingWordParts(folder: Int, folders: Int, done: Int, total: Int)
    case upToDate, problems(failed: [String], noText: [String]), unreachable
}
