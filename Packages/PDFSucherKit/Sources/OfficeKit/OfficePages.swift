// OfficePages.swift — 1.3 Office Task 8: Word and PowerPoint pages for thumbnails, the large preview and output.
import CoreGraphics
import Foundation
import ImageIO
import IndexKit
import OSLog
import OutputKit
import PDFKit
import Synchronization

/// Pages of Office documents for the viewer and for `Merger`/`Printer` (as their `ForeignPageProvider`).
///
/// PowerPoint pages come only from the `SlideCache`, filled when the deck was laid out (`QuickLookSlideSource`, same
/// cache key): a deck that is not laid out yet (or whose file changed since) has no pages here — `pageCount(of:)` nil,
/// so `Merger.unavailable` lists them; no thumbnail (caller shows a placeholder), no preview. A slide page is the cached
/// image, embedded as JPEG, on a page of slide size without margin (`p:sldSz`; fallback 960 pt wide in the image's
/// aspect, spec §5a). Word pages come from `TextKitWordDocument.cached`: output and preview pages are vector pages
/// whose text stays text.
///
/// Stateless besides the cache; safe from any thread.
public struct OfficePages: ForeignPageProvider {
    /// Width of a slide page when the deck's slide size cannot be read (16:9 → 960 × 540 pt).
    static let fallbackSlideWidth: CGFloat = 960
    static let jpegQuality = 0.9

    private static let log = Logger(subsystem: "PDFSucher", category: "OfficePages")

    private let cache: SlideCache
    private let renderers: any PageLayoutSource
    /// `p:sldSz` per cache key, so merging many slides of one deck opens its package once.
    private let slideSizes = SlideSizeMemo()

    /// - Parameter renderers: whose PowerPoint/Word renderer names go into `contentVersion` (the app passes its layout
    ///   source, so tiles follow „PowerPoint-Darstellung“).
    /// Office's font registration, whose state goes into Word's `contentVersion`.
    private let fontGate: FontRegistrationGate

    public init(cache: SlideCache = .shared, renderers: any PageLayoutSource = OfficeLayoutSource()) {
        self.init(cache: cache, renderers: renderers, fontGate: .shared)
    }

    /// Tests: another registration gate.
    init(cache: SlideCache, renderers: any PageLayoutSource, fontGate: FontRegistrationGate) {
        self.cache = cache
        self.renderers = renderers
        self.fontGate = fontGate
    }

    private static func kind(of url: URL) -> DocumentKind? { DocumentKind(fileExtension: url.pathExtension) }

    public func handles(_ url: URL) -> Bool { Self.kind(of: url)?.isOffice == true }

    public func pageCount(of url: URL) -> Int? {
        switch Self.kind(of: url) {
        case .powerpoint: return (try? QuickLookSlideSource.cacheKey(for: url)).flatMap(cache.slideCount(for:))
        case .word: return (try? TextKitWordDocument.cached(url: url))?.pageCount
        default: return nil
        }
    }

    /// Throws `OutputError.cannotOpen` for an unreadable (or not laid out) file and `pageOutOfRange` for a page it
    /// does not have.
    public func makePage(_ ref: PageRef) throws -> PDFPage {
        switch Self.kind(of: ref.url) {
        case .powerpoint:
            guard let key = try? QuickLookSlideSource.cacheKey(for: ref.url),
                  let count = cache.slideCount(for: key) else { throw OutputError.cannotOpen(ref.url) }
            guard ref.pageIndex >= 0, ref.pageIndex < count else { throw OutputError.pageOutOfRange(ref) }
            guard let image = cache.image(for: key, slide: ref.pageIndex),
                  let page = Self.slidePage(image, size: slideSize(of: ref.url, key: key, image: image)) else {
                Self.log.error("Cannot build slide page \(ref.pageIndex) of \(ref.url.path, privacy: .private)")
                throw OutputError.cannotOpen(ref.url)
            }
            return page
        case .word:
            guard let document = try? TextKitWordDocument.cached(url: ref.url) else { throw OutputError.cannotOpen(ref.url) }
            guard ref.pageIndex >= 0, ref.pageIndex < document.pageCount else { throw OutputError.pageOutOfRange(ref) }
            guard let page = Self.wordPage(document, index: ref.pageIndex) else {
                Self.log.error("Cannot build Word page \(ref.pageIndex) of \(ref.url.path, privacy: .private)")
                throw OutputError.cannotOpen(ref.url)
            }
            return page
        default:
            throw OutputError.cannotOpen(ref.url)
        }
    }

    /// What the pages of `url` are drawn from beyond its date and size (1.3 Teil B: part of the tile key, so a relayout
    /// without a file change shows new tiles): `renderer:version` of the layout source for the kind (`OfficeLayoutSource`),
    /// for PowerPoint plus the slide-cache entry (`|slides:n`, or `|-` while not cached), for Word plus `+fonts` once
    /// Office's fonts are complete (`FontRegistrationGate.isComplete`) (1.3.2: a tile drawn with substitute fonts before it is not reused after it,
    /// in memory or on disk). "" for other files.
    /// The renderer names come from `renderers` (default `OfficeLayoutSource()`, which follows the shared setting); keep
    /// it the layout source the Indexer uses (or tiles of a newer layout would keep the old version).
    public func contentVersion(_ url: URL) -> String {
        guard let kind = Self.kind(of: url), kind.isOffice else { return "" }
        let renderer = renderers.renderer(for: kind)
        let base = "\(renderer.name):\(renderer.version)"
        guard kind == .powerpoint else { return fontGate.isComplete ? base + "+fonts" : base }
        let count = (try? QuickLookSlideSource.cacheKey(for: url)).flatMap(cache.slideCount(for:))
        return base + (count.map { "|slides:\($0)" } ?? "|-")
    }

    /// The page as an image, long side `maxPixel`: a slide from the cache (nil when not cached), a Word page drawn on
    /// white. Nil for an unreadable file or a page it does not have.
    public func thumbnail(_ ref: PageRef, maxPixel: Int) -> CGImage? {
        guard ref.pageIndex >= 0 else { return nil }
        switch Self.kind(of: ref.url) {
        case .powerpoint:
            // Same rule as `pageCount`/`makePage`: only a complete entry has pages.
            guard let key = try? QuickLookSlideSource.cacheKey(for: ref.url),
                  let count = cache.slideCount(for: key), ref.pageIndex < count else { return nil }
            return cache.image(for: key, slide: ref.pageIndex, maxPixel: maxPixel)
        case .word:
            guard let document = try? TextKitWordDocument.cached(url: ref.url), ref.pageIndex < document.pageCount else {
                return nil
            }
            return document.thumbnail(ref.pageIndex, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    /// A one-page PDF page for the large preview, the same as in output (`makePage`); nil when there is none.
    public func previewPage(_ ref: PageRef) -> PDFPage? {
        try? makePage(ref)
    }

    /// A one-page document for display (1.3 Teil B). PowerPoint with `maxPixel`: a page of slide size drawing the
    /// cached slide decoded at long side `maxPixel` (`SlideCache.image(for:slide:maxPixel:)`), without the JPEG
    /// re-encoding of output pages; nil when the deck is not (completely) cached or has no such slide. Word, or no
    /// `maxPixel`: the output page (`makePage`) — Word pages are vector pages, small at any size.
    public func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
        guard ref.pageIndex >= 0 else { return nil }
        guard let maxPixel, Self.kind(of: ref.url) == .powerpoint else {
            guard let page = try? makePage(ref) else { return nil }
            let document = PDFDocument()
            document.insert(page, at: 0)
            return document
        }
        guard let key = try? QuickLookSlideSource.cacheKey(for: ref.url),
              let count = cache.slideCount(for: key), ref.pageIndex < count,
              let image = cache.image(for: key, slide: ref.pageIndex, maxPixel: maxPixel) else { return nil }
        return Self.slideDocument(image, size: slideSize(of: ref.url, key: key, image: image), embedJPEG: false)
    }

    // MARK: Pages

    /// `p:sldSz` of the deck (memoized per cache key); if the package cannot be read, 960 pt wide in the image's aspect.
    private func slideSize(of url: URL, key: SlideCacheKey, image: CGImage) -> CGSize {
        if let size = slideSizes.size(for: key, make: { PresentationSlides.slideSize(of: url) }) { return size }
        let height = Self.fallbackSlideWidth * CGFloat(image.height) / CGFloat(max(1, image.width))
        return CGSize(width: Self.fallbackSlideWidth, height: height)
    }

    /// `image` filling a page of `size` (aspect-fit and centred, should the aspects differ), embedded as JPEG.
    static func slidePage(_ image: CGImage, size: CGSize) -> PDFPage? {
        slideDocument(image, size: size, embedJPEG: true)?.page(at: 0)
    }

    /// One-page document of `image` filling a page of `size`; `embedJPEG` re-encodes it first (output pages).
    static func slideDocument(_ image: CGImage, size: CGSize, embedJPEG: Bool) -> PDFDocument? {
        let embedded = embedJPEG ? (jpeg(image) ?? image) : image
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                            width: drawn.width, height: drawn.height)
        return onePageDocument(size: size) { context in
            context.interpolationQuality = .high
            context.draw(embedded, in: target)
        }
    }

    /// Word page `index` as a vector page: TextKit draws into a PDF context, so the text stays text.
    static func wordPage(_ document: TextKitWordDocument, index: Int) -> PDFPage? {
        onePageDocument(size: document.pageSize(index)) { document.draw(page: index, in: $0) }?.page(at: 0)
    }

    /// A one-page PDF drawn by `draw`. PDFKit keeps its page usable after the document is released.
    private static func onePageDocument(size: CGSize, draw: (CGContext) -> Void) -> PDFDocument? {
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// `image` re-encoded as JPEG, so the PDF context embeds DCT data instead of raw pixels (as `ImagePages`).
    private static func jpeg(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Thread-safe memo of slide sizes (nil = package unreadable) per cache key, at most `capacity` entries; when full it
/// starts over (a merge touches few decks). A changed file has a new key, so an entry never goes stale.
final class SlideSizeMemo: Sendable {
    private let capacity: Int
    private let entries = Mutex<[SlideCacheKey: CGSize?]>([:])

    init(capacity: Int = 64) {
        precondition(capacity > 0, "SlideSizeMemo: Kapazität muss positiv sein")
        self.capacity = capacity
    }

    /// The memoized size for `key`, or `make()`'s result (run outside the lock), stored.
    func size(for key: SlideCacheKey, make: () -> CGSize?) -> CGSize? {
        if let hit = entries.withLock({ $0[key] }) { return hit }
        let size = make()
        entries.withLock { entries in
            if entries.count >= capacity { entries.removeAll() }
            entries[key] = .some(size)
        }
        return size
    }

    var count: Int { entries.withLock { $0.count } }
}
