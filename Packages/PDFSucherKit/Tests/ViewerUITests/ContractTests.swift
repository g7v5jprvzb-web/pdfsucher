import Testing
import Foundation
import Observation
import OutputKit
import SearchKit
import ViewerUI // deliberately not @testable: proves ViewerModel is implementable cross-module

@MainActor @Observable
private final class ContractViewerModel: ViewerModel {
    var queryText = ""
    var hits: [DocumentHit] = []
    var query = ParsedQuery(terms: [])
    var selection = PageSelection()
    var focusedPage: PageRef?
    let settings: GridSettings
    init(defaults: UserDefaults) { settings = GridSettings(defaults: defaults) }
    var indexStatus: IndexStatus = .none
    var summary = ""
    var isSearching = false
    var isBrowsing = false
    let previewZoom = PreviewZoom()
    let ocrPreferences = OCRPreferences(defaults: UserDefaults(suiteName: "PDFSucher.Sample.OCR") ?? .standard)
    func stopRecognition() {}
    var isRecognitionStopped = false
    func resumeRecognition() {}
    func ocrText(for page: PageRef) async -> OCRPageText? { nil }
    let keyboard = KeyboardSettings(defaults: UserDefaults(suiteName: "PDFSucher.Sample.Keys") ?? .standard)
    var notice: String?
    var alertMessage: String?
    var alertOffersRemovingMissingPages = false
    func removeMissingPagesFromSelection() {}
    var isPreparingPrint = false
    var sources: [LoadedSourceRef] = []
    func openSources() {}
    func addSources(_ urls: [URL]) {}
    let searchHistory = SearchHistory(defaults: UserDefaults(suiteName: "Sample-\(UUID())")!)
    func noteSearchArrived() {}
    func chooseHistoryEntry(_ term: String) { queryText = term }
    var addPrompt: AddPrompt?
    func answerAddPrompt(_ choice: AddChoice, remember: Bool) {}
    func removeSource(_ url: URL) {}
    func removeAllSources() {}
    func printSelection() {}
    func saveSelection() {}
    func openInPreview(_ r: PageRef) {}
}

@Suite("ViewerUI public contract")
@MainActor
struct ViewerUIContractTests {
    @Test func contentShellAcceptsAnyViewerModel() {
        withTempDefaults { defaults in
            _ = ContentShell(model: ContractViewerModel(defaults: defaults))
        }
        #expect(IndexStatus.building(folder: 1, folders: 1, done: 1, total: 2) != .upToDate)
    }

    /// Phase 4 views hold `any ViewerModel` and must be able to mutate it (search field, checkboxes).
    @Test func modelIsMutableThroughExistential() {
        withTempDefaults { defaults in
            let model: any ViewerModel = ContractViewerModel(defaults: defaults)
            let ref = PageRef(url: URL(fileURLWithPath: "/tmp/a.pdf"), pageIndex: 0)
            model.queryText = "Vertrag"
            model.focusedPage = ref
            model.selection.toggle(ref)
            #expect(model.queryText == "Vertrag")
            #expect(model.focusedPage == ref)
        }
    }

    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PDFSucher.ContractTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
