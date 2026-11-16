import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Folders renamed or deleted in the Finder while the app runs leave the tree: the folder sources are
/// watched (FSEvents in the app, a fake here) and a change indexes that source again.
@MainActor @Suite("Folder sources watched on disk", .timeLimit(.minutes(1)))
struct FolderWatchTests {
    let base: URL
    let akten: URL, belege: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        akten = base.appendingPathComponent("Akten", isDirectory: true)
        belege = base.appendingPathComponent("Belege", isDirectory: true)
        for dir in [akten, belege] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func entry(_ path: String, in root: URL) -> DocumentHit {
        DocumentHit(url: root.appendingPathComponent(path), relativePath: path, modifiedAt: .distantPast,
                    pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: root, pageCount: 3)
    }

    func model(_ indexes: [String: FakeIndex], watcher: FakeWatcher, cooldown: Duration = .zero) -> AppModel {
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Watch-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), debounce: .zero,
                         openIndex: { root in
                             guard let index = indexes[root.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
                             return index
                         })
        m.diskChangeCooldown = cooldown
        m.folderWatcher = watcher
        return m
    }

    func updates(_ index: FakeIndex) -> Int { index.events.filter { $0 == "update-end" }.count }

    @Test func watchedRootsFollowTheFolderSources() async throws {
        let watcher = FakeWatcher()
        let single = base.appendingPathComponent("eins.pdf")
        try PDFFixtures.makePDF(at: single, pages: ["x"])
        let m = model(["Akten": FakeIndex(), "Belege": FakeIndex()], watcher: watcher)
        await m.add([akten, belege, single])
        await m.waitUntilIdle()
        #expect(watcher.roots == [akten.path, belege.path], "folders only, no single files")
        m.removeSource(akten)
        #expect(watcher.roots == [belege.path])
        m.removeAllSources()
        #expect(watcher.roots == [])
    }

    @Test func aChangeIndexesTheSourceAgainAndUpdatesTheTree() async {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Verträge/v1.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        #expect(m.folderTree.first?.children.map(\.name) == ["Verträge"])
        #expect(updates(index) == 1)

        index.browseList = [entry("a.pdf", in: akten), entry("Verträge 2025/v1.pdf", in: akten)]   // renamed in the Finder
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        #expect(updates(index) == 2)
        #expect(m.folderTree.first?.children.map(\.name) == ["Verträge 2025"])
    }

    @Test func aChangeElsewhereIndexesNothing() async {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        watcher.fire([base.appendingPathComponent("Fremd").path])
        await m.waitUntilIdle()
        #expect(updates(index) == 1)
    }

    /// Review: a busy folder (a long copy into Downloads) must not index the source every 1.5 s and keep
    /// the text recognition from running. Reports within the cooldown collapse into one later run.
    @Test func manyReportsCollapseIntoFewRuns() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher, cooldown: .seconds(2))
        await m.add([akten])
        await m.waitUntilIdle()
        for i in 0..<20 {
            if i == 19 { index.browseList = [entry("a.pdf", in: akten), entry("Neu/b.pdf", in: akten)] }
            watcher.fire([akten.path])
            try await Task.sleep(for: .milliseconds(20))
        }
        await m.waitUntilIdle()
        #expect(updates(index) <= 3, "1 add + at most a first and a trailing run, got \(updates(index))")
        #expect(m.folderTree.first?.children.map(\.name) == ["Neu"], "the last change is indexed")
    }

    /// Trial run: an ejected volume within the cooldown showed „aktuell“ for seconds. A root that went away
    /// or came back (unmount, mount, moved) is indexed at once.
    @Test func aRootThatWentAwayIsIndexedAtOnce() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        let m = model(["Akten": index], watcher: watcher, cooldown: .seconds(30))
        await m.add([akten])
        await m.waitUntilIdle()
        watcher.fire([akten.path])                                // the first change: at once
        await m.waitUntilIdle()
        #expect(updates(index) == 2)
        watcher.fire([akten.path])                                // cooling now: waits
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates(index) == 2)
        watcher.fire([akten.path], urgent: true)
        await m.waitUntilIdle()                                   // no trailing run left: no 30 s wait
        #expect(updates(index) == 3)
    }

    /// Re-review: the cooldown counts from the end of a run, so a run longer than the cooldown is not
    /// followed at once by the next one.
    @Test func theCooldownStartsWhenTheRunEnds() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        let m = model(["Akten": index], watcher: watcher, cooldown: .milliseconds(600))
        await m.add([akten])
        await m.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(700))
        index.holdUpdates = true
        watcher.fire([akten.path])                                // run 2 starts, takes longer than the cooldown
        while index.events.filter({ $0 == "update-start" }).count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(700))
        watcher.fire([akten.path])                                // during run 2: waits for its end + cooldown
        index.holdUpdates = false
        while updates(index) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates(index) == 2, "not at once after run 2")
        await m.waitUntilIdle()
        #expect(updates(index) == 3, "a trailing run after the cooldown")
    }

    /// Re-review: a change reported while the source's own run is going on is checked by the next run's
    /// tree (the running one scanned before it).
    @Test func aChangeDuringTheRunIsCheckedByTheNextRun() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Verträge/v1.pdf", in: akten)]
        let renamed = [entry("a.pdf", in: akten), entry("Verträge 2025/v1.pdf", in: akten)]
        index.beforeUpdate = { n in if n == 3 { index.browseList = renamed } }
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        index.holdUpdates = true
        watcher.fire([akten.path])
        while index.events.filter({ $0 == "update-start" }).count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        watcher.fire([akten.path])                                // the rename, while run 2 goes on
        index.holdUpdates = false
        await m.waitUntilIdle()
        #expect(updates(index) == 3)
        #expect(m.folderTree.first?.children.map(\.name) == ["Verträge 2025"])
        #expect(m.folderFilter.isEmpty)
    }

    @Test func removingAllSourcesForgetsWaitingChanges() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        let m = model(["Akten": index], watcher: watcher, cooldown: .seconds(30))
        await m.add([akten])
        await m.waitUntilIdle()
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        watcher.fire([akten.path])                                // waits for the cooldown
        m.removeAllSources()
        await m.waitUntilIdle()                                   // no 30 s wait for a source that is gone
        #expect(updates(index) == 2)
    }

    @Test func theWatcherKnowsWhetherImagesCount() async {
        let watcher = FakeWatcher()
        let m = model(["Akten": FakeIndex()], watcher: watcher)
        m.ocrPreferences.includeImages = false
        await m.add([akten])
        await m.waitUntilIdle()
        #expect(watcher.includeImages == false)
        m.ocrPreferences.includeImages = true
        await m.waitUntilIdle()
        #expect(watcher.includeImages == true)
    }

    /// Review: an ejected volume's run fails; its chosen folders stay (the tree still shows them, they come
    /// back with the volume).
    @Test func aFailedRunKeepsTheFilter() async throws {
        let watcher = FakeWatcher()
        let vertraege = akten.appendingPathComponent("Verträge", isDirectory: true)
        let index = FakeIndex()
        index.browseList = [entry("Verträge/v1.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(vertraege, adding: false)
        index.failNextUpdate(with: CocoaError(.fileReadNoSuchFile))
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        m.queryText = "x"; m.queryText = ""                    // a later browse rebuilds the tree
        await m.waitUntilIdle()
        #expect(m.folderFilter.folders == [vertraege.standardizedFileURL])
    }

    /// Review: a rename that only changes case still exists on disk (case-insensitive APFS); the tree decides.
    @Test func aFolderRenamedOnlyInCaseLeavesTheFilter() async throws {
        let watcher = FakeWatcher()
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Verträge/v1.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(akten.appendingPathComponent("Verträge"), adding: false)
        index.browseList = [entry("a.pdf", in: akten), entry("verträge/v1.pdf", in: akten)]
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        #expect(m.folderFilter.isEmpty)
    }

    @Test func aFilteredFolderThatIsGoneLeavesTheFilter() async throws {
        let watcher = FakeWatcher()
        let vertraege = akten.appendingPathComponent("Verträge", isDirectory: true)
        try FileManager.default.createDirectory(at: vertraege, withIntermediateDirectories: true)
        let index = FakeIndex()
        index.browseList = [entry("a.pdf", in: akten), entry("Verträge/v1.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(vertraege, adding: false)
        #expect(m.hits.count == 1)

        try FileManager.default.removeItem(at: vertraege)
        index.browseList = [entry("a.pdf", in: akten)]
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        #expect(m.folderFilter.isEmpty, "the deleted folder no longer filters")
        #expect(m.filterHeader == nil)
        #expect(m.hits.map(\.relativePath) == ["a.pdf"])
    }

    @Test func aFilteredFolderThatStillExistsStays() async throws {
        let watcher = FakeWatcher()
        let vertraege = akten.appendingPathComponent("Verträge", isDirectory: true)
        try FileManager.default.createDirectory(at: vertraege, withIntermediateDirectories: true)
        let index = FakeIndex()
        index.browseList = [entry("Verträge/v1.pdf", in: akten)]
        let m = model(["Akten": index], watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        m.selectFolder(vertraege, adding: false)
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        #expect(m.folderFilter.folders == [vertraege.standardizedFileURL])
    }
}

/// Records the watched roots; `fire` stands for FSEvents reporting a change below those roots.
@MainActor final class FakeWatcher: FolderWatching {
    var onChange: (@MainActor ([String], Bool, [String: [String]]) -> Void)?
    private(set) var roots: [String] = []
    private(set) var includeImages: Bool?
    func watch(_ roots: [String], includeImages: Bool) { self.roots = roots; self.includeImages = includeImages }
    /// Without `scopes`: a full scan of each root (as before 1.4.0).
    func fire(_ roots: [String], urgent: Bool = false, scopes: [String: [String]] = [:]) { onChange?(roots, urgent, scopes) }
}
