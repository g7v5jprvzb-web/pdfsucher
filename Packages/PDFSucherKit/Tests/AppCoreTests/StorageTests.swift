import Foundation
import IndexKit
import Testing
import TestSupport
@testable import AppCore

/// 1.3.10: settings „Speicher“ — index sizes and orphan indexes; sources and other files are never touched.
@MainActor @Suite("Storage: indexes and caches")
struct StorageTests {
    let folder = URL(fileURLWithPath: "/docs")

    private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    @Test func orphansAreOnlyIndexFilesNotKept() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appendingPathComponent(hex("a") + ".sqlite")
        for name in [hex("a") + ".sqlite", hex("a") + ".sqlite-wal", hex("b") + ".sqlite", hex("b") + ".sqlite-wal",
                     hex("b") + ".sqlite-shm", "notizen.txt", "ABC.sqlite", hex("C") + ".sqlite"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let orphans = IndexFiles.orphans(in: dir, keeping: [kept.standardizedFileURL.path]).map(\.lastPathComponent)
        #expect(orphans == [hex("b") + ".sqlite", hex("b") + ".sqlite-shm", hex("b") + ".sqlite-wal"])
        #expect(IndexFiles.bytes(ofIndex: kept) == 2)
    }

    @Test func modelKeepsLoadedAndRememberedSourcesIndexes() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = IndexStore.location(forFolder: folder).lastPathComponent
        let remembered = IndexStore.location(forFolder: URL(fileURLWithPath: "/offline", isDirectory: true)).lastPathComponent
        let orphan = hex("e") + ".sqlite"
        for name in [loaded, remembered, orphan, orphan + "-wal", "README"] {
            try Data("xyz".utf8).write(to: dir.appendingPathComponent(name))
        }
        let model = makeModel(index: FakeIndex())
        await model.open(folder: folder)
        model.rememberedMissing = ["/offline"]
        model.indexDirectory = dir
        #expect(await model.orphanIndexFiles().map(\.lastPathComponent) == [orphan, orphan + "-wal"])
        #expect(await model.deleteOrphanIndexes() == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == [loaded, remembered, "README"].sorted())
        #expect(model.sources.map(\.url.path) == ["/docs"], "the source stays")
    }

    @Test func withoutIndexDirectoryNothingIsAnOrphan() async {
        let model = makeModel(index: FakeIndex())
        #expect(await model.orphanIndexFiles().isEmpty)
        #expect(await model.deleteOrphanIndexes() == 0)
    }
}
