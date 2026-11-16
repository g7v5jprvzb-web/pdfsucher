import CoreGraphics
import Foundation
import IndexKit
import Testing
import TestSupport
@testable import AppCore

/// 1.4.0 P1: loading the parent of an indexed folder does not read the child's files again.
@Suite("Elternordner übernimmt Kind-Index")
struct ParentTakesOverChildTests {
    @Test func parentRunFindsTheChildsFilesUnchanged() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("Akten", isDirectory: true)
        let child = parent.appendingPathComponent("2025", isDirectory: true)
        let indexes = base.appendingPathComponent("Indexes", isDirectory: true)
        for dir in [child, indexes] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for i in 0..<5 { try PDFFixtures.makePDF(at: child.appendingPathComponent("k\(i).pdf"), pages: ["Kind \(i) Vertragstext"]) }
        try PDFFixtures.makePDF(at: parent.appendingPathComponent("oben.pdf"), pages: ["Oben"])
        func url(_ folder: URL) -> URL { indexes.appendingPathComponent(IndexStore.location(forFolder: folder).lastPathComponent) }

        let childIndex = try FolderIndex(root: child, indexURL: url(child), makeLayout: { NoLayout() })
        #expect(try await childIndex.update { _ in }.added == 5)
        let parentIndex = try FolderIndex(root: parent, indexURL: url(parent), makeLayout: { NoLayout() })
        let report = try await parentIndex.update { _ in }
        #expect(report.added == 1)
        #expect(report.unchanged == 5)
        #expect(try parentIndex.browse().count == 6)
    }
}

private struct NoLayout: PageLayoutSource {
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "", words: [], size: CGSize(width: 100, height: 100))], renderer: "none", layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("none", 1) }
}
