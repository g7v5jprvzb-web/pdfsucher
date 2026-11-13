import Foundation
import IndexKit
import OutputKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Indexing runs that fail (final review, Task 5.6).
@MainActor @Suite("Index failures", .serialized)
struct IndexFailureTests {
    private func folder() throws -> URL { try PDFFixtures.tempDirectory() }

    /// The indexer itself reports a damaged index (it wiped it): a new run rebuilds it, so the notice
    /// „wird neu aufgebaut“ is true.
    @Test func damagedIndexDuringIndexingStartsNewRun() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        let model = makeModel(index: index)
        await model.open(folder: dir)
        #expect(await eventually { index.events.filter { $0 == "update-start" }.count == 2 })
        await model.waitUntilIdle()
        #expect(index.events == ["update-start", "update-failed", "update-start", "update-end"])
        #expect(model.indexStatus == .upToDate)
        #expect(model.notice == nil)
    }

    /// Damaged again right away: no endless loop, the notice says indexing failed.
    @Test func repeatedDamageDoesNotLoop() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        let model = makeModel(index: index)
        await model.open(folder: dir)
        #expect(await eventually { index.events.filter { $0 == "update-failed" }.count == 2 })
        await model.waitUntilIdle()
        #expect(index.events.filter { $0 == "update-start" }.count == 2)
        #expect(model.notice?.hasPrefix("Indexieren fehlgeschlagen: ") == true)
    }

    /// Review of the fixes: after „Index löschen“ a new damage report rebuilds again.
    @Test func deleteIndexAllowsAnotherRebuild() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        let model = makeModel(index: index)
        await model.open(folder: dir)
        #expect(await eventually { index.events.filter { $0 == "update-failed" }.count == 2 })
        await model.waitUntilIdle()
        index.failNextUpdate(with: IndexStoreError.corruptIndexRebuilt)
        await model.deleteIndex()
        #expect(await eventually { index.events.filter { $0 == "update-end" }.count == 1 })
        await model.waitUntilIdle()
        #expect(model.indexStatus == .upToDate)
    }

    @Test func otherIndexErrorShowsReason() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        index.failNextUpdate(with: CocoaError(.fileReadNoPermission))
        let model = makeModel(index: index)
        await model.open(folder: dir)
        await model.waitUntilIdle()
        #expect(model.indexStatus == .none)
        #expect(model.notice == "Indexieren fehlgeschlagen: \(CocoaError(.fileReadNoPermission).localizedDescription)")
    }
}

/// Final review (Task 5.6): a page ticked in folder mode (URL built from the index's NFC relative path)
/// and in single-file mode (URL from the open panel, possibly NFD) must be one selection entry.
/// Foundation file URLs use the decomposed file system form on macOS, so both compare equal.
@MainActor @Suite("Single file URL form")
struct SingleFileURLTests {
    @Test func nfcAndNfdPagesAreOneSelectionEntry() {
        let root = URL(fileURLWithPath: "/tmp/Ordner", isDirectory: true)
        let fromIndex = root.appendingPathComponent("Übersicht.pdf".precomposedStringWithCanonicalMapping, isDirectory: false)
        let fromPanel = URL(fileURLWithPath: "/tmp/Ordner/" + "Übersicht.pdf".decomposedStringWithCanonicalMapping)
        #expect(fromIndex == fromPanel)
        var selection = PageSelection()
        selection.toggle(PageRef(url: fromIndex, pageIndex: 0))
        #expect(selection.contains(PageRef(url: fromPanel, pageIndex: 0)))
        selection.toggle(PageRef(url: fromPanel, pageIndex: 0))
        #expect(!selection.contains(PageRef(url: fromIndex, pageIndex: 0)))
    }
}
