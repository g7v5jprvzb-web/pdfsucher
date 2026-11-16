import CoreGraphics
import Foundation
import IndexKit
@testable import OfficeKit
import Testing
import TestSupport

/// 1.4.0 P5: a Word document is searchable after phase 1, before its layout; the layout replaces the provisional page.
@Suite("Word sofort durchsuchbar")
struct WordPreviewTextTests {
    struct OnePagePerParagraph: PageLayoutSource {
        func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
            LayoutResult(pages: [LaidOutPage(text: "Gesetzte Seite eins", words: [], size: CGSize(width: 10, height: 10)),
                                 LaidOutPage(text: "Gesetzte Seite zwei Mietvertrag", words: [], size: CGSize(width: 10, height: 10))],
                         renderer: "fake", layoutVersion: 1)
        }
        func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("fake", 1) }
    }

    @Test func bodyTextOfADocx() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try OfficeFixtures.docx(paragraphs: ["Sehr geehrte Damen und Herren,", "der Mietvertrag endet am 31.12."],
                                          name: "brief.docx", in: dir)
        let text = try #require(WordPreviewText.text(of: url))
        #expect(text.contains("Mietvertrag endet"))
        #expect(text.contains("Damen und Herren"))
        #expect(WordPreviewText.text(of: dir.appendingPathComponent("fehlt.docx")) == nil)
        try Data("kein zip".utf8).write(to: dir.appendingPathComponent("kaputt.docx"))
        #expect(WordPreviewText.text(of: dir.appendingPathComponent("kaputt.docx")) == nil)
    }

    @Test func searchableAfterPhaseOneAndReplacedByTheLayout() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try OfficeFixtures.docx(paragraphs: ["Der Mietvertrag endet bald"], name: "brief.docx", in: root)
        try Data("kein zip".utf8).write(to: root.appendingPathComponent("kaputt.docx"))
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let indexer = Indexer(root: root, store: store, layout: OnePagePerParagraph(), layoutDuringUpdate: false,
                              wordPreview: { WordPreviewText.text(of: $0) })
        let report = try await indexer.update { _ in }
        #expect(report.added == 2 && report.noText.isEmpty && report.failed.isEmpty)
        let docs = Dictionary(uniqueKeysWithValues: try store.documents().map { ($0.relativePath, $0) })
        #expect(docs["brief.docx"]?.status == .ok && docs["brief.docx"]?.pageCount == 0, "page count unknown until the layout")
        #expect(docs["kaputt.docx"]?.status == .noText && docs["kaputt.docx"]?.pageCount == 0, "unreadable package: waits as before")
        #expect(try store.match("Mietvertrag", in: .words).map(\.pageIndex) == [0])
        #expect(try store.pendingLayoutJobs().map(\.relativePath).sorted() == ["brief.docx", "kaputt.docx"])
        #expect(try store.ocrPage(relativePath: "brief.docx", pageIndex: 0) == nil, "no word boxes from the provisional page")

        _ = try await indexer.layOutPending { _ in }
        #expect(try store.pendingLayoutJobs().isEmpty)
        #expect(try store.match("Mietvertrag", in: .words).map(\.pageIndex) == [1, 1], "the real pages now (the fake lays out both)")
        #expect(try store.match("bald", in: .words).isEmpty, "the provisional text is gone")
        #expect(try store.documents().first { $0.relativePath == "brief.docx" }?.pageCount == 2)
    }
}

