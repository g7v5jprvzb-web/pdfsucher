// SlideKitAdapterTests.swift — SlideKit adapter: layout source, page provider, tile hook, deck cache.
import AppKit
import Foundation
import PDFKit
import Testing
import IndexKit
import OOXMLKit
import OutputKit
import SearchKit
import TestSupport
import ViewerUI
@testable import SlideKit
@testable import SlideKitAdapter

/// A temporary folder removed when the value dies.
private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("slidekit-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Fixture decks from `OfficeFixtures.pptx` (720 × 540 pt, one text box per slide).
private enum Decks {
    static let texts = ["Erste Folie mit Text", "Versteckt", "Dritte Folie Angebot"]

    /// Three slides, the second hidden → two visible.
    static func basic(in dir: URL, name: String = "Folien.pptx") throws -> URL {
        try OfficeFixtures.pptx(slides: texts, hidden: [1], name: name, in: dir)
    }

    /// One slide whose runs name a font that is not installed: `.powerPoint` and `.similar` draw it differently.
    static func missingFont(in dir: URL) throws -> URL {
        let plain = try OfficeFixtures.pptx(slides: ["Wirtschaftlichkeitsberechnung und Angebotsübersicht für Kunden"],
                                            name: "plain.pptx", in: dir)
        let zip = try ZipArchive(url: plain)
        var builder = OOXMLBuilder()
        for name in zip.entryNames {
            var data = try zip.data(name)
            if name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml") {
                let xml = String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: #"<a:rPr lang="de-DE" sz="2800"/>"#,
                    with: #"<a:rPr lang="de-DE" sz="2800"><a:latin typeface="Fictional Corporate Sans Wide"/></a:rPr>"#)
                data = Data(xml.utf8)
            }
            builder.add(name, String(decoding: data, as: UTF8.self))
        }
        let url = dir.appendingPathComponent("Firmenschrift.pptx")
        try builder.write(to: url)
        return url
    }

    static func garbage(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("kaputt.pptx")
        try Data("not a zip".utf8).write(to: url)
        return url
    }
}

@Suite struct SlideKitLayoutSourceTests {
    @Test func onePagePerVisibleSlideWithTextWordsAndSize() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let source = SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let result = try await source.layout(of: url, kind: .powerpoint)
        #expect(result.renderer == "slidekit")
        #expect(result.layoutVersion == SlideKitLayoutSource.layoutVersion(for: .powerPoint))
        #expect(result.pages.count == 2)
        let deck = try SlideDeck(url: url)
        for (i, page) in result.pages.enumerated() {
            #expect(page.size == CGSize(width: 720, height: 540))
            #expect(page.text == deck.slideText(i))
            #expect(!page.words.isEmpty)
            for word in page.words {
                #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(word.box))
                #expect(NSMaxRange(word.range) <= (page.text as NSString).length)
            }
        }
        #expect(result.pages[0].text.localizedCaseInsensitiveContains("erste folie"))
        #expect(result.pages[1].text.localizedCaseInsensitiveContains("dritte folie"))
        // Word boxes sit in the upper part of the slide, where the text box is (origin top left).
        #expect(result.pages[0].words.allSatisfy { $0.box.minY < 0.5 })
    }

    @Test func versionDependsOnFontSubstitution() {
        let pp = SlideKitLayoutSource(fontSubstitution: .powerPoint)
        let similar = SlideKitLayoutSource(fontSubstitution: .similar)
        #expect(pp.renderer(for: .powerpoint).name == "slidekit")
        #expect(similar.renderer(for: .powerpoint).name == "slidekit")
        #expect(pp.renderer(for: .powerpoint).version != similar.renderer(for: .powerpoint).version)
        #expect(pp.renderer(for: .powerpoint).version == 101)
        #expect(similar.renderer(for: .powerpoint).version == 102)
        #expect(pp.renderer(for: .word) == ("none", 0))
        #expect(pp.renderer(for: .pdf) == ("none", 0))
    }

    @Test func fontSubstitutionChangesTheLayout() async throws {
        let tmp = try TempDir()
        let url = try Decks.missingFont(in: tmp.url)
        let decks = SlideDeckCache()
        let pp = try await SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: decks).layout(of: url, kind: .powerpoint)
        let similar = try await SlideKitLayoutSource(fontSubstitution: .similar, decks: decks).layout(of: url, kind: .powerpoint)
        #expect(pp.pages[0].text == similar.pages[0].text)
        #expect(pp.pages[0].words.map(\.box) != similar.pages[0].words.map(\.box))
        #expect(pp.layoutVersion != similar.layoutVersion)
        #expect(decks.count == 2)
    }

    @Test func otherKindsAndUnreadableFilesAreUnreadable() async throws {
        let tmp = try TempDir()
        let source = SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let deck = try Decks.basic(in: tmp.url)
        await #expect(throws: LayoutSourceError.unreadable(deck, reason: SlideKitLayoutSource.notPowerPointReason)) {
            try await source.layout(of: deck, kind: .word)
        }
        let garbage = try Decks.garbage(in: tmp.url)
        await #expect(throws: LayoutSourceError.unreadable(garbage, reason: SlideKitLayoutSource.unreadableReason)) {
            try await source.layout(of: garbage, kind: .powerpoint)
        }
    }

    @Test func missingFilePropagatesForARetry() async throws {
        let tmp = try TempDir()
        let gone = tmp.url.appendingPathComponent("weg.pptx")
        let source = SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        await #expect {
            try await source.layout(of: gone, kind: .powerpoint)
        } throws: { !($0 is LayoutSourceError) }
    }

    @Test func honoursCancellation() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let source = SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.layout(of: url, kind: .powerpoint)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func plugsIntoTheIndexerAsOfficePowerPointSource() async throws {
        // Through the IndexKit protocol only, as the Indexer sees it.
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let source: any PageLayoutSource = SlideKitLayoutSource(fontSubstitution: .similar, decks: SlideDeckCache())
        let result = try await source.layout(of: url, kind: .powerpoint)
        #expect(result.renderer == source.renderer(for: .powerpoint).name)
        #expect(result.layoutVersion == source.renderer(for: .powerpoint).version)
    }
}

/// Stands in for `OfficePages` (Word) behind `SlideKitPages`.
private struct WordStub: ForeignPageProvider {
    func handles(_ url: URL) -> Bool { url.pathExtension == "docx" }
    func pageCount(of url: URL) -> Int? { 3 }
    func makePage(_ ref: PageRef) throws -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        return page
    }
    func contentVersion(_ url: URL) -> String { "textkit:1" }
}

@Suite struct SlideKitPagesTests {
    @Test func pagesExistWithoutALayoutRun() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let pages = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        #expect(pages.handles(url))
        #expect(pages.pageCount(of: url) == 2)
        let page = try pages.makePage(PageRef(url: url, pageIndex: 1))
        let slide = try #require(page as? SlidePDFPage)
        #expect(slide.bounds(for: .mediaBox).size == CGSize(width: 720, height: 540))
        #expect(slide.string?.localizedCaseInsensitiveContains("dritte folie") == true)
        #expect(slide.deck.fontSubstitution == .powerPoint)
        #expect(pages.previewPage(PageRef(url: url, pageIndex: 0)) != nil)
        let thumb = try #require(pages.thumbnail(PageRef(url: url, pageIndex: 0), maxPixel: 200))
        #expect(thumb.width == 200 && thumb.height == 150)
    }

    @Test func outOfRangeAndUnreadable() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let pages = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let past = PageRef(url: url, pageIndex: 2)
        #expect(throws: OutputError.pageOutOfRange(past)) { try pages.makePage(past) }
        #expect(throws: OutputError.pageOutOfRange(PageRef(url: url, pageIndex: -1))) {
            try pages.makePage(PageRef(url: url, pageIndex: -1))
        }
        #expect(pages.pageDocument(past, maxPixel: nil) == nil)
        #expect(pages.thumbnail(past, maxPixel: 100) == nil)
        let garbage = try Decks.garbage(in: tmp.url)
        #expect(pages.pageCount(of: garbage) == nil)
        #expect(throws: OutputError.cannotOpen(garbage)) { try pages.makePage(PageRef(url: garbage, pageIndex: 0)) }
    }

    @Test func otherFilesGoToTheFallback() throws {
        let docx = URL(fileURLWithPath: "/tmp/Brief.docx")
        let pdf = URL(fileURLWithPath: "/tmp/Scan.pdf")
        let alone = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        #expect(!alone.handles(docx))
        #expect(alone.pageCount(of: docx) == nil)
        #expect(alone.contentVersion(docx) == "")
        #expect(throws: OutputError.cannotOpen(docx)) { try alone.makePage(PageRef(url: docx, pageIndex: 0)) }
        let routed = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache(), fallback: WordStub())
        #expect(routed.handles(docx))
        #expect(!routed.handles(pdf))
        #expect(routed.pageCount(of: docx) == 3)
        #expect(routed.contentVersion(docx) == "textkit:1")
        #expect(try routed.makePage(PageRef(url: docx, pageIndex: 0)).bounds(for: .mediaBox).width == 595)
        #expect(routed.pageDocument(PageRef(url: docx, pageIndex: 0), maxPixel: 100)?.pageCount == 1)
        #expect(throws: OutputError.cannotOpen(pdf)) { try routed.makePage(PageRef(url: pdf, pageIndex: 0)) }
    }

    @Test func contentVersionFollowsTheFontSetting() throws {
        let url = URL(fileURLWithPath: "/tmp/Folien.pptx")
        let pp = SlideKitPages(fontSubstitution: .powerPoint).contentVersion(url)
        let similar = SlideKitPages(fontSubstitution: .similar).contentVersion(url)
        #expect(pp == "slidekit:101:r1")
        #expect(similar == "slidekit:102:r1")
    }

    @Test func mergedOutputKeepsSlideText() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let pages = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let refs = [PageRef(url: url, pageIndex: 1), PageRef(url: url, pageIndex: 0)]
        #expect(Merger.unavailable(refs, foreign: pages).isEmpty)
        let out = tmp.url.appendingPathComponent("merged.pdf")
        try Merger(foreign: pages).write(refs, to: out)
        let merged = try #require(PDFDocument(url: out))
        #expect(merged.pageCount == 2)
        let texts = (0..<merged.pageCount).map { merged.page(at: $0)?.string ?? "" }
        #expect(texts[0].localizedCaseInsensitiveContains("Folie Angebot"), "\(texts)")
        #expect(texts[1].localizedCaseInsensitiveContains("Erste Folie mit Text"), "\(texts)")
        // Calibri's "tt" ligature kept its text since SlideKit draws without standard ligatures (slidekit-ligatures).
        #expect(texts[0].localizedCaseInsensitiveContains("Dritte Folie"), "\(texts)")
    }
}

@Suite struct SlideKitTileTests {
    /// Share of non-white pixels of an image.
    private static func inkShare(_ image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var ink = 0
        for i in 0..<(cg.width * cg.height) where bytes[i * 4] < 200 || bytes[i * 4 + 1] < 200 || bytes[i * 4 + 2] < 200 {
            ink += 1
        }
        return Double(ink) / Double(cg.width * cg.height)
    }

    @Test func thumbnailCacheDrawsSlideTilesThroughTheProvider() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let cache = ThumbnailCache(scale: 1, foreign: SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache()))
        let tile = try #require(await cache.thumbnail(for: PageRef(url: url, pageIndex: 1), size: CGSize(width: 320, height: 240)))
        let share = Self.inkShare(tile)
        #expect(share > 0.002, "the slide text must be drawn (ink \(share))")
        #expect(share < 0.5)
        #expect(await cache.thumbnail(for: PageRef(url: url, pageIndex: 5), size: CGSize(width: 320, height: 240)) == nil)
    }

    /// Pixels of a tile that show the yellow highlight over white (multiplied), as (count, bounding box in pixels,
    /// origin top left).
    private static func yellow(_ image: NSImage) -> (count: Int, box: CGRect) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, .null) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0, box = CGRect.null
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                if bytes[i] > 200, bytes[i + 1] > 180, bytes[i + 2] < 170 {
                    count += 1
                    box = box.union(CGRect(x: x, y: y, width: 1, height: 1))   // bitmap rows run top-down
                }
            }
        }
        return (count, box)
    }

    /// Wiring rule: highlights on SlideKit tiles come from the stored word boxes (OCR path), not from a PDFSelection.
    @Test func highlightsOnSlideTilesComeFromStoredWordBoxes() async throws {
        let tmp = try TempDir()
        let url = try OfficeFixtures.pptx(slides: ["Angebot Wasserwerk"], name: "Markiert.pptx", in: tmp.url)
        let laid = try await SlideKitLayoutSource(fontSubstitution: .powerPoint, decks: SlideDeckCache())
            .layout(of: url, kind: .powerpoint).pages[0]
        let word = try #require(laid.words.first { (laid.text as NSString).substring(with: $0.range) == "Wasserwerk" })
        let ocr = OCRPageText(text: laid.text, words: laid.words)
        let ranges: HighlightRanges = { text in text.range(of: "Wasserwerk").map { [$0] } ?? [] }
        let cache = ThumbnailCache(scale: 1, foreign: SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache()))
        let ref = PageRef(url: url, pageIndex: 0), size = CGSize(width: 720, height: 540)

        let plain = try #require(await cache.thumbnail(for: ref, size: size))
        #expect(Self.yellow(plain).count == 0)
        let marked = try #require(await cache.thumbnail(for: ref, size: size, highlightKey: "Wasserwerk",
                                                        highlightRanges: ranges, ocr: ocr))
        let found = Self.yellow(marked)
        #expect(found.count > 200, "highlight drawn (\(found.count) px)")
        // Where the stored box says (0…1, origin top left; tile = slide size here, 1 pt = 1 px).
        let expected = CGRect(x: word.box.minX * 720, y: word.box.minY * 540, width: word.box.width * 720, height: word.box.height * 540)
        #expect(expected.insetBy(dx: -12, dy: -12).contains(CGPoint(x: found.box.midX, y: found.box.midY)),
                "mark \(found.box) vs word box \(expected)")
    }

    @Test func pageDocumentIsVectorAtAnySize() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let pages = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache())
        let small = try #require(pages.pageDocument(PageRef(url: url, pageIndex: 0), maxPixel: 64))
        #expect(small.pageCount == 1)
        #expect(small.page(at: 0) is SlidePDFPage)
        #expect(small.page(at: 0)?.bounds(for: .cropBox).size == CGSize(width: 720, height: 540))
    }
}

@Suite struct SlideDeckCacheTests {
    @Test func reusesTheDeckPerFileVersionAndSetting() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let cache = SlideDeckCache()
        let a = try cache.deck(for: url, fontSubstitution: .powerPoint)
        let b = try cache.deck(for: url, fontSubstitution: .powerPoint)
        #expect(a.store === b.store)
        let c = try cache.deck(for: url, fontSubstitution: .similar)
        #expect(a.store !== c.store)
        #expect(c.fontSubstitution == .similar)
        #expect(cache.count == 2)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func aChangedFileOpensANewDeck() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let cache = SlideDeckCache()
        let old = try cache.deck(for: url, fontSubstitution: .powerPoint)
        #expect(old.slideCount == 2)
        try FileManager.default.removeItem(at: url)
        try OfficeFixtures.pptx(slides: ["Eins", "Zwei", "Drei", "Vier"], name: url.lastPathComponent, in: tmp.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(try cache.deck(for: url, fontSubstitution: .powerPoint).slideCount == 4)
    }

    /// 1.3.2: a deck at tile/preview size keeps up to ~375 MB of decoded images (docs/performance.md), so the shared
    /// cache keeps two decks, not four.
    @Test func sharedCacheKeepsTwoDecks() {
        #expect(SlideDeckCache.shared.capacity == 2)
    }

    @Test func dropsTheLeastRecentlyUsedDeck() throws {
        let tmp = try TempDir()
        let urls = try (0..<3).map { try Decks.basic(in: tmp.url, name: "d\($0).pptx") }
        let cache = SlideDeckCache(capacity: 2)
        let first = try cache.deck(for: urls[0], fontSubstitution: .powerPoint)
        _ = try cache.deck(for: urls[1], fontSubstitution: .powerPoint)
        _ = try cache.deck(for: urls[0], fontSubstitution: .powerPoint) // urls[0] is now the most recent
        _ = try cache.deck(for: urls[2], fontSubstitution: .powerPoint) // drops urls[1]
        #expect(cache.count == 2)
        #expect(try cache.deck(for: urls[0], fontSubstitution: .powerPoint).store === first.store)
    }

    @Test func remembersUnreadablePackagesApartFromDecks() throws {
        let tmp = try TempDir()
        let garbage = try Decks.garbage(in: tmp.url)
        let cache = SlideDeckCache(capacity: 1, failureCapacity: 2)
        let good = try Decks.basic(in: tmp.url)
        let deck = try cache.deck(for: good, fontSubstitution: .powerPoint)
        #expect(throws: SlideKitError.self) { try cache.deck(for: garbage, fontSubstitution: .powerPoint) }
        #expect(throws: SlideKitError.self) { try cache.deck(for: garbage, fontSubstitution: .powerPoint) }
        #expect(cache.failureCount == 1)
        #expect(cache.count == 1) // a damaged file does not push the deck out
        #expect(try cache.deck(for: good, fontSubstitution: .powerPoint).store === deck.store)
        let gone = tmp.url.appendingPathComponent("weg.pptx")
        #expect(throws: (any Error).self) { try cache.deck(for: gone, fontSubstitution: .powerPoint) }
        #expect(cache.failureCount == 1)
    }

    @Test func aFileThatCannotBeReadIsAFileErrorAndNotRemembered() throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let cache = SlideDeckCache()
        #expect { try cache.deck(for: url, fontSubstitution: .powerPoint) } throws: { !($0 is SlideKitError) }
        #expect(cache.failureCount == 0 && cache.count == 0)
        // Readable again with the same size and date: opens now.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try cache.deck(for: url, fontSubstitution: .powerPoint).slideCount == 2)
    }

    @Test func aSymbolicLinkOpensByItsOwnName() throws {
        let tmp = try TempDir()
        let target = try Decks.basic(in: tmp.url, name: "ohne-endung.bin")
        let link = tmp.url.appendingPathComponent("Verweis.pptx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = SlideDeckCache()
        #expect(try cache.deck(for: link, fontSubstitution: .powerPoint).slideCount == 2)
    }

    @Test func concurrentRequestsShareOneDeck() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        let cache = SlideDeckCache()
        let stores = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? cache.deck(for: url, fontSubstitution: .powerPoint)).map { ObjectIdentifier($0.store) } }
            }
            var ids: [ObjectIdentifier?] = []
            for await id in group { ids.append(id) }
            return ids
        }
        #expect(stores.count == 8 && !stores.contains(nil))
        #expect(Set(stores).count == 1)
        #expect(cache.count == 1)
    }
}

@Suite struct SlideKitLayoutCachingTests {
    @Test func layoutWithoutACacheLeavesTheSharedDecksAlone() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        // Other suites in this process use `SlideDeckCache.shared` too: look for this file's deck, not at the count.
        let result = try await SlideKitLayoutSource(fontSubstitution: .powerPoint).layout(of: url, kind: .powerpoint)
        #expect(result.pages.count == 2)
        #expect(!SlideDeckCache.shared.contains(url, fontSubstitution: .powerPoint))
        let own = SlideDeckCache()                                  // the check does see a deck (own cache: no race)
        _ = try own.deck(for: url, fontSubstitution: .powerPoint)
        #expect(own.contains(url, fontSubstitution: .powerPoint))
    }

    @Test func unreadableFileIsRetriedNotMarkedBroken() async throws {
        let tmp = try TempDir()
        let url = try Decks.basic(in: tmp.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        await #expect {
            try await SlideKitLayoutSource(fontSubstitution: .powerPoint).layout(of: url, kind: .powerpoint)
        } throws: { !($0 is LayoutSourceError) }
    }
}
