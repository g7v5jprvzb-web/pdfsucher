import CoreGraphics
import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport

/// Answers every image with the same recognized text.
private struct FixedOCR: OCRSource {
    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult {
        OCRResult(text: "Stichwort im Bild", words: [])
    }
}

/// Lays out every Office file as one page; Word as `textkit` („vereinfacht“), PowerPoint as `quicklook`.
private struct FixedLayout: PageLayoutSource {
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (kind == .word ? "textkit" : "quicklook", 1) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let (name, version) = renderer(for: kind)
        return LayoutResult(pages: [LaidOutPage(text: "Stichwort in \(url.lastPathComponent)", words: [],
                                                size: CGSize(width: 595, height: 842))],
                            renderer: name, layoutVersion: version)
    }
}

private struct FixedPages: TextSource {
    func pages(of url: URL) throws -> [PageText] { [PageText(pageIndex: 0, text: "Stichwort")] }
}

@Suite("Document kind in hits")
struct DocumentKindHitTests {
    @Test func hitCarriesKindFromIndex() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Ordner", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a.pdf"), pages: ["Stichwort im PDF"])
        try ImageFixtures.makeImage(at: root.appendingPathComponent("b.png"), text: "Bild", size: CGSize(width: 200, height: 100),
                                    format: .png)
        try Data("x".utf8).write(to: root.appendingPathComponent("c.docx"))
        try Data("x".utf8).write(to: root.appendingPathComponent("d.pptx"))
        let store = try IndexStore(fileURL: dir.appendingPathComponent("index.sqlite"), root: root)
        _ = try await Indexer(root: root, store: store, ocr: FixedOCR(), layout: FixedLayout()).update { _ in }

        let hits = try SearchService(index: store, root: root).search(QueryParser.parse("Stichwort", partialWords: false),
                                                                       sort: .fileName)
        let kinds = Dictionary(uniqueKeysWithValues: hits.map { ($0.relativePath, $0.kind) })
        #expect(kinds == ["a.pdf": .pdf, "b.png": .image, "c.docx": .word, "d.pptx": .powerpoint])
        #expect(hits.filter(\.isImage).map(\.relativePath) == ["b.png"])
        #expect(hits.filter(\.isSimplified).map(\.relativePath) == ["c.docx"])
    }

    @Test func textkitIsSimplified() {
        func doc(_ renderer: String?, _ kind: DocumentKind) -> StoredDocument {
            StoredDocument(id: 1, relativePath: "x", fileSize: 1, modifiedAt: Date(), pageCount: 1, status: .ok,
                           kind: kind, renderer: renderer, layoutVersion: renderer == nil ? nil : 1)
        }
        #expect(doc("textkit", .word).isSimplified)
        #expect(!doc("quicklook", .powerpoint).isSimplified)
        #expect(!doc(nil, .pdf).isSimplified)
    }

    @Test func singleSearchReportsKind() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("brief.docx")
        try Data("x".utf8).write(to: url)
        let hit = try SingleDocumentSearch(source: FixedPages(), kind: .word, isSimplified: true)
            .search(url: url, query: QueryParser.parse("Stichwort", partialWords: false))
        #expect(hit?.kind == .word)
        #expect(hit?.isSimplified == true)
        #expect(hit?.isImage == false)

        let image = try SingleDocumentSearch(source: FixedPages(), kind: .image)
            .search(url: url, query: QueryParser.parse("Stichwort", partialWords: false))
        #expect(image?.kind == .image)
        #expect(image?.isImage == true)
        #expect(image?.isSimplified == false)
    }
}
