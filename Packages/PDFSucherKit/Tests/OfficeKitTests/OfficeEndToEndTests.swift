import CoreGraphics
import Foundation
import IndexKit
import MediaKit
import SearchKit
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// Task 9 (1.3 Office): the whole chain — PDF, Word and PowerPoint files on disk → Indexer with `OfficeLayoutSource`
/// (Quick Look slides, TextKit Word pages) → IndexStore → SearchService / PageMatcher / HighlightBoxes.
/// Needs macOS's own `Office.qlgenerator`; without it every test records an issue instead of passing.
@Suite("Office end to end", .serialized)
struct OfficeEndToEndTests {
    let base: URL
    let root: URL
    let cacheRoot: URL

    init() throws {
        base = try PDFFixtures.tempDirectory()
        root = base.appendingPathComponent("Quelle", isDirectory: true)
        cacheRoot = base.appendingPathComponent("SlideCache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // „Kündigungsfrist“ never stands on the first page, so a wrong page index shows.
        try PDFFixtures.makePDF(at: root.appendingPathComponent("Vertrag.pdf"),
                                pages: ["Mietvertrag Deckblatt", "Die Kündigungsfrist beträgt drei Monate."])
        try OfficeFixtures.docx(paragraphs: ["Einleitung zum Vertrag", "Die Kündigungsfrist beträgt drei Monate."],
                                pageBreakAfter: [0], name: "Brief.docx", in: root)
        // Slide 2 is hidden: the hit is on XML slide 3 but on visible page 1.
        try OfficeFixtures.pptx(slides: ["Präsentation Deckblatt", "Versteckte Folie", "Alpha Kündigungsfrist"],
                                hidden: [1], name: "Folien.pptx", in: root)
    }

    /// Wraps a layout source and counts (and records the URLs of) its `layout` calls.
    final class CountingLayoutSource: PageLayoutSource {
        let inner: any PageLayoutSource
        private let urls = Mutex<[URL]>([])

        init(_ inner: any PageLayoutSource) { self.inner = inner }

        var calls: [URL] { urls.withLock { $0 } }

        func renderer(for kind: DocumentKind) -> (name: String, version: Int) { inner.renderer(for: kind) }

        func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
            urls.withLock { $0.append(url) }
            return try await inner.layout(of: url, kind: kind)
        }
    }

    /// False (and an issue recorded) when this Mac has no Office Quick Look generator.
    private func generatorAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: QuickLookHTML.officeGenerator) else {
            Issue.record("\(QuickLookHTML.officeGenerator) fehlt – PowerPoint-Vorschau über Quick Look nicht testbar")
            return false
        }
        return true
    }

    private func makeLayout() -> CountingLayoutSource {
        CountingLayoutSource(OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: SlideCache(root: cacheRoot)),
                                                word: TextKitWordSource()))
    }

    /// Indexes `root` once with a fresh store; checks that all three files were indexed without failures.
    private func indexed(layout: CountingLayoutSource) async throws -> IndexStore {
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let report = try await Indexer(root: root, store: store, layout: layout).update { _ in }
        #expect(report.added == 3 && report.failed.isEmpty && report.noText.isEmpty, "\(report)")
        #expect(report.layout.laidOut == 2 && report.layout.failed.isEmpty && report.layout.deferred == 0, "\(report.layout)")
        return store
    }

    private func document(_ name: String, in store: IndexStore) throws -> StoredDocument {
        try #require(try store.documents().first { $0.relativePath == name })
    }

    private static func query() -> ParsedQuery { QueryParser.parse("Kündigungsfrist", partialWords: false) }

    @Test func searchFindsWordAndSlideHits() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard generatorAvailable() else { return }
        let store = try await indexed(layout: makeLayout())

        let pptx = try document("Folien.pptx", in: store)
        let docx = try document("Brief.docx", in: store)
        #expect(pptx.kind == .powerpoint && pptx.renderer == "quicklook" && pptx.pageCount == 2, "\(pptx)")
        #expect(docx.kind == .word && docx.renderer == "textkit" && docx.pageCount == 2, "\(docx)")

        let service = SearchService(index: store, root: root)
        for sort in [SortMode.matchCount, .relevance, .modifiedDate, .fileName, .folder] {
            let hits = try service.search(Self.query(), sort: sort)
            #expect(Set(hits.map(\.relativePath)) == ["Brief.docx", "Folien.pptx", "Vertrag.pdf"], "\(sort)")
        }
        let hits = try service.search(Self.query(), sort: .fileName)
        try #require(hits.count == 3)
        for hit in hits {
            #expect(hit.pageHits.map(\.pageIndex) == [1], "\(hit.relativePath): \(hit.pageHits)")
            #expect(hit.pageHits.map(\.matchCount) == [1], "\(hit.relativePath): \(hit.pageHits)")
        }
        // Text of the other pages is searchable too, on the right page.
        #expect(try service.search(QueryParser.parse("Deckblatt", partialWords: false), sort: .fileName)
            .map { "\($0.relativePath)\($0.pageHits.map(\.pageIndex))" } == ["Folien.pptx[0]", "Vertrag.pdf[0]"])
        // The hidden slide is not indexed.
        #expect(try service.search(QueryParser.parse("Versteckte", partialWords: false), sort: .fileName).isEmpty)
    }

    @Test func highlightBoxesForSlideHit() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard generatorAvailable() else { return }
        let store = try await indexed(layout: makeLayout())
        let pptx = try document("Folien.pptx", in: store)
        let text = try #require(try store.allPages().first { $0.docId == pptx.id && $0.pageIndex == 1 }?.text)

        // 1.2.1 path of the preview (`AppModel.ocrText` → `ocrPage` → `OCRHighlights`): a laid-out slide
        // gives its text and word boxes like a recognized image; a PDF page with a text layer gives nil.
        let page = try #require(try store.ocrPage(relativePath: "Folien.pptx", pageIndex: 1))
        #expect(page.text == text)
        #expect(try store.ocrPage(relativePath: "Vertrag.pdf", pageIndex: 0) == nil)

        let ranges = try #require(PageMatcher(Self.query()).ranges(in: page.text))
        try #require(ranges.count == 1)
        let nsRanges = ranges.map { NSRange($0, in: page.text) }
        let words = page.words
        #expect(!words.isEmpty)
        #expect(words == (try store.ocrWords(docId: pptx.id, pageIndex: 1)))
        let rects = HighlightBoxes.rects(for: nsRanges, in: words)
        try #require(!rects.isEmpty)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for rect in rects {
            #expect(unit.contains(rect), "\(rect)")
            #expect(rect.width > 0 && rect.height > 0, "\(rect)")
        }
        // „Alpha Kündigungsfrist“ in one text box at the top of the slide: one box, right of „Alpha“, upper half.
        #expect(rects.count == 1)
        let alpha = try #require(words.first { (text as NSString).substring(with: $0.range) == "Alpha" })
        #expect(rects[0].minX >= alpha.box.maxX, "\(rects[0]) vs \(alpha.box)")
        #expect(rects[0].maxY < 0.5, "\(rects[0])")
    }

    @Test func incrementalSecondRunNoLayout() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard generatorAvailable() else { return }
        let first = makeLayout()
        let store = try await indexed(layout: first)
        #expect(Set(first.calls.map(\.lastPathComponent)) == ["Brief.docx", "Folien.pptx"])
        #expect(first.calls.count == 2)

        let second = makeLayout()
        let again = try await Indexer(root: root, store: store, layout: second).update { _ in }
        #expect(second.calls.isEmpty, "\(second.calls)")
        #expect(again.unchanged == 3 && again.added == 0 && again.updated == 0, "\(again)")
        #expect(again.layout == LayoutReport())
        #expect(try SearchService(index: store, root: root).search(Self.query(), sort: .fileName).count == 3)
    }

    @Test func cacheHasSlidesAfterIndexing() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        guard generatorAvailable() else { return }
        let layout = makeLayout()
        _ = try await indexed(layout: layout)

        let deck = root.appendingPathComponent("Folien.pptx")
        #expect(layout.calls.contains { $0.standardizedFileURL == deck.standardizedFileURL }, "\(layout.calls)")
        let values = try deck.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = SlideCacheKey(url: deck, fileSize: Int64(try #require(values.fileSize)),
                                modifiedAt: try #require(values.contentModificationDate))
        let cache = SlideCache(root: cacheRoot)
        #expect(cache.slideCount(for: key) == 2) // visible slides only
        for slide in 0..<2 {
            let image = try #require(cache.image(for: key, slide: slide))
            #expect(max(image.width, image.height) == SlideCache.maxLongSide)
            #expect(image.width * 3 == image.height * 4)
        }
        // Only the deck has a cache entry (no leftover .tmp folder, nothing for the Word file).
        let names = try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)
        #expect(names == [key.id], "\(names)")
    }
}
