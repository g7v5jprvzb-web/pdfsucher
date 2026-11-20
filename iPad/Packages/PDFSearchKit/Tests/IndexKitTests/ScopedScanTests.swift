import Foundation
@testable import IndexKit
import Testing
import TestSupport

/// 1.4.0 P3: phase 1 only for the folders changed on disk.
@Suite("Plattenänderung: nur betroffene Ordner")
struct ScopedScanTests {
    @Test func onlyTheChangedFoldersAreScannedAndCompared() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        for dir in ["a/tief", "b"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a/x.pdf"), pages: ["Alt"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a/tief/t.pdf"), pages: ["Tief"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("b/y.pdf"), pages: ["Bleibt"])
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let indexer = Indexer(root: root, store: store)
        #expect(try await indexer.update { _ in }.added == 3)

        try await Task.sleep(for: .milliseconds(20))                    // another modification date
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a/x.pdf"), pages: ["Neuer Inhalt"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a/neu.pdf"), pages: ["Neu"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("b/y.pdf"))
        let scoped = try await indexer.update(scopes: ["a"]) { _ in }
        #expect(scoped.added == 1 && scoped.updated == 1 && scoped.unchanged == 1 && scoped.removed == 0)
        #expect(try store.documents().map(\.relativePath) == ["a/neu.pdf", "a/tief/t.pdf", "a/x.pdf", "b/y.pdf"],
                "b was not looked at")
        #expect(try store.match("Neuer", in: .words).count == 1)

        #expect(try await indexer.update(scopes: ["b"]) { _ in }.removed == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        let gone = try await indexer.update(scopes: ["a"]) { _ in }
        #expect(gone.removed == 3, "a deleted folder: its documents leave")
        #expect(try store.documents().isEmpty)
    }

    @Test func aScopedScanReachesAsDeepAsAFullOne() {
        #expect(FolderScanner(maxDepth: 3).scoped(depth: 1) != nil)
        #expect(FolderScanner(maxDepth: 3).scoped(depth: 4) == nil)
    }
}
