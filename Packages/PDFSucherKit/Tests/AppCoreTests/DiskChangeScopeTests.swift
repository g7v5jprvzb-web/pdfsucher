import Foundation
import IndexKit
import Testing
import TestSupport
@testable import AppCore

/// 1.4.0 P3: a change on disk indexes only the changed folders, and does not throw away a running layout.
@MainActor @Suite("Plattenänderungen schonend", .timeLimit(.minutes(1)))
struct DiskChangeScopeTests {
    let base: URL
    let akten: URL
    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        akten = base.appendingPathComponent("Akten", isDirectory: true)
        try FileManager.default.createDirectory(at: akten, withIntermediateDirectories: true)
    }

    func model(_ index: FakeIndex, watcher: FakeWatcher) -> AppModel {
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Scope-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: { _ in index })
        m.diskChangeCooldown = .zero
        m.folderWatcher = watcher
        return m
    }

    @Test func aChangeWithFoldersIsIndexedThereOnly() async {
        let index = FakeIndex(), watcher = FakeWatcher()
        let m = model(index, watcher: watcher)
        await m.add([akten])
        await m.waitUntilIdle()
        #expect(index.scopedUpdates.isEmpty, "the first run after adding is whole")
        watcher.fire([akten.path], scopes: [akten.path: ["2025", "Alt"]])
        await m.waitUntilIdle()
        #expect(index.scopedUpdates == [["2025", "Alt"]])
        watcher.fire([akten.path])                                      // lost events: the whole folder
        await m.waitUntilIdle()
        #expect(index.scopedUpdates.count == 1)
        #expect(index.events.filter { $0 == "update-end" }.count == 3)
    }

    @Test func anotherReasonMakesTheRunWhole() async {
        let index = FakeIndex(), watcher = FakeWatcher()
        let m = model(index, watcher: watcher)
        index.holdUpdates = true
        await m.add([akten])
        while !index.events.contains("update-start") { try? await Task.sleep(for: .milliseconds(2)) }
        watcher.fire([akten.path], scopes: [akten.path: ["2025"]])       // during the first run: held for a trailing run
        m.ocrPreferences.includeImages.toggle()                          // settings: the folder is listed again, whole
        index.holdUpdates = false
        await m.waitUntilIdle()
        #expect(index.scopedUpdates.isEmpty)
    }

    @Test func aChangeOnDiskLetsTheRunningLayoutFinish() async {
        let index = FakeIndex(), watcher = FakeWatcher()
        let log = StringLog()
        index.layoutLog = log
        index.ocrLog = log
        index.holdLayout = true
        let m = model(index, watcher: watcher)
        await m.add([akten])
        while !log.entries.contains(":layout-start") { try? await Task.sleep(for: .milliseconds(2)) }
        watcher.fire([akten.path], scopes: [akten.path: ["2025"]])
        #expect(index.gentleStops == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!log.entries.contains(":layout-cancelled"), "not thrown away")
        index.holdLayout = false
        await m.waitUntilIdle()
        #expect(index.scopedUpdates == [["2025"]])
    }
}
