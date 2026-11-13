import Foundation
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Chris (Task 5.6): opening and deleting an index must not block the user interface.
@MainActor @Suite("Index work off the main thread", .serialized)
struct OffMainTests {
    @Test func openIndexRunsOffMain() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        let onMain = Locked(false)
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), debounce: .zero,
                             openIndex: { _ in onMain.set(Thread.isMainThread); return index })
        await model.open(folder: dir)
        #expect(onMain.value == false)
        #expect(model.canDeleteIndex)
    }

    @Test func deleteIndexRunsOffMain() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = FakeIndex()
        let model = makeModel(index: index)
        await model.open(folder: dir)
        await model.waitUntilIdle()
        await model.deleteIndex()
        #expect(index.events.contains("delete"))
        #expect(!index.events.contains("delete-on-main"))
    }

    /// A slow index open must not win over a folder opened after it.
    @Test func laterOpenWinsOverSlowerEarlierOpen() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let slow = base.appendingPathComponent("langsam"), fast = base.appendingPathComponent("schnell")
        for d in [slow, fast] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let slowIndex = FakeIndex(), fastIndex = FakeIndex()
        slowIndex.hits = [doc("alt.pdf", pages: [0])]
        fastIndex.hits = [doc("neu.pdf", pages: [0])]
        let release = Locked(false)
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), debounce: .zero,
                             openIndex: { url in
                                 if url.lastPathComponent == "langsam" {
                                     waitFor(release)
                                     return slowIndex
                                 }
                                 return fastIndex
                             })
        let first = Task { await model.open(folder: slow) }
        try await Task.sleep(for: .milliseconds(50))
        await model.open(folder: fast)
        release.set(true)
        await first.value
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.url.lastPathComponent) == ["neu.pdf"])
    }

    /// A slow folder open must not replace a single file opened after it.
    @Test func laterFileOpenWinsOverSlowerFolderOpen() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let release = Locked(false)
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), debounce: .zero,
                             openIndex: { _ in
                                 waitFor(release)
                                 return FakeIndex()
                             })
        let first = Task { await model.open(folder: base) }
        try await Task.sleep(for: .milliseconds(50))
        model.open(file: base.appendingPathComponent("a.pdf"))
        release.set(true)
        await first.value
        #expect(!model.canDeleteIndex)     // still the file, not the folder
    }
}

/// Spins until `flag` is set, at most 2 s (so a call on the main thread fails the test instead of hanging).
func waitFor(_ flag: Locked<Bool>) {
    let deadline = Date().addingTimeInterval(2)
    while !flag.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}
