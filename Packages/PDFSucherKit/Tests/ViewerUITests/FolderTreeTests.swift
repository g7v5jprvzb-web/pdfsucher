import Foundation
import OutputKit
import SearchKit
import Testing
import TestSupport
@testable import ViewerUI

/// Ordnerleiste (spec 2026-11-13-pdfsucher-v1.2.5-folder-tree): tree from the document list, counts,
/// folder filter, header, places.
@Suite("Folder tree")
struct FolderTreeTests {
    let root = URL(fileURLWithPath: "/Akten", isDirectory: true)

    func file(_ relative: String, in source: URL? = nil) -> URL { (source ?? root).appendingPathComponent(relative) }

    func hit(_ url: URL, source: URL? = nil, hits: [Int] = []) -> DocumentHit {
        DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: .distantPast,
                    pageHits: hits.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: hits.count, relevance: 0,
                    sourceRoot: source ?? root, pageCount: 3)
    }

    var sources: [LoadedSourceRef] { [LoadedSourceRef(url: root, isFolder: true)] }

    // MARK: §2 tree

    @Test func treeFromDocumentListWithCounts() {
        let files = [file("a.pdf"), file("Verträge/2024/v1.pdf"), file("Verträge/2024/v2.pdf"), file("Verträge/2023/v3.pdf"),
                     file("Fotos/beleg.jpg")]
        let tree = FolderTree.build(sources: sources, files: files)
        #expect(tree.count == 1)
        let akten = tree[0]
        #expect(akten.name == "Akten" && akten.fileCount == 5 && akten.isSourceRoot)
        #expect(akten.children.map(\.name) == ["Fotos", "Verträge"], "sorted by name, localized")
        let vertraege = akten.children[1]
        #expect(vertraege.fileCount == 3)
        #expect(vertraege.children.map { "\($0.name) \($0.fileCount)" } == ["2023 1", "2024 2"])
        #expect(akten.children[0].children.isEmpty && akten.children[0].fileCount == 1)
    }

    @Test func countsFollowThePredicateButTheFoldersStay() {
        let files = [file("a.pdf"), file("Folien/f1.pptx"), file("Folien/2024/f2.pptx"), file("Verträge/v1.pdf"),
                     file("Verträge/v2.pdf")]
        let all = FolderTree.build(sources: sources, files: files)
        let onlyPowerPoint = FolderTree.build(sources: sources, files: files, counts: { $0.pathExtension == "pptx" })
        func shape(_ nodes: [FolderNode]) -> [String] {
            nodes.flatMap { [$0.name] + shape($0.children).map { "  " + $0 } }
        }
        #expect(shape(all) == shape(onlyPowerPoint), "same folders, only the counts change")
        #expect(all[0].fileCount == 5)
        #expect(onlyPowerPoint[0].fileCount == 2)
        #expect(onlyPowerPoint[0].children.map { "\($0.name) \($0.fileCount)" } == ["Folien 2", "Verträge 0"])
        #expect(onlyPowerPoint[0].children[0].children.map { "\($0.name) \($0.fileCount)" } == ["2024 1"])
        #expect(FolderTree.path(to: root.appendingPathComponent("Verträge", isDirectory: true), in: onlyPowerPoint) != nil)
    }

    @Test func singleFilesCountFollowsThePredicate() {
        let pdf = URL(fileURLWithPath: "/Downloads/rechnung.pdf"), deck = URL(fileURLWithPath: "/Downloads/folien.pptx")
        let all = sources + [LoadedSourceRef(url: pdf, isFolder: false), LoadedSourceRef(url: deck, isFolder: false)]
        let tree = FolderTree.build(sources: all, files: [file("a.pdf"), pdf, deck], counts: { $0.pathExtension == "pptx" })
        #expect(tree.map(\.name) == ["Akten", FolderTree.singleFilesTitle], "the group stays")
        #expect(tree[0].fileCount == 0 && tree[1].fileCount == 1)
        let none = FolderTree.build(sources: all, files: [pdf], counts: { _ in false })
        #expect(none.last?.kind == .singleFiles && none.last?.fileCount == 0)
    }

    @Test func onlyFoldersWithFilesAppear() {
        // A folder exists on disk but holds no source file: it is simply not in the document list.
        let tree = FolderTree.build(sources: sources, files: [file("Verträge/v.pdf")])
        #expect(tree[0].children.map(\.name) == ["Verträge"])
    }

    @Test func depthIsLimitedToTen() {
        let deep = (1...14).map { "e\($0)" }.joined(separator: "/") + "/x.pdf"
        let tree = FolderTree.build(sources: sources, files: [file(deep)])
        var node = tree[0], depth = 0
        while let child = node.children.first { node = child; depth += 1 }
        #expect(depth == FolderTree.maxDepth)
        #expect(node.name == "e10" && node.fileCount == 1, "deeper files count to the level-10 folder")
    }

    @Test func singleFilesGroup() {
        let single = URL(fileURLWithPath: "/Downloads/rechnung.pdf")
        let all = sources + [LoadedSourceRef(url: single, isFolder: false)]
        let tree = FolderTree.build(sources: all, files: [file("a.pdf"), single])
        #expect(tree.map(\.name) == ["Akten", FolderTree.singleFilesTitle])
        #expect(tree[1].fileCount == 1 && tree[1].kind == .singleFiles)
    }

    @Test func severalSourcesKeepTheirOrder() {
        let second = URL(fileURLWithPath: "/Belege", isDirectory: true)
        let all = sources + [LoadedSourceRef(url: second, isFolder: true)]
        let tree = FolderTree.build(sources: all, files: [file("x.pdf", in: second), file("a.pdf")])
        #expect(tree.map(\.name) == ["Akten", "Belege"], "in the order they were added")
    }

    // MARK: §3 filter

    @Test func filterWithoutSearchShowsAllFilesOfTheFolder() {
        let files = [file("a.pdf"), file("Verträge/2024/v1.pdf"), file("Verträge/v0.pdf"), file("Verträgeneu/w.pdf")]
        var filter = FolderFilter()
        filter.select(file("Verträge"), adding: false)
        let shown = filter.apply(files.map { hit($0) })
        #expect(shown.map(\.url.lastPathComponent) == ["v1.pdf", "v0.pdf"], "the folder and its subfolders, not „Verträgeneu“")
    }

    @Test func filterWithSearchKeepsOnlyHitsInside() {
        let results = [hit(file("a.pdf"), hits: [0]), hit(file("Verträge/v1.pdf"), hits: [1])]
        var filter = FolderFilter()
        filter.select(file("Verträge"), adding: false)
        #expect(filter.apply(results).map(\.url.lastPathComponent) == ["v1.pdf"])
    }

    @Test func commandClickSelectsSeveralAndClearRemoves() {
        let files = [file("a/1.pdf"), file("b/2.pdf"), file("c/3.pdf")].map { hit($0) }
        var filter = FolderFilter()
        filter.select(file("a"), adding: false)
        filter.select(file("c"), adding: true)
        #expect(filter.apply(files).count == 2)
        filter.select(file("c"), adding: true)                 // ⌘-click again: off
        #expect(filter.apply(files).count == 1)
        filter.clear()
        #expect(filter.isEmpty && filter.apply(files).count == 3)
    }

    @Test func singleFilesGroupFilters() {
        let single = URL(fileURLWithPath: "/Downloads/rechnung.pdf")
        var filter = FolderFilter()
        filter.selectSingleFiles([single], adding: false)
        #expect(filter.apply([hit(file("a.pdf")), hit(single, source: single)]).map(\.url) == [single])
    }

    @Test func keepingSingleFilesLeavesFoldersAlone() {
        var filter = FolderFilter()
        filter.select(file("a"), adding: false)
        filter.selectSingleFiles([URL(fileURLWithPath: "/x.pdf")], adding: true)
        filter.keepSingleFiles([])
        #expect(filter.folders == [file("a").standardizedFileURL] && filter.singleFiles.isEmpty)
    }

    @Test func filtersCombineWithAnd() {
        struct OnlyImages: DocumentFilter {
            func includes(_ hit: DocumentHit) -> Bool { hit.url.pathExtension == "jpg" }
            var label: String { "Bilder" }
        }
        var filters = DocumentFilters()
        filters.folder.select(file("Fotos"), adding: false)
        filters.others = [OnlyImages()]
        let hits = [hit(file("Fotos/a.jpg")), hit(file("Fotos/b.pdf")), hit(file("c.jpg"))]
        #expect(filters.apply(hits).map(\.url.lastPathComponent) == ["a.jpg"])
    }

    // MARK: header

    @Test func headerText() {
        let files = [file("Verträge/2024/v1.pdf"), file("Verträge/2024/v2.pdf"), file("x/y.pdf")]
        let tree = FolderTree.build(sources: sources, files: files)
        var filter = FolderFilter()
        #expect(filter.header(tree: tree) == nil)
        filter.select(file("Verträge/2024"), adding: false)
        #expect(filter.header(tree: tree) == "Ordner: Akten › Verträge › 2024 (2 Dateien)")
        filter.select(file("x"), adding: true)
        #expect(filter.header(tree: tree) == "2 Ordner (3 Dateien)")
    }

    // MARK: performance

    @Test func tenThousandFilesBuildAndFilterFast() {
        let files = (0..<10_000).map { file("Ordner\($0 % 50)/Jahr\($0 % 7)/Monat\($0 % 12)/d\($0).pdf") }
        let hits = files.map { hit($0) }
        let clock = ContinuousClock()
        // Best of 3 (load of the parallel suite, see decisions.md 1.2.4 Nachtrag).
        let build = (0..<3).map { _ in clock.measure { _ = FolderTree.build(sources: sources, files: files) } }.min()!
        var filter = FolderFilter()
        filter.select(file("Ordner7"), adding: false)
        let apply = (0..<3).map { _ in clock.measure { _ = filter.apply(hits) } }.min()!
        #expect(build < .milliseconds(100), "build \(build)")
        #expect(apply < .milliseconds(100), "filter \(apply)")
        #expect(filter.apply(hits).count == 200)
    }

    // MARK: §4 places

    @Test func placesListOnlyFoldersAndLoadLazily() throws {
        let home = try PDFFixtures.tempDirectory()
        for name in ["Dokumente", "Bilder", ".versteckt"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("datei.pdf"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("App.app"), withIntermediateDirectories: true)
        let children = try FileSystemFolderLister().subfolders(of: home)
        #expect(children.map(\.lastPathComponent) == ["Bilder", "Dokumente"], "no files, hidden folders or packages")
    }

    @Test func standardPlaces() {
        let places = Places.standard(home: URL(fileURLWithPath: "/Users/chris"), volumes: [URL(fileURLWithPath: "/Volumes/Archiv")])
        #expect(places.map(\.name) == ["Home", "Schreibtisch", "Dokumente", "Downloads", "Archiv"])
        #expect(places[1].url.path == "/Users/chris/Desktop")
    }

    @Test func clickOnPlaceAsksOrFilters() {
        #expect(Places.action(for: file("Verträge"), sources: sources) == .filter(file("Verträge")), "inside a source: just filter")
        #expect(Places.action(for: root, sources: sources) == .filter(root))
        let other = URL(fileURLWithPath: "/Users/chris/Documents", isDirectory: true)
        #expect(Places.action(for: other, sources: sources) == .add(other), "not loaded: the add prompt, then filter")
    }
}

/// Sichtbarkeit und Breite der Ordnerleiste werden gemerkt.
@MainActor @Suite("Folder bar settings")
struct FolderBarSettingsTests {
    @Test func visibilityAndWidthPersistAndClamp() {
        let d = UserDefaults(suiteName: "FolderBar-\(UUID())")!
        let s = FolderBarSettings(defaults: d)
        #expect(!s.isVisible && s.width == FolderBarSettings.defaultWidth)
        s.isVisible = true
        s.width = 300
        let r = FolderBarSettings(defaults: d)
        #expect(r.isVisible && r.width == 300)
        r.width = 2_000
        #expect(r.width == FolderBarSettings.widthRange.upperBound)
        d.set(-5.0, forKey: "layout.folderBar.width")
        #expect(FolderBarSettings(defaults: d).width == FolderBarSettings.widthRange.lowerBound)
        r.toggle()
        #expect(!FolderBarSettings(defaults: d).isVisible)
    }

    let root = URL(fileURLWithPath: "/Akten", isDirectory: true)
    func tree() -> [FolderNode] {
        let files = ["a.pdf", "Verträge/2024/Q1/v1.pdf", "Verträge/2023/v2.pdf", "Steuer/s.pdf"].map { root.appendingPathComponent($0) }
        return FolderTree.build(sources: [LoadedSourceRef(url: root, isFolder: true)], files: files)
    }
    func url(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: true) }

    /// Which folders are open is kept, also for the next start.
    @Test func expandedFoldersPersist() async {
        let d = UserDefaults(suiteName: "FolderBar-\(UUID())")!
        let s = FolderBarSettings(defaults: d)
        #expect(!s.isExpanded(url("Verträge")))
        s.setExpanded(url("Verträge"), true)
        s.setExpanded(url("Steuer/"), true)
        s.setExpanded(url("Steuer"), false)
        await s.expandedWrite?.value                               // one write for the three changes
        let r = FolderBarSettings(defaults: d)
        #expect(r.isExpanded(url("Verträge")))
        #expect(!r.isExpanded(url("Steuer")))
    }

    /// A source root is open until closed by hand (the bar shows the first level at once), and stays closed.
    @Test func sourceRootsAreOpenUntilClosed() async {
        let d = UserDefaults(suiteName: "FolderBar-\(UUID())")!
        let s = FolderBarSettings(defaults: d)
        let akten = tree()[0]
        #expect(s.isExpanded(akten))
        #expect(!s.isExpanded(akten.children[0]))
        s.setExpanded(root, false, byDefault: true)
        await s.expandedWrite?.value
        #expect(!FolderBarSettings(defaults: d).isExpanded(akten))
    }

    /// A folder chosen by code or a place: the tree opens down to it (its parents, not the folder itself).
    @Test func revealOpensTheParentsOfTheChosenFolder() {
        let s = FolderBarSettings(defaults: UserDefaults(suiteName: "FolderBar-\(UUID())")!)
        var filter = FolderFilter()
        filter.select(url("Verträge/2024/Q1"), adding: false)
        let shown = s.reveal(filter, in: tree())
        #expect(shown.first == url("Verträge/2024/Q1").path && shown.allFound)
        s.setExpanded(root, false, byDefault: true)                       // closed by hand before
        _ = s.reveal(filter, in: tree())
        #expect(s.isExpanded(tree()[0]) && s.isExpanded(url("Verträge")) && s.isExpanded(url("Verträge/2024")))
        #expect(s.openState[root.path] == nil, "a source root is open by default: nothing stored")
        #expect(!s.isExpanded(url("Verträge/2024/Q1")), "the folder itself stays as it was")
        #expect(!s.isExpanded(url("Steuer")))
    }

    @Test func revealOfAFolderNotInTheTreeChangesNothing() {
        let s = FolderBarSettings(defaults: UserDefaults(suiteName: "FolderBar-\(UUID())")!)
        var filter = FolderFilter()
        filter.select(url("Gibt es nicht/x"), adding: false)
        #expect(s.reveal(filter, in: tree()) == FolderBarSettings.Reveal(first: nil, allFound: false))
        #expect(s.openState.isEmpty)
        #expect(s.reveal(FolderFilter(), in: tree()) == FolderBarSettings.Reveal(first: nil, allFound: true))
    }

    @Test func revealOfSeveralFoldersOpensAllAndShowsTheFirstInTreeOrder() {
        let s = FolderBarSettings(defaults: UserDefaults(suiteName: "FolderBar-\(UUID())")!)
        var filter = FolderFilter()
        filter.select(url("Verträge/2023"), adding: false)
        filter.select(url("Steuer"), adding: true)
        #expect(s.reveal(filter, in: tree()) == FolderBarSettings.Reveal(first: url("Steuer").path, allFound: true),
                "Steuer comes before Verträge")
        #expect(s.isExpanded(url("Verträge")))
    }

    /// Review: one folder found, another still loading (a place): not complete, so the sidebar keeps waiting.
    @Test func revealTellsWhenAFolderIsStillMissing() {
        let s = FolderBarSettings(defaults: UserDefaults(suiteName: "FolderBar-\(UUID())")!)
        var filter = FolderFilter()
        filter.select(url("Verträge/2023"), adding: false)
        filter.select(url("Neu/lädt"), adding: true)
        #expect(s.reveal(filter, in: tree()) == FolderBarSettings.Reveal(first: url("Verträge/2023").path, allFound: false))
    }

    /// Review: a state equal to the default is not stored (an ⌥-click closing a subtree stores nothing).
    @Test func defaultStatesAreNotStored() {
        let s = FolderBarSettings(defaults: UserDefaults(suiteName: "FolderBar-\(UUID())")!)
        s.setExpanded(url("Verträge"), true)
        s.setExpanded(url("Verträge"), false)
        s.setExpanded(root, false, byDefault: true)
        #expect(s.openState == [root.path: false])
        s.setExpanded(root, true, byDefault: true)
        #expect(s.openState.isEmpty)
    }
}

/// Review: only folders newly chosen by code, a place or a restored filter open the tree and scroll; the
/// list's own clicks and the model's later adjustments (a folder gone, single files re-synced) do not.
@Suite("Folder sidebar reveal")
struct FolderSidebarRevealTests {
    let a = URL(fileURLWithPath: "/Akten/A", isDirectory: true), b = URL(fileURLWithPath: "/Akten/B", isDirectory: true)
    func filter(_ urls: URL...) -> FolderFilter {
        var f = FolderFilter()
        for u in urls { f.select(u, adding: true) }
        return f
    }

    @Test func aFolderChosenByCodeIsRevealed() {
        #expect(FolderSidebarSelection.toReveal(old: FolderFilter(), new: filter(a), applied: nil) == filter(a))
        #expect(FolderSidebarSelection.toReveal(old: filter(a), new: filter(a, b), applied: nil) == filter(b), "only the new one")
    }

    @Test func theListsOwnChangeIsNotRevealed() {
        #expect(FolderSidebarSelection.toReveal(old: filter(a), new: filter(a, b), applied: filter(a, b)) == nil)
    }

    @Test func removalsAreNotRevealed() {
        #expect(FolderSidebarSelection.toReveal(old: filter(a, b), new: filter(a), applied: nil) == nil)
        #expect(FolderSidebarSelection.toReveal(old: filter(a), new: FolderFilter(), applied: nil) == nil)
    }
}

/// The sidebar's list selection (ids) ↔ the folder filter.
@Suite("Folder sidebar selection")
struct FolderSidebarSelectionTests {
    let root = URL(fileURLWithPath: "/Akten", isDirectory: true)

    @Test func selectionToFilterAndBack() {
        let a = root.appendingPathComponent("A", isDirectory: true), b = root.appendingPathComponent("B", isDirectory: true)
        let single = URL(fileURLWithPath: "/x.pdf")
        #expect(FolderSidebarSelection.filter(for: [], singleFiles: [single]).isEmpty)
        #expect(FolderSidebarSelection.filter(for: [FolderSidebarSelection.allID], singleFiles: []).isEmpty, "„Alle Quellen“")
        let two = FolderSidebarSelection.filter(for: [a.path, b.path], singleFiles: [])
        #expect(Set(two.folders) == [a.standardizedFileURL, b.standardizedFileURL])
        let withSingles = FolderSidebarSelection.filter(for: ["pdfsucher.singleFiles"], singleFiles: [single])
        #expect(withSingles.singleFiles == [single])
        #expect(FolderSidebarSelection.ids(for: two) == [a.standardizedFileURL.path, b.standardizedFileURL.path])
        #expect(FolderSidebarSelection.ids(for: FolderFilter()) == [FolderSidebarSelection.allID])
        let place = FolderSidebarSelection.placeID(URL(fileURLWithPath: "/Users/chris/Documents"))
        #expect(FolderSidebarSelection.place(in: [place])?.path == "/Users/chris/Documents")
        #expect(FolderSidebarSelection.filter(for: [place, a.path], singleFiles: []).folders == [a.standardizedFileURL], "places are not folder ids")
    }
}

/// Review I5: how the list selection moves between „Alle Quellen“ and folders.
@Suite("Folder sidebar selection transitions")
struct FolderSidebarTransitionTests {
    let all = FolderSidebarSelection.allID

    @Test func commandClickFromAllSourcesDropsAll() {
        #expect(FolderSidebarSelection.normalize(old: [all], new: [all, "/A"]) == ["/A"])
    }

    @Test func choosingAllSourcesClearsTheRest() {
        #expect(FolderSidebarSelection.normalize(old: ["/A", "/B"], new: ["/A", "/B", all]) == [all])
    }

    @Test func emptySelectionMeansAll() {
        #expect(FolderSidebarSelection.normalize(old: ["/A"], new: []) == [all])
    }

    @Test func plainChangesStay() {
        #expect(FolderSidebarSelection.normalize(old: ["/A"], new: ["/A", "/B"]) == ["/A", "/B"])
        #expect(FolderSidebarSelection.normalize(old: ["/A"], new: ["/B"]) == ["/B"])
    }
}
