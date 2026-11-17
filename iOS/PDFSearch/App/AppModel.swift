import Foundation
import Observation
import PDFSearchCore
import SwiftUI

/// A folder in the library with its live state.
struct FolderItem: Identifiable, Hashable {
    var record: FolderRecord
    /// Resolved, security-scoped URL (nil if the bookmark no longer resolves).
    var url: URL?
    var stats = FolderStats()
    var progress: IndexProgress?
    var isIndexing = false
    var lastError: String?

    var id: Int64 { record.id }
    var name: String { record.name }
}

/// A page (or photo) the user collected for printing or sharing.
struct SelectedPage: Identifiable, Hashable {
    let fileID: Int64
    let folderID: Int64
    let relativePath: String
    let kind: FileKind
    let pageNumber: Int

    var id: String { "\(fileID)-\(pageNumber)" }
    var name: String { (relativePath as NSString).lastPathComponent }
}

enum KindFilter: String, CaseIterable, Hashable {
    case all, pdf, jpeg

    var title: String {
        switch self {
        case .all: "Alle"
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        }
    }

    var kinds: Set<FileKind> {
        switch self {
        case .all: Set(FileKind.allCases)
        case .pdf: [.pdf]
        case .jpeg: [.jpeg]
        }
    }
}

/// Destinations inside the search tab.
enum SearchRoute: Hashable {
    case page(fileID: Int64, page: Int)
    case photo(fileID: Int64)
}

@MainActor
@Observable
final class AppModel {
    enum TabID: Hashable { case library, search, selection }

    // MARK: Navigation
    var tab: TabID = .library
    var searchPath: [SearchRoute] = []
    /// Incremented to ask the search field to take focus.
    var focusRequest = 0
    /// Incremented to ask the search screen to start voice input.
    var voiceRequest = 0

    // MARK: Library
    private(set) var folders: [FolderItem] = []
    private(set) var isLoaded = false
    var alertMessage: String?

    // MARK: Search
    var query = ""
    var scope: SearchScope = .everywhere
    var kindFilter: KindFilter = .all
    var sort: SortOrder = .hits
    /// true: only pages with hits (tiles, preview, page strip); false: all pages.
    var hitsOnly = true
    var previewOnTop: Bool {
        didSet { UserDefaults.standard.set(previewOnTop, forKey: Keys.previewOnTop) }
    }
    private(set) var result: SearchResult = .empty
    private(set) var isSearching = false
    private(set) var recentSearches: [String]

    /// The document and first page shown in the two-page preview.
    var previewFileID: Int64?
    var previewPage = 1

    // MARK: Selection
    var selection: [SelectedPage] = []

    // MARK: Engine
    let store: IndexStore
    private let indexer: Indexer
    private let searchService: SearchService
    private var searchTask: Task<Void, Never>?
    private var indexTasks: [Int64: Task<Void, Never>] = [:]

    private enum Keys {
        static let previewOnTop = "previewOnTop"
        static let recent = "recentSearches"
    }

    init() {
        let store: IndexStore
        do {
            store = try IndexStore(databaseURL: Self.databaseURL)
        } catch {
            // Should never happen; keep the app usable with an index that lives only in memory.
            store = try! IndexStore()
        }
        self.store = store
        self.indexer = Indexer(store: store)
        self.searchService = SearchService(store: store)
        let defaults = UserDefaults.standard
        self.previewOnTop = defaults.object(forKey: Keys.previewOnTop) as? Bool ?? true
        self.recentSearches = defaults.stringArray(forKey: Keys.recent) ?? []
    }

    static var databaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "PDFSearch/index.sqlite")
    }

    // MARK: - Loading folders

    func load() async {
        guard !isLoaded else { return }
        let records = (try? await store.folders()) ?? []
        var items: [FolderItem] = []
        for record in records {
            var item = FolderItem(record: record)
            do {
                let (url, refreshed) = try FolderAccess.resolve(record.bookmark)
                item.url = url
                if let refreshed { try? await store.updateBookmark(folderID: record.id, bookmark: refreshed) }
            } catch {
                item.lastError = "Kein Zugriff mehr. Ordner bitte neu hinzufügen."
            }
            item.stats = (try? await store.stats(folderID: record.id)) ?? FolderStats()
            items.append(item)
        }
        folders = items
        isLoaded = true
        refreshAll()
    }

    func refreshAllIfLoaded() {
        guard isLoaded else { return }
        refreshAll()
    }

    func refreshAll() {
        for folder in folders { reindex(folder.id) }
    }

    /// Adds a folder picked in the Files app and indexes it.
    func addFolder(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        if folders.contains(where: { $0.url?.standardizedFileURL.path == path }) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            alertMessage = "Der Ordner „\(url.lastPathComponent)“ ist schon in der Bibliothek."
            return
        }
        do {
            let bookmark = try FolderAccess.bookmark(for: url)
            let record = try await store.addFolder(name: url.lastPathComponent, bookmark: bookmark)
            folders.append(FolderItem(record: record, url: url))
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            reindex(record.id)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            alertMessage = "Der Ordner lässt sich nicht hinzufügen: \(error.localizedDescription)"
        }
    }

    func removeFolder(_ id: Int64) async {
        indexTasks[id]?.cancel()
        indexTasks[id] = nil
        if let url = folders.first(where: { $0.id == id })?.url {
            url.stopAccessingSecurityScopedResource()
        }
        try? await store.removeFolder(id: id)
        folders.removeAll { $0.id == id }
        selection.removeAll { $0.folderID == id }
        if scope == .folder(id) { scope = .everywhere }
        runSearch()
    }

    /// Starts downloading the cloud placeholders of a folder; they are indexed on the next refresh.
    func downloadMissing(in id: Int64) async {
        guard let root = folders.first(where: { $0.id == id })?.url else { return }
        let files = (try? await store.files(inFolder: id)) ?? []
        for file in files where file.state == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: root.appending(path: file.relativePath))
        }
        alertMessage = "Die Dateien werden geladen. Sobald sie auf dem iPhone sind, werden sie beim nächsten Öffnen der App oder durch Herunterziehen der Bibliothek durchsucht."
    }

    func reindex(_ id: Int64) {
        guard indexTasks[id] == nil,
              let index = folders.firstIndex(where: { $0.id == id }),
              let root = folders[index].url else { return }
        folders[index].isIndexing = true
        folders[index].lastError = nil
        let indexer = self.indexer
        // The model lives as long as the app, so strong captures are fine here.
        indexTasks[id] = Task {
            var failure: String?
            do {
                try await indexer.index(folderID: id, root: root) { progress in
                    Task { @MainActor in self.apply(progress) }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            await self.finishIndexing(id, error: failure)
        }
    }

    private func apply(_ progress: IndexProgress) {
        guard let index = folders.firstIndex(where: { $0.id == progress.folderID }), folders[index].isIndexing else { return }
        folders[index].progress = progress
    }

    private func finishIndexing(_ id: Int64, error: String?) async {
        indexTasks[id] = nil
        let stats = (try? await store.stats(folderID: id)) ?? FolderStats()
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isIndexing = false
        folders[index].progress = nil
        folders[index].stats = stats
        folders[index].lastError = error
        runSearch()
    }

    var isIndexingAnything: Bool { folders.contains { $0.isIndexing } }

    func folderName(_ id: Int64) -> String {
        folders.first { $0.id == id }?.name ?? ""
    }

    // MARK: - Search

    /// Searches again with the current query and settings (debounced).
    func runSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            result = .empty
            isSearching = false
            return
        }
        let request = SearchRequest(text: text, scope: scope, kinds: kindFilter.kinds, sort: sort)
        let service = searchService
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = (try? await service.search(request)) ?? .empty
            guard !Task.isCancelled else { return }
            self.result = found
            self.isSearching = false
            self.keepPreviewValid()
        }
    }

    /// Remembers the query in "Zuletzt gesucht" (called when the user submits or opens a hit).
    func rememberQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recentSearches.insert(text, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: Keys.recent)
    }

    func search(for text: String, scope: SearchScope = .everywhere) {
        query = text
        self.scope = scope
        searchPath.removeAll()
        tab = .search
        runSearch()
    }

    /// The blue "search everything" button.
    func startGlobalSearch() {
        scope = .everywhere
        searchPath.removeAll()
        tab = .search
        focusRequest += 1
        runSearch()
    }

    func searchInFolder(_ id: Int64) {
        scope = .folder(id)
        searchPath.removeAll()
        tab = .search
        focusRequest += 1
        runSearch()
    }

    func startVoiceSearch() {
        searchPath.removeAll()
        tab = .search
        voiceRequest += 1
    }

    var scopeTitle: String {
        switch scope {
        case .everywhere: "Ganzes iPhone"
        case .folder(let id): folderName(id)
        }
    }

    // MARK: - Pages shown for a document

    func document(_ fileID: Int64) -> DocumentHit? {
        result.documents.first { $0.fileID == fileID }
    }

    /// Page numbers shown for a document: only hit pages or all pages.
    func visiblePages(of document: DocumentHit) -> [Int] {
        guard !hitsOnly, document.kind == .pdf, document.pageCount > 0 else { return document.hitPageNumbers }
        return Array(1...document.pageCount)
    }

    func url(folderID: Int64, relativePath: String) -> URL? {
        folders.first { $0.id == folderID }?.url?.appending(path: relativePath)
    }

    func url(of document: DocumentHit) -> URL? {
        url(folderID: document.folderID, relativePath: document.relativePath)
    }

    // MARK: - Two-page preview

    var previewDocument: DocumentHit? {
        previewFileID.flatMap { document($0) } ?? result.pdfDocuments.first
    }

    /// The two pages shown side by side.
    var previewPages: [Int] {
        guard let document = previewDocument else { return [] }
        let pages = visiblePages(of: document)
        guard let start = pages.firstIndex(of: previewPage) ?? pages.indices.first else { return [] }
        return Array(pages[start..<min(start + 2, pages.count)])
    }

    func showInPreview(_ fileID: Int64, page: Int) {
        previewFileID = fileID
        previewPage = page
    }

    func stepPreview(by direction: Int) {
        guard let document = previewDocument else { return }
        let pages = visiblePages(of: document)
        guard let current = pages.firstIndex(of: previewPage) else { return }
        let next = min(max(current + direction * 2, 0), max(pages.count - 1, 0))
        previewPage = pages[next]
    }

    private func keepPreviewValid() {
        if let document = previewFileID.flatMap({ self.document($0) }), visiblePages(of: document).contains(previewPage) { return }
        if let first = result.pdfDocuments.first {
            previewFileID = first.fileID
            previewPage = first.pages.first?.number ?? 1
        } else {
            previewFileID = nil
        }
    }

    func hitsOnlyChanged() {
        keepPreviewValid()
    }

    // MARK: - Selection

    func isSelected(fileID: Int64, page: Int) -> Bool {
        selection.contains { $0.fileID == fileID && $0.pageNumber == page }
    }

    func toggleSelection(_ document: DocumentHit, page: Int) {
        if let index = selection.firstIndex(where: { $0.fileID == document.fileID && $0.pageNumber == page }) {
            selection.remove(at: index)
        } else {
            selection.append(SelectedPage(fileID: document.fileID, folderID: document.folderID,
                                          relativePath: document.relativePath, kind: document.kind, pageNumber: page))
        }
    }

    func composeItems() -> [ComposeItem] {
        selection.compactMap { item in
            url(folderID: item.folderID, relativePath: item.relativePath)
                .map { ComposeItem(url: $0, kind: item.kind, pageNumber: item.pageNumber) }
        }
    }
}
