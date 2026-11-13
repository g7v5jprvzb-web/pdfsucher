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
    var settings: GridSettings { get }
    /// Zoom of the large page view (spec 1.1 §2, §13).
    var previewZoom: PreviewZoom { get }
    /// Type-to-search, Tab order and the chosen shortcuts (spec 1.1 §7, §9, §10).
    var keyboard: KeyboardSettings { get }
    /// Text recognition settings (spec 1.2 §7).
    var ocrPreferences: OCRPreferences { get }
    /// Status ✕ „Texterkennung anhalten“ (spec 1.2 §3: cancellable, finished pages kept).
    func stopRecognition()
    /// ✕ was pressed: phase 2 waits until „Fortsetzen“, a new source or the next start.
    var isRecognitionStopped: Bool { get }
    func resumeRecognition()
    /// Stored text and word boxes of an OCR page (spec 1.2 §5), nil for a page with a text layer.
    func ocrText(for page: PageRef) async -> OCRPageText?
    var indexStatus: IndexStatus { get }
    var summary: String { get }
    /// The search field is empty and `hits` lists every file of every source (spec 1.1 §12).
    var isBrowsing: Bool { get }
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
    /// 1.2.1 §1: the „hinzufügen?“ sheet while it is shown.
    var addPrompt: AddPrompt? { get }
    func answerAddPrompt(_ choice: AddChoice, remember: Bool)
    func removeSource(_ url: URL)
    func removeAllSources()
    func printSelection()
    func saveSelection()
    func openInPreview(_ r: PageRef)
}

public enum IndexStatus: Equatable {
    /// `building`: folder `folder` of `folders` is being indexed (spec 1.1 §4), `done` of `total` files.
    /// `recognizing`: text recognition (spec 1.2 §3) of folder `folder` of `folders`, `done` of `total` pages.
    case none, building(folder: Int, folders: Int, done: Int, total: Int), recognizing(folder: Int, folders: Int, done: Int, total: Int)
    case upToDate, problems(failed: [String], noText: [String]), unreachable
}
