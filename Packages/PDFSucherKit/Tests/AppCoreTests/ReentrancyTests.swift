import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

private struct OpenFailed: Error {}
private struct SearchBroke: Error {}

/// Review findings for Task 5.1: state changes that overlap while the model waits for an indexer.
@MainActor @Suite("AppModel re-entrancy")
struct ReentrancyTests {
    let a = URL(fileURLWithPath: "/eins"), b = URL(fileURLWithPath: "/zwei"), c = URL(fileURLWithPath: "/drei")

    func model(_ indexes: [String: FakeIndex], debounce: Duration = .zero, defaults: UserDefaults? = nil) -> AppModel {
        AppModel(settings: makeSettings(), defaults: defaults ?? UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: debounce,
                 openIndex: { root in
                     guard let index = indexes[root.lastPathComponent] else { throw OpenFailed() }
                     return index
                 }, officeRendering: PowerPointDisplaySetting())
    }

    private func starts(_ index: FakeIndex) -> Int { index.events.filter { $0 == "update-start" }.count }

    @Test func openDuringDeleteStartsOneIndexer() async {
        let first = FakeIndex(), second = FakeIndex()
        first.holdUpdates = true
        second.holdUpdates = true
        let m = model(["eins": first, "zwei": second])
        Task { await m.open(folder: a) }
        #expect(await eventually { first.events == ["update-start"] })
        let deleting = Task { await m.deleteIndex() }
        let opening = Task { await m.open(folder: b) }
        await deleting.value
        await opening.value
        #expect(await eventually { starts(second) >= 1 })
        first.holdUpdates = false
        second.holdUpdates = false
        await m.waitUntilIdle()
        #expect(starts(second) == 1)
        #expect(!first.events.contains("update-end"))
        #expect(first.events.contains("delete"))      // the confirmed delete still happens (spec §10)
        #expect(starts(first) == 1)                   // but /eins is not re-indexed
        #expect(m.indexStatus == .upToDate)
    }

    @Test func lastOfQuickOpensWins() async {
        let first = FakeIndex(), second = FakeIndex(), third = FakeIndex()
        first.holdUpdates = true
        third.hits = [doc("drei.pdf", pages: [0])]
        let m = model(["eins": first, "zwei": second, "drei": third])
        m.queryText = "Vertrag"
        Task { await m.open(folder: a) }
        #expect(await eventually { first.events == ["update-start"] })
        let openB = Task { await m.open(folder: b) }
        let openC = Task { await m.open(folder: c) }
        await openB.value
        await openC.value
        first.holdUpdates = false
        await m.waitUntilIdle()
        #expect(starts(second) == 0)
        #expect(starts(third) == 1)
        #expect(m.hits.map(\.relativePath) == ["drei.pdf"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test func openFileDuringFolderOpenWins() async throws {
        let first = FakeIndex(), second = FakeIndex()
        first.holdUpdates = true
        first.lingerOnCancel = true
        let m = model(["eins": first, "zwei": second])
        Task { await m.open(folder: a) }
        #expect(await eventually { first.events == ["update-start"] })
        let opening = Task { await m.open(folder: b) }
        // open(b) has cancelled the run of /eins and is now waiting for it to end
        #expect(await eventually { first.events.contains("update-cancelled") })
        m.open(file: URL(fileURLWithPath: "/nirgends/datei.pdf"))
        first.lingerOnCancel = false
        await opening.value
        first.holdUpdates = false
        await m.waitUntilIdle()
        #expect(starts(second) == 0)
        #expect(m.indexStatus == .none)
    }

    @Test func failedOpenKeepsCurrentFolderIndexing() async {
        let first = FakeIndex()
        first.holdUpdates = true
        let m = model(["eins": first])
        Task { await m.open(folder: a) }
        #expect(await eventually { first.events == ["update-start"] })
        await m.open(folder: URL(fileURLWithPath: "/gibtsnicht"))
        #expect(m.alertMessage?.hasPrefix("Index für „gibtsnicht“ kann nicht geöffnet werden") == true)
        first.holdUpdates = false
        await m.waitUntilIdle()
        #expect(first.events == ["update-start", "update-end"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test func searchFailureNoticeClearsOnSuccess() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0])]
        let m = model(["eins": index])
        await m.open(folder: a)
        await m.waitUntilIdle()
        index.failNextSearch(with: SearchBroke())
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.notice?.hasPrefix("Suche fehlgeschlagen") == true)
        m.queryText = "Vertrag Miete"
        await m.waitUntilIdle()
        #expect(m.notice == nil)
        #expect(m.hits.count == 1)
    }

    @Test func rebuildNoticeShownOncePerIndex() async {
        let index = FakeIndex()
        index.wasRebuilt = true
        let m = model(["eins": index])
        await m.open(folder: a)
        #expect(m.notice == AppModel.Text.corruptIndex)
        await m.waitUntilIdle()
        #expect(m.notice == nil)
        await m.open(folder: a)
        #expect(m.notice == nil)
    }

    @Test func rapidTypingSearchesOnce() async {
        let index = FakeIndex()
        let m = model(["eins": index], debounce: .milliseconds(500))
        await m.open(folder: a)
        await m.waitUntilIdle()
        let before = index.searchCount
        for text in ["V", "Ve", "Ver", "Vert", "Vertrag"] {
            m.queryText = text
            try? await Task.sleep(for: .milliseconds(10))
        }
        await m.waitUntilIdle()
        #expect(index.searchCount == before + 1)
    }

    @Test func restoreLastFolderOnlyOnce() async throws {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        let eins = try TestSupport.PDFFixtures.tempDirectory().appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: eins, withIntermediateDirectories: true)
        defaults.set(eins.path, forKey: "lastFolderPath")
        let index = FakeIndex()
        let m = model(["eins": index], defaults: defaults)
        await m.restoreSources()
        await m.waitUntilIdle()
        m.open(file: URL(fileURLWithPath: "/x.pdf"))
        await m.restoreSources()          // window reopened: keeps the single PDF
        await m.waitUntilIdle()
        #expect(starts(index) == 1)
        #expect(m.indexStatus == .none)
    }
}
