import Foundation
import IndexKit
import Observation
import OCRKit
import SearchKit
import UIKit

enum KindFilter: String, CaseIterable, Identifiable {
    case all, pdf, jpeg
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Alle"
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        }
    }
}

enum ResultSort: String, CaseIterable, Identifiable {
    case matchCount, name, date
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matchCount: "Trefferanzahl"
        case .name: "Name"
        case .date: "Datum"
        }
    }
    var mode: SortMode {
        switch self {
        case .matchCount: .matchCount
        case .name: .fileName
        case .date: .modifiedDate
        }
    }
}

/// A folder chosen in the tree: a place, and a folder path relative to it ("" = the whole place).
struct FolderSelection: Hashable, Sendable {
    let placeID: UUID
    let relativePath: String
}

/// A file that could not be read or downloaded.
struct UnreadableFile: Identifiable, Hashable {
    let id = UUID()
    let place: String
    let path: String
    let reason: String
}

/// What the big preview shows: a hit and the page to start on.
struct PreviewTarget: Equatable {
    let hit: DocumentHit
    let page: Int
    /// Changes on every tap, so tapping the same tile again jumps back to it.
    let token: UUID
}

@MainActor
@Observable
final class AppModel {
    // Places and index
    private(set) var places: [PlaceRuntime] = []
    private(set) var placeErrors: [String] = []
    private(set) var isIndexing = false
    private(set) var indexStatus = "Noch nicht indiziert"
    private(set) var progressText = ""
    private(set) var progressFraction: Double?
    private(set) var unreadable: [UnreadableFile] = []
    private(set) var documentCount = 0
    private(set) var lastIndexed: Date?

    // Search
    var query = "" { didSet { scheduleSearch() } }
    var wholeIPad = false { didSet { scheduleSearch() } }
    var kindFilter: KindFilter = .all { didSet { scheduleSearch() } }
    var sort: ResultSort = .matchCount { didSet { scheduleSearch() } }
    var selection: FolderSelection? { didSet { scheduleSearch() } }
    private(set) var hits: [DocumentHit] = []
    private(set) var parsedQuery = ParsedQuery(terms: [])
    private(set) var isSearching = false
    var preview: PreviewTarget?

    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The index run was stopped because the app went to the background; it continues on return.
    private(set) var interrupted = false

    init() {
        // UI tests: start from the default view settings (before any view reads them).
        if UserDefaults.standard.bool(forKey: "uiTestResetSettings") {
            for key in [SettingsKey.showFolderTree, SettingsKey.previewOnLeft, SettingsKey.tileSize] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: Start

    func start() async {
        if DemoFiles.isRequested {
            do { try DemoFiles.install() } catch { placeErrors.append("Testdateien: \(error.localizedDescription)") }
        }
        loadPlaces()
        if let demo = UserDefaults.standard.string(forKey: "demoQuery"), !demo.isEmpty {
            await reindex()
            query = demo
        } else {
            await reindex()
        }
    }

    private func loadPlaces() {
        var stored = PlaceStorage.load()
        var runtimes: [PlaceRuntime] = []
        var errors: [String] = []
        let builtIn = SharedPlace(id: SharedPlace.builtInID, name: "Auf diesem iPad", bookmark: nil)
        if let runtime = PlaceStorage.resolve(builtIn).runtime { runtimes.append(runtime) }
        var changed = false
        for (i, place) in stored.enumerated() {
            let resolved = PlaceStorage.resolve(place)
            if let refreshed = resolved.refreshed { stored[i] = refreshed; changed = true }
            if let runtime = resolved.runtime {
                runtimes.append(runtime)
            } else {
                errors.append("\(place.name): \(resolved.error ?? "nicht erreichbar")")
            }
        }
        if changed { PlaceStorage.save(stored) }
        places = runtimes
        placeErrors = errors
    }

    var userPlaces: [PlaceRuntime] { places.filter { $0.place.bookmark != nil } }

    func addFolders(_ urls: [URL]) {
        var stored = PlaceStorage.load()
        for url in urls {
            guard let place = try? PlaceStorage.makePlace(from: url) else {
                placeErrors.append("\(url.lastPathComponent): Freigabe konnte nicht gespeichert werden")
                continue
            }
            stored.append(place)
        }
        PlaceStorage.save(stored)
        loadPlaces()
        Task { await reindex() }
    }

    func removePlace(_ id: UUID) {
        guard id != SharedPlace.builtInID else { return }
        if let runtime = places.first(where: { $0.id == id }) { try? runtime.store?.deleteIndex() }
        PlaceStorage.save(PlaceStorage.load().filter { $0.id != id })
        if selection?.placeID == id { selection = nil }
        loadPlaces()
        scheduleSearch()
    }

    // MARK: Indexing

    /// Indexes all places in the foreground: iCloud downloads, text, word parts, text recognition.
    func reindex() async {
        if let indexTask { await indexTask.value; return }
        let task = Task { await runIndex() }
        indexTask = task
        await task.value
        indexTask = nil
    }

    private func runIndex() async {
        isIndexing = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isIndexing = false
            UIApplication.shared.isIdleTimerDisabled = false
            progressFraction = nil
            progressText = ""
        }
        var problems: [UnreadableFile] = []
        for runtime in places {
            if Task.isCancelled { break }
            guard let store = runtime.store else {
                problems.append(UnreadableFile(place: runtime.place.name, path: "–", reason: "Index nicht zu öffnen: \(runtime.openError ?? "")"))
                continue
            }
            let name = runtime.place.name
            let root = runtime.url
            progressText = "\(name): iCloud-Dateien prüfen …"
            progressFraction = nil
            let pending = await Task.detached { ICloudPlaceholders.pending(below: root) }.value
            if !pending.isEmpty {
                let missing = await ICloudPlaceholders.download(pending) { done, total in
                    Task { @MainActor in
                        self.progressText = "\(name): iCloud-Dateien laden (\(done) von \(total))"
                        self.progressFraction = total > 0 ? Double(done) / Double(total) : nil
                    }
                }
                for url in missing {
                    problems.append(UnreadableFile(place: name, path: Self.relative(url, to: root), reason: "iCloud-Datei nicht geladen"))
                }
            }
            let indexer = Indexer(root: root, store: store,
                                  scanner: FolderScanner(includeImages: true, imageExtensions: SupportedSourceTypes.iPadImageExtensions),
                                  ocr: VisionOCRSource(),
                                  ocrSettings: OCRSettings(recognizeText: true, includeImages: true))
            let progress: @Sendable (IndexProgress) -> Void = { p in
                Task { @MainActor in self.show(p, place: name) }
            }
            do {
                let report = try await indexer.update(progress: progress)
                _ = try await indexer.buildWordParts(progress: progress)
                problems += report.failed.map { UnreadableFile(place: name, path: $0, reason: "nicht lesbar") }
                problems += report.ocr.failed.map { UnreadableFile(place: name, path: $0, reason: "Texterkennung fehlgeschlagen") }
            } catch is CancellationError {
                break
            } catch {
                problems.append(UnreadableFile(place: name, path: "–", reason: "Indizieren abgebrochen: \(error.localizedDescription)"))
            }
            if let docs = try? store.documents() {
                let known = Set(problems.filter { $0.place == name }.map(\.path))
                for doc in docs where doc.status == .error && !known.contains(doc.relativePath) {
                    problems.append(UnreadableFile(place: name, path: doc.relativePath, reason: "nicht lesbar"))
                }
            }
        }
        unreadable = problems
        if !Task.isCancelled { lastIndexed = Date() }
        refreshCounts()
        scheduleSearch(immediately: true)
    }

    // MARK: Background

    /// The app went to the background: iPadOS gives a running index some seconds more, then the run stops
    /// (everything stored so far stays) and continues when the app is active again.
    func enteredBackground() {
        guard isIndexing, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Indizieren") { [weak self] in
            MainActor.assumeIsolated { self?.stopForBackground() }
        }
    }

    func becameActive() {
        endBackgroundTask()
        if interrupted {
            interrupted = false
            Task { await reindex() }
        }
    }

    private func stopForBackground() {
        if isIndexing {
            interrupted = true
            indexTask?.cancel()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func show(_ p: IndexProgress, place: String) {
        guard isIndexing else { return }
        let phase = switch p.phase {
        case .text: "Text lesen"
        case .ocr: "Texterkennung"
        case .wordParts: "Wortteil-Index"
        case .layout: "Layout"
        }
        var text = "\(place): \(phase) \(p.done) von \(p.total)"
        if let file = p.currentFile { text += " – \((file as NSString).lastPathComponent)" }
        progressText = text
        progressFraction = p.total > 0 ? min(1, Double(p.done) / Double(p.total)) : nil
    }

    private func refreshCounts() {
        documentCount = places.reduce(0) { $0 + ((try? $1.store?.documents().count) ?? 0) }
        let time = lastIndexed.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–"
        indexStatus = interrupted
            ? "\(documentCount) Dateien im Index · unterbrochen, wird fortgesetzt"
            : "\(documentCount) Dateien im Index · Stand \(time)"
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    // MARK: Search

    func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let text = query
        let parsed = QueryParser.parse(text, partialWords: false)
        let targets: [(UUID, IndexStore, URL)] = places.compactMap { r in r.store.map { (r.id, $0, r.url) } }
        let selection = SearchScope.effectiveSelection(self.selection, wholeIPad: wholeIPad)
        let kind = kindFilter
        let sortMode = sort.mode
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            guard !parsed.isEmpty else {
                self.parsedQuery = parsed
                self.hits = []
                self.preview = nil
                return
            }
            self.isSearching = true
            let found = await Task.detached(priority: .userInitiated) { () -> [DocumentHit] in
                var all: [DocumentHit] = []
                for (id, store, root) in targets where SearchScope.includes(place: id, selection: selection) {
                    guard let hits = try? SearchService(index: store, root: root).search(parsed, sort: sortMode, searchNames: true) else { continue }
                    all += hits
                }
                return SearchScope.filter(all, kind: kind, selection: selection)
            }.value
            guard !Task.isCancelled else { return }
            self.parsedQuery = parsed
            self.hits = sortHits(found, by: sortMode)
            self.isSearching = false
            if let current = self.preview, let updated = self.hits.first(where: { $0.id == current.hit.id }) {
                self.preview = PreviewTarget(hit: updated, page: current.page, token: current.token)
            } else if let first = self.hits.first {
                self.preview = PreviewTarget(hit: first, page: first.pageHits.first?.pageIndex ?? 0, token: UUID())
            } else {
                self.preview = nil
            }
        }
    }

    func show(_ hit: DocumentHit, page: Int) {
        preview = PreviewTarget(hit: hit, page: page, token: UUID())
    }

    /// The store of the place a hit came from (for the OCR word boxes of images).
    func store(for hit: DocumentHit) -> IndexStore? {
        places.first { $0.url.standardizedFileURL == hit.sourceRoot.standardizedFileURL }?.store
    }

    var selectionTitle: String {
        if wholeIPad { return "Ganzes iPad (alle freigegebenen Orte)" }
        guard let selection, let place = places.first(where: { $0.id == selection.placeID }) else { return "Alle freigegebenen Orte" }
        return selection.relativePath.isEmpty ? place.place.name : "\(place.place.name) › \(selection.relativePath.replacingOccurrences(of: "/", with: " › "))"
    }
}

/// Which places and hits a search covers: „Ganzes iPad“ ignores the tree selection; a selected folder
/// keeps its own place and the files below it; the type filter keeps PDF or JPEG.
enum SearchScope {
    static func effectiveSelection(_ selection: FolderSelection?, wholeIPad: Bool) -> FolderSelection? {
        wholeIPad ? nil : selection
    }

    static func includes(place: UUID, selection: FolderSelection?) -> Bool {
        selection.map { $0.placeID == place } ?? true
    }

    static func filter(_ hits: [DocumentHit], kind: KindFilter, selection: FolderSelection?) -> [DocumentHit] {
        hits.filter { hit in
            switch kind {
            case .all: break
            case .pdf: guard hit.kind == .pdf else { return false }
            case .jpeg: guard hit.kind == .image else { return false }
            }
            guard let selection, !selection.relativePath.isEmpty else { return true }
            return hit.relativePath.hasPrefix(selection.relativePath + "/")
        }
    }
}

extension DocumentHit {
    var displayName: String { (relativePath as NSString).lastPathComponent }
    /// Pages shown as tiles: pages with hits, or the first page for a hit by name only.
    var tilePages: [Int] { pageHits.isEmpty ? [0] : pageHits.map(\.pageIndex) }
}
