import Foundation
import IndexKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Ordnerleiste in the app model: the tree comes from the document list, a folder filters browsing and
/// search, places add a folder through the add prompt and then filter.
@MainActor @Suite("Folder filter in the app", .timeLimit(.minutes(1)))
struct FolderFilterAppTests {
    let base: URL
    let akten: URL, belege: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        akten = base.appendingPathComponent("Akten", isDirectory: true)
        belege = base.appendingPathComponent("Belege", isDirectory: true)
        for dir in [akten, belege] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func entry(_ path: String, in root: URL, pages: [Int] = []) -> DocumentHit {
        DocumentHit(url: root.appendingPathComponent(path), relativePath: path, modifiedAt: .distantPast,
                    pageHits: pages.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: pages.count,
                    relevance: 0, sourceRoot: root, pageCount: 3)
    }

    func model(_ indexes: [String: FakeIndex]) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Folder-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), debounce: .zero,
                 openIndex: { root in
                     guard let index = indexes[root.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
                     return index
                 })
    }

    func names(_ m: AppModel) -> [String] { m.hits.map(\.relativePath) }

    func akteIndex() -> FakeIndex {
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Verträge/2024/v1.pdf", in: akten), entry("Verträge/v0.pdf", in: akten)]
        index.hits = [entry("a.pdf", in: akten, pages: [0]), entry("Verträge/2024/v1.pdf", in: akten, pages: [1])]
        return index
    }

    @Test func treeComesFromTheDocumentList() async {
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        #expect(m.folderTree.map(\.name) == ["Akten"])
        #expect(m.folderTree.first?.fileCount == 3)
        #expect(m.folderTree.first?.children.map(\.name) == ["Verträge"])
    }

    /// The folder counts follow „Dateitypen“; the folders stay.
    @Test func folderCountsFollowTheFileKindFilter() async {
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Folien/f1.pptx", in: akten), entry("Folien/2024/f2.pptx", in: akten),
                            entry("Verträge/v1.pdf", in: akten), entry("Verträge/v2.docx", in: akten)]
        let m = model(["Akten": index])
        await m.add([akten])
        await m.waitUntilIdle()
        func counts() -> [String] {
            guard let root = m.folderTree.first else { return [] }
            return ["\(root.name) \(root.fileCount)"] + root.children.map { "\($0.name) \($0.fileCount)" }
        }
        #expect(counts() == ["Akten 5", "Folien 2", "Verträge 2"])
        m.settings.fileKinds = [.powerpoint]
        await m.waitUntilIdle()
        #expect(counts() == ["Akten 2", "Folien 2", "Verträge 0"])
        m.settings.fileKinds = Set(GridSettings.allFileKinds)
        await m.waitUntilIdle()
        #expect(counts() == ["Akten 5", "Folien 2", "Verträge 2"])
    }

    @Test func folderFiltersBrowsingAndSearch() async {
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        #expect(Set(names(m)) == ["Verträge/2024/v1.pdf", "Verträge/v0.pdf"], "browsing: all files of the folder")
        #expect(m.filterHeader == "Ordner: Akten › Verträge (2 Dateien)")
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(names(m) == ["Verträge/2024/v1.pdf"], "search: only the hits inside")
        m.clearFolderFilter()
        #expect(Set(names(m)) == ["a.pdf", "Verträge/2024/v1.pdf"])
        #expect(m.filterHeader == nil)
    }

    @Test func commandClickAddsAFolder() async {
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge/2024"), adding: false)
        m.selectFolder(akten, adding: true)
        #expect(m.hits.count == 3)
        #expect(m.filterHeader == "2 Ordner (4 Dateien)")
    }

    @Test func placeInsideASourceJustFilters() async {
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        await m.openPlace(akten.appendingPathComponent("Verträge"))
        #expect(m.addPrompt == nil)
        #expect(m.folderFilter.folders == [akten.appendingPathComponent("Verträge").standardizedFileURL])
    }

    /// 1.4.0 P2: with „Fragen“ a place outside the sources is added at once (no sheet), then filtered to.
    @Test func placeOutsideLoadsAtOnceAndFilters() async {
        let other = FakeIndex()
        other.browseList = [entry("q.pdf", in: belege)]
        let m = model(["Akten": akteIndex(), "Belege": other])
        await m.add([akten])
        await m.waitUntilIdle()
        await m.openPlace(belege)
        #expect(m.addPrompt == nil, "no add prompt for a place since 1.4.0")
        await m.waitUntilIdle()
        #expect(m.sources.map(\.url.lastPathComponent) == ["Akten", "Belege"])
        #expect(m.folderFilter.folders == [belege.standardizedFileURL])
        #expect(names(m) == ["q.pdf"])
    }

    /// A drop still asks (1.2.1); cancelling it changes nothing (a place no longer asks since 1.4.0).
    @Test func cancelledDropChangesNothing() async {
        let m = model(["Akten": akteIndex(), "Belege": FakeIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        await m.requestAdd([belege])
        #expect(m.addPrompt != nil)
        m.answerAddPrompt(.cancel, remember: false)
        await m.waitUntilIdle()
        #expect(m.folderFilter.isEmpty && m.sources.count == 1)
    }

    /// Review I1: a new sort order survives choosing or clearing a folder.
    @Test func resortThenFilterKeepsTheNewOrder() async {
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("b.pdf", in: akten)]
        index.hits = [entry("b.pdf", in: akten, pages: [0, 1]), entry("a.pdf", in: akten, pages: [0])]
        let m = model(["Akten": index])
        await m.add([akten])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(names(m) == ["b.pdf", "a.pdf"])
        m.settings.sort = .fileName
        await m.waitUntilIdle()
        #expect(names(m) == ["a.pdf", "b.pdf"])
        m.selectFolder(akten, adding: false)
        #expect(names(m) == ["a.pdf", "b.pdf"], "the filter starts from the re-sorted list")
        m.clearFolderFilter()
        #expect(names(m) == ["a.pdf", "b.pdf"])
    }

    /// Review I2: the tree does not depend on the search: a source added while a term is typed shows at once.
    @Test func treeWhileSearching() async {
        let m = model(["Akten": akteIndex()])
        m.queryText = "Vertrag"
        await m.add([akten])
        await m.waitUntilIdle()
        #expect(m.folderTree.first?.name == "Akten" && m.folderTree.first?.fileCount == 3)
    }

    @Test func treeAfterReplaceDuringSearch() async {
        let other = FakeIndex()
        other.browseList = [entry("q.pdf", in: belege)]
        let m = model(["Akten": akteIndex(), "Belege": other])
        m.queryText = "Vertrag"
        await m.add([akten])
        await m.waitUntilIdle()
        await m.replaceSources(with: [belege])
        await m.waitUntilIdle()
        #expect(m.folderTree.map(\.name) == ["Belege"])
    }

    /// Review I7: a place whose index cannot be opened leaves no filter waiting for a later add.
    @Test func failedPlaceLeavesNoPendingFilter() async throws {
        let m = model(["Akten": akteIndex()])
        m.settings.addSourcesPolicy = .add
        await m.add([akten])
        await m.waitUntilIdle()
        let broken = base.appendingPathComponent("Kaputt", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        await m.openPlace(broken)
        await m.waitUntilIdle()
        #expect(m.pendingPlaceFilter == nil)
        #expect(m.folderFilter.isEmpty)
    }

    /// Further filters (e.g. a file type) combine with the folder filter (AND), and one call sets a whole filter.
    @Test func extraFiltersAndWholeFilterSet() async {
        struct OnlyTopLevel: DocumentFilter {
            func includes(_ hit: DocumentHit) -> Bool { !hit.relativePath.contains("/") }
            var label: String { "oben" }
        }
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        m.extraFilters = [OnlyTopLevel()]
        #expect(names(m) == ["a.pdf"])
        var filter = FolderFilter()
        filter.select(akten.appendingPathComponent("Verträge"), adding: false)
        m.setFolderFilter(filter)
        #expect(names(m).isEmpty, "both filters apply")
        m.extraFilters = []
        #expect(m.hits.count == 2)
    }

    /// Deferred minor: while searching, the header counts the documents shown out of the folder's files.
    @Test func headerCountsHitsWhileSearching() async {
        let m = model(["Akten": akteIndex()])
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.filterHeader == "Ordner: Akten › Verträge (1 von 2 Dateien)")
        m.queryText = ""
        await m.waitUntilIdle()
        #expect(m.filterHeader == "Ordner: Akten › Verträge (2 Dateien)")
    }

    /// Trial run 2026-11-13: every file of the folder hit, and the header looked like browsing („10 Dateien“).
    /// While searching it always reads „x von y“, also when x equals y.
    @Test func headerCountsAllHitsWhileSearching() async {
        let index = akteIndex()
        index.hits = [entry("Verträge/2024/v1.pdf", in: akten, pages: [0]), entry("Verträge/v0.pdf", in: akten, pages: [0])]
        let m = model(["Akten": index])
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.filterHeader == "Ordner: Akten › Verträge (2 von 2 Dateien)")
    }

    /// Deferred minor: „Einzelne Dateien“ also covers a single file added after it was chosen.
    @Test func singleFilesFilterFollowsNewFiles() async throws {
        let one = base.appendingPathComponent("eins.pdf"), two = base.appendingPathComponent("zwei.pdf")
        try PDFFixtures.makePDF(at: one, pages: ["Eins"])
        try PDFFixtures.makePDF(at: two, pages: ["Zwei"])
        let m = model(["Akten": akteIndex()])
        await m.add([akten, one])
        await m.waitUntilIdle()
        m.selectSingleFiles(adding: false)
        await m.add([two])
        await m.waitUntilIdle()
        #expect(Set(m.hits.map(\.url.lastPathComponent)) == ["eins.pdf", "zwei.pdf"])
    }

    @Test func removingTheSourceDropsItsFilter() async {
        let m = model(["Akten": akteIndex(), "Belege": FakeIndex()])
        await m.add([akten, belege])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        m.removeSource(akten)
        await m.waitUntilIdle()
        #expect(m.folderFilter.isEmpty)
    }
}
