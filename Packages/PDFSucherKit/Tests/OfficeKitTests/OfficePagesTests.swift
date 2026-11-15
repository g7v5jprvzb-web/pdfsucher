import CoreGraphics
import Foundation
import IndexKit
import OutputKit
import PDFKit
import Testing
import TestSupport
@testable import OfficeKit

/// 1.3 Office Task 8: Office pages for thumbnails, the large preview and output (merge / print), and the combined
/// layout source. Slide tests fill the `SlideCache` directly instead of running Quick Look.
@Suite("Office pages")
struct OfficePagesTests {
    let dir: URL
    let cache: SlideCache
    let pages: OfficePages
    let deck: URL
    let word: URL
    let pdf: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        cache = SlideCache(root: dir.appendingPathComponent("SlideCache"))
        pages = OfficePages(cache: cache)
        deck = try OfficeFixtures.pptx(slides: ["Alpha", "Beta"], in: dir) // 720 × 540 pt
        word = try OfficeFixtures.docx(paragraphs: ["Kündigungsfrist für Herrn Müller", "Zweite Seite"],
                                       pageBreakAfter: [0], in: dir)
        pdf = dir.appendingPathComponent("A.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Alpha null"])
    }

    /// An opaque image with a dark block, so a rendered page has ink.
    private func slideImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    private func cacheSlides(of url: URL, count: Int = 2, width: Int = 2800, height: Int = 2100) throws {
        try cache.store((0..<count).map { _ in slideImage(width: width, height: height) },
                        for: QuickLookSlideSource.cacheKey(for: url))
    }

    private func size(_ page: PDFPage) -> CGSize { page.bounds(for: .mediaBox).size }

    // MARK: Merge

    @Test func mergerUsesForeignProviderForOffice() throws {
        try cacheSlides(of: deck)
        let doc = try Merger(foreign: pages).makeDocument([
            PageRef(url: pdf, pageIndex: 0), PageRef(url: deck, pageIndex: 1), PageRef(url: word, pageIndex: 0),
        ])
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 0)?.string?.contains("Alpha null") == true)
        let slide = try #require(doc.page(at: 1))
        #expect(size(slide) == CGSize(width: 720, height: 540))
        #expect(slide.string?.isEmpty ?? true)
        let wordPage = try #require(doc.page(at: 2))
        let expected = try TextKitWordDocument.cached(url: word).pageSize(0)
        #expect(abs(size(wordPage).width - expected.width) < 0.01 && abs(size(wordPage).height - expected.height) < 0.01,
                "\(size(wordPage)) vs \(expected)")
        #expect(wordPage.string?.contains("Müller") == true)
    }

    @Test func wordPageKeepsTextInOutput() throws {
        // Made inside an autorelease pool, so the one-page document it came from is gone afterwards; only the page
        // is held. Rendering and reading it afterwards must still work.
        var made: PDFPage?
        try autoreleasepool { made = try pages.makePage(PageRef(url: word, pageIndex: 0)) }
        let page = try #require(made)
        #expect(page.string?.contains("Müller") == true)
        #expect(page.string?.contains("Zweite") != true)
        let image = try #require(page.thumbnail(of: CGSize(width: 200, height: 300), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(Self.hasInk(image))
        let out = dir.appendingPathComponent("Wort.pdf")
        try Merger(foreign: pages).write([PageRef(url: word, pageIndex: 1), PageRef(url: word, pageIndex: 0)], to: out)
        let written = try #require(PDFDocument(url: out))
        #expect(written.pageCount == 2)
        #expect(written.page(at: 0)?.string?.contains("Zweite Seite") == true)
        #expect(written.page(at: 1)?.string?.contains("Müller") == true)
    }

    @Test func slidePageEmbedsCompressedImage() throws {
        try cacheSlides(of: deck)
        let page = try pages.makePage(PageRef(url: deck, pageIndex: 0))
        let data = try #require(page.dataRepresentation)
        #expect(data.firstRange(of: Data("/DCTDecode".utf8)) != nil)
        #expect(data.count < 1_000_000, "\(data.count) bytes")
    }

    /// Whether `image` has a pixel clearly darker than white.
    static func hasInk(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < 128 }
    }

    /// Pixel widths of the image XObjects on a page.
    static func embeddedImageWidths(_ page: PDFPage) -> [Int] {
        guard let dictionary = page.pageRef?.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?, xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return [] }
        final class Box { var widths: [Int] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(xObjects, { _, object, info in
            var stream: CGPDFStreamRef?
            var width: CGPDFInteger = 0
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
               CGPDFDictionaryGetInteger(dict, "Width", &width) {
                Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().widths.append(width)
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.widths
    }

    @Test func slideOutputHasAtLeast200dpi() throws {
        // 960 × 540 pt slide (fallback width, 16:9 cache image at the cache's long side).
        let wide = dir.appendingPathComponent("Breit.pptx")
        try Data("kein zip".utf8).write(to: wide)
        try cacheSlides(of: wide, count: 1, width: SlideCache.maxLongSide, height: SlideCache.maxLongSide * 9 / 16)
        let page = try pages.makePage(PageRef(url: wide, pageIndex: 0))
        #expect(size(page).width == 960)
        let widths = Self.embeddedImageWidths(page)
        try #require(widths.count == 1)
        let dpi = Double(widths[0]) / Double(size(page).width) * 72
        #expect(dpi >= 200, "\(dpi) dpi")
    }

    @Test func unavailableForeignPage() throws {
        try cacheSlides(of: deck)
        let notLaidOut = try OfficeFixtures.pptx(slides: ["Gamma"], name: "Neu.pptx", in: dir)
        let refs = [PageRef(url: word, pageIndex: 1), PageRef(url: word, pageIndex: 2), PageRef(url: deck, pageIndex: 1),
                    PageRef(url: deck, pageIndex: 2), PageRef(url: notLaidOut, pageIndex: 0), PageRef(url: pdf, pageIndex: 0)]
        #expect(Merger.unavailable(refs, foreign: pages) == [refs[1], refs[3], refs[4]])
        #expect(pages.pageCount(of: deck) == 2)
        #expect(pages.pageCount(of: notLaidOut) == nil)
        #expect(pages.pageCount(of: word) == 2)
        #expect(throws: OutputError.pageOutOfRange(refs[1])) { try pages.makePage(refs[1]) }
        #expect(throws: OutputError.cannotOpen(notLaidOut)) { try pages.makePage(refs[4]) }
    }

    @Test func handlesOfficeExtensionsOnly() {
        for name in ["a.docx", "a.DOC", "a.docm", "a.dotx", "a.pptx", "a.PPTM"] {
            #expect(pages.handles(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.pdf", "a.png", "a.ppt", "a.potx", "a.txt"] {
            #expect(!pages.handles(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    // MARK: Thumbnails and preview

    @Test func thumbnailNilWhenSlideNotCached() throws {
        #expect(pages.thumbnail(PageRef(url: deck, pageIndex: 0), maxPixel: 256) == nil)
        try cacheSlides(of: deck)
        #expect(pages.thumbnail(PageRef(url: deck, pageIndex: 2), maxPixel: 256) == nil)
        let image = try #require(pages.thumbnail(PageRef(url: deck, pageIndex: 1), maxPixel: 256))
        #expect(image.width == 256 && image.height == 192)
    }

    @Test func thumbnailNilForIncompleteCacheEntry() throws {
        try cacheSlides(of: deck)
        let key = try QuickLookSlideSource.cacheKey(for: deck)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("SlideCache/\(key.id)/0.heic"))
        #expect(cache.slideCount(for: key) == nil)
        #expect(pages.pageCount(of: deck) == nil)
        #expect(pages.thumbnail(PageRef(url: deck, pageIndex: 1), maxPixel: 256) == nil) // 1.heic is still there
    }

    @Test func slideSizeMemoMakesOncePerKeyAndIsCapped() {
        let memo = SlideSizeMemo(capacity: 2)
        func key(_ n: Int) -> SlideCacheKey {
            SlideCacheKey(url: URL(fileURLWithPath: "/tmp/\(n).pptx"), fileSize: 1, modifiedAt: .distantPast)
        }
        var calls = 0
        for _ in 0..<100 {
            #expect(memo.size(for: key(1)) { calls += 1; return CGSize(width: 720, height: 540) } == CGSize(width: 720, height: 540))
        }
        #expect(calls == 1)
        #expect(memo.size(for: key(2)) { () -> CGSize? in calls += 1; return nil } == nil)
        #expect(memo.size(for: key(2)) { () -> CGSize? in calls += 1; return nil } == nil)
        #expect(calls == 2)
        _ = memo.size(for: key(3)) { () -> CGSize? in calls += 1; return .zero }
        #expect(memo.count <= 2)
    }

    @Test func wordThumbnail() throws {
        let image = try #require(pages.thumbnail(PageRef(url: word, pageIndex: 0), maxPixel: 300))
        #expect(max(image.width, image.height) == 300)
        #expect(pages.thumbnail(PageRef(url: word, pageIndex: 5), maxPixel: 300) == nil)
        #expect(pages.thumbnail(PageRef(url: dir.appendingPathComponent("weg.docx"), pageIndex: 0), maxPixel: 300) == nil)
    }

    @Test func previewPageSizeMatchesSlide() throws {
        #expect(pages.previewPage(PageRef(url: deck, pageIndex: 0)) == nil)
        try cacheSlides(of: deck)
        let page = try #require(pages.previewPage(PageRef(url: deck, pageIndex: 0)))
        #expect(size(page) == CGSize(width: 720, height: 540))
        let wordPage = try #require(pages.previewPage(PageRef(url: word, pageIndex: 0)))
        #expect(wordPage.string?.contains("Müller") == true)
    }

    @Test func slideSizeFromPresentationXML() throws {
        #expect(PresentationSlides.slideSize(of: deck) == CGSize(width: 720, height: 540))
        let notZip = dir.appendingPathComponent("Kaputt.pptx")
        try Data("kein zip".utf8).write(to: notZip)
        #expect(PresentationSlides.slideSize(of: notZip) == nil)
    }

    @Test func slideSizeFallsBackToImageAspect() throws {
        // A cache entry for a file whose package cannot be read (any more): 16:9 image → 960 × 540 pt.
        let damaged = dir.appendingPathComponent("Kaputt.pptx")
        try Data("kein zip".utf8).write(to: damaged)
        try cacheSlides(of: damaged, count: 1, width: 2800, height: 1575)
        let page = try pages.makePage(PageRef(url: damaged, pageIndex: 0))
        #expect(size(page).width == 960)
        #expect(abs(size(page).height - 540) < 0.5)
    }

    // MARK: Combined layout source

    struct RecordingSource: PageLayoutSource {
        let name: String
        let calls: Calls
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var kinds: [DocumentKind] = []
            func add(_ kind: DocumentKind) { lock.withLock { kinds.append(kind) } }
            var all: [DocumentKind] { lock.withLock { kinds } }
        }

        func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name, 7) }

        func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
            calls.add(kind)
            return LayoutResult(pages: [], renderer: name, layoutVersion: 7)
        }
    }

    @Test func dispatchByKind() async throws {
        let slideCalls = RecordingSource.Calls(), wordCalls = RecordingSource.Calls()
        let source = OfficeLayoutSource(powerpoint: RecordingSource(name: "folien", calls: slideCalls),
                                        word: RecordingSource(name: "wort", calls: wordCalls))
        #expect(try await source.layout(of: deck, kind: .powerpoint).renderer == "folien")
        #expect(try await source.layout(of: word, kind: .word).renderer == "wort")
        #expect(slideCalls.all == [.powerpoint])
        #expect(wordCalls.all == [.word])
        await #expect(throws: LayoutSourceError.self) { try await source.layout(of: pdf, kind: .pdf) }
        #expect(slideCalls.all.count == 1 && wordCalls.all.count == 1)
        #expect(source.renderer(for: .powerpoint).name == "folien")
        #expect(source.renderer(for: .word).name == "wort")
        let real = OfficeLayoutSource()
        #expect(real.renderer(for: .powerpoint) == ("quicklook", 1))
        #expect(real.renderer(for: .word) == ("textkit", 1))
    }

    // MARK: Page documents (1.3 Teil B)

    @Test func slidePageDocumentUsesSmallImage() throws {
        try cacheSlides(of: deck) // 2800 px
        let doc = try #require(pages.pageDocument(PageRef(url: deck, pageIndex: 1), maxPixel: 400))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        #expect(size(page) == CGSize(width: 720, height: 540)) // p:sldSz
        let widths = Self.embeddedImageWidths(page)
        #expect(widths.count == 1 && widths.allSatisfy { $0 <= 400 }, "\(widths)")
        // Without maxPixel: the output page (full image).
        let full = try #require(pages.pageDocument(PageRef(url: deck, pageIndex: 1), maxPixel: nil)?.page(at: 0))
        #expect(size(full) == CGSize(width: 720, height: 540))
        #expect(Self.embeddedImageWidths(full) == [2800])
        // Word: the vector page, whatever maxPixel.
        let wordDoc = try #require(pages.pageDocument(PageRef(url: word, pageIndex: 0), maxPixel: 400))
        #expect(wordDoc.pageCount == 1 && wordDoc.page(at: 0)?.string?.contains("Müller") == true)
    }

    @Test func pageDocumentNilWhenSlideNotCached() throws {
        #expect(pages.pageDocument(PageRef(url: deck, pageIndex: 0), maxPixel: 400) == nil)
        #expect(pages.pageDocument(PageRef(url: deck, pageIndex: 0), maxPixel: nil) == nil)
        try cacheSlides(of: deck)
        #expect(pages.pageDocument(PageRef(url: deck, pageIndex: 2), maxPixel: 400) == nil)
        #expect(pages.pageDocument(PageRef(url: deck, pageIndex: -1), maxPixel: 400) == nil)
        #expect(pages.pageDocument(PageRef(url: word, pageIndex: 5), maxPixel: 400) == nil)
    }

    /// 1.3 Teil B Task 13: tiles of an older layout (renderer, slide cache) are not shown after a relayout.
    @Test func contentVersionNamesRendererAndSlideCache() throws {
        #expect(pages.contentVersion(word).hasPrefix("textkit:1"))   // "+fonts" once registered (WordFontStateTests)
        let before = pages.contentVersion(deck)
        #expect(before.hasPrefix("quicklook:1"))
        try cacheSlides(of: deck)
        let after = pages.contentVersion(deck)
        #expect(after.hasPrefix("quicklook:1") && after != before)
        #expect(pages.contentVersion(pdf) == "")
    }
}
