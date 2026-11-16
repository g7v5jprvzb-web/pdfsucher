// ThumbnailCache.swift — Task 4.2
import AppKit
import ImageIO
import Foundation
import OutputKit
import SearchKit
import PDFKit
import os
import Synchronization

/// Given the page text exactly as PDFKit reports it (`PDFPage.string`), returns the ranges to
/// highlight. The ranges must be indices into the string passed in. The app passes
/// `AppCore.Highlighter.make(query)`, so tiles mark exactly what the search matched (also words
/// split across a line break).
public typealias HighlightRanges = @Sendable (String) -> [Range<String.Index>]

/// Renders page thumbnails with yellow match highlights off the main actor and keeps them in an
/// LRU cache bounded by count and bytes, optionally backed by a `TileDiskCache` (spec 1.2.3).
///
/// Rendering runs in parallel on `TileRenderQueue`'s threads: visible tiles before prefetched ones,
/// newest first; a request whose task is cancelled (tile scrolled away) is dropped before it starts.
/// A cached image is returned without waiting behind any rendering. Open `PDFDocument`s are pooled
/// per file (one per render thread at most, a small LRU of files); a file is reopened when it
/// changes on disk.
///
/// `nil` means "no thumbnail": file missing, unreadable, locked, page out of range, or the request
/// was cancelled. Callers that need to tell "file missing" apart check the file themselves.
public final class ThumbnailCache: Sendable {
    struct ImageKey: Hashable, Sendable {
        let ref: PageRef
        let stamp: FileStamp
        let width: Int, height: Int      // rounded to 10 pt
        let highlightKey: String?        // nil = no highlights
        let colorKey: String
        /// The exact tile width decides the style; the 10 pt rounding above would mix 275–284 pt.
        let enlarged: Bool
        /// Hash of the OCR text and boxes the marks came from ("" = none): a page recognized later gets
        /// its marks (spec 1.2.4 §5).
        let ocrVersion: String
    }

    /// Identifies one version of a file on disk.
    struct FileStamp: Hashable, Sendable {
        let modifiedAt: Date?
        let size: Int?
    }

    /// A job of this cache in the shared render queue.
    struct JobKey: Hashable { let cache: UUID; let key: ImageKey }

    private static let log = Logger(subsystem: "local.pdfsucher", category: "ThumbnailCache")
    static func cgColor(_ c: RGBA, alpha: Double) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
    }
    /// Larger point sizes are rejected as nonsense.
    static let maxPointSide: CGFloat = 20_000
    /// Long side of a rendered bitmap at most; larger tiles are drawn scaled up (about 12 MB per bitmap).
    static let maxRenderPixelSide: CGFloat = 2048

    let id = UUID()
    let images: Mutex<LRUCache<ImageKey, NSImage>>
    let documents: DocumentPool
    let queue: TileRenderQueue
    let disk: TileDiskCache?
    let scale: CGFloat
    /// The running prefetch batch; a new one cancels it (spec 1.2.4 §2).
    private let prefetchTask = Mutex<Task<Void, Never>?>(nil)
    /// Word/PowerPoint pages (1.3 Teil B, `ThumbnailCache+Foreign.swift`).
    let foreign: (any ForeignPageProvider)?
    let foreignVersions = Mutex<[URL: String]>([:])
    /// The size the grid last asked a tile for (1.3.4: the preview's stand-in looks for that tile on disk).
    let lastTileSize = Mutex<CGSize?>(nil)

    /// - Parameters:
    ///   - countLimit: maximum number of cached thumbnails.
    ///   - byteLimit: maximum bitmap bytes of cached thumbnails (default 256 MB).
    ///   - documentLimit: maximum number of files with open `PDFDocument`s.
    ///   - scale: pixels per point of the rendered bitmap (2 = Retina).
    ///   - disk: tiles on disk; nil (tests) keeps them in memory only.
    public convenience init(countLimit: Int = 300, byteLimit: Int = 256 << 20, documentLimit: Int = 20, scale: CGFloat = 2,
                disk: TileDiskCache? = nil, foreign: (any ForeignPageProvider)? = nil) {
        self.init(countLimit: countLimit, byteLimit: byteLimit, documentLimit: documentLimit, scale: scale, disk: disk,
                  queue: .shared, foreign: foreign)
    }

    init(countLimit: Int = 300, byteLimit: Int = 256 << 20, documentLimit: Int = 20, scale: CGFloat = 2,
         disk: TileDiskCache?, queue: TileRenderQueue, foreign: (any ForeignPageProvider)? = nil) {
        self.foreign = foreign
        images = Mutex(LRUCache(limit: countLimit, costLimit: byteLimit))
        // Parallel renders of one file keep their documents, but all files together keep at most `workers`
        // documents beyond one per file (spec 1.2.4 §4: about 26 open instead of up to 120).
        documents = DocumentPool(limit: documentLimit, instancesPerFile: queue.workers, extraLimit: queue.workers)
        self.queue = queue
        self.disk = disk
        self.scale = max(scale, 1)
    }

    var cachedImageCount: Int { images.withLock { $0.count } }
    var cachedDocumentCount: Int { documents.count }
    var documentOpenCount: Int { documents.openCount }

    /// The page rendered aspect-fit into an image of `size` points. A cached image rendered for a
    /// size within ±5 pt may be returned instead. `highlightKey` identifies the highlight set for
    /// caching (e.g. the normalized query) and must change whenever `highlightRanges` would.
    /// Marks are exact on tiles at least `HighlightGeometry.threshold` wide, enlarged with a left-edge stripe
    /// on smaller ones (spec 1.1 §14), in `highlightColor`.
    /// - Parameter ocr: text and word boxes of an OCR page (spec 1.2 §5): marks come from them.
    public func thumbnail(for ref: PageRef, size: CGSize, highlightKey: String = "", highlightRanges: HighlightRanges? = nil,
                          highlightColor: RGBA = .yellow, ocr: OCRPageText? = nil) async -> NSImage? {
        guard let request = Request(ref: ref, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                    color: highlightColor, ocr: ocr, cache: self) else {
            if Self.validSize(size) { forget(ref.url) }
            return nil
        }
        lastTileSize.withLock { $0 = size }
        if let cached = images.withLock({ $0.value(for: request.key) }) { return cached }
        guard !Task.isCancelled else { return nil }
        if let disk, let stored = await disk.image(named: request.diskName) {
            // Decoded already: kept even when the tile scrolled away meanwhile (review M5).
            let image = NSImage(cgImage: stored, size: size)
            images.withLock { $0.insert(image, for: request.key, cost: stored.bytesPerRow * stored.height) }
            return Task.isCancelled ? nil : image
        }
        guard !Task.isCancelled else { return nil }
        return await queue.image(key: JobKey(cache: id, key: request.key), priority: .visible) { [self] in render(request) }
    }

    /// One group of tiles to render ahead with the same size and marks.
    public struct PrefetchGroup: Sendable {
        public let refs: [PageRef]
        public let size: CGSize
        public let highlightKey: String
        public let highlightRanges: HighlightRanges?
        public let highlightColor: RGBA
        public let ocr: (@Sendable (PageRef) async -> OCRPageText?)?

        public init(refs: [PageRef], size: CGSize, highlightKey: String = "", highlightRanges: HighlightRanges? = nil,
                    highlightColor: RGBA = .yellow, ocr: (@Sendable (PageRef) async -> OCRPageText?)? = nil) {
            self.refs = refs
            self.size = size
            self.highlightKey = highlightKey
            self.highlightRanges = highlightRanges
            self.highlightColor = highlightColor
            self.ocr = ocr
        }
    }

    /// Renders tiles ahead of time at low priority (the area next to the visible tiles), into memory and
    /// disk. Does not wait. Replaces the previous batch: its task is cancelled and its waiting jobs leave
    /// the render queue (spec 1.2.4 §2). Pages already cached are skipped.
    public func prefetch(_ groups: [PrefetchGroup]) {
        let groups = groups.filter { !$0.refs.isEmpty && Self.validSize($0.size) }
        let me = id
        // Under the lock, in this order: the old batch stops and its waiting jobs go before the new
        // batch can queue any (its task starts only after the swap).
        prefetchTask.withLock { current in
            current?.cancel()
            queue.dropWaitingPrefetches { ($0.base as? JobKey)?.cache == me }
            current = groups.isEmpty ? nil : Task.detached(priority: .utility) { [self] in
                for group in groups { await prefetch(group) }
            }
        }
    }

    /// One group, for callers with a single size and set of marks. Like `prefetch(_ groups:)` it replaces
    /// the running batch: send plain and marked tiles together, not in two calls (review M4).
    public func prefetch(_ refs: [PageRef], size: CGSize, highlightKey: String = "", highlightRanges: HighlightRanges? = nil,
                         highlightColor: RGBA = .yellow, ocr: (@Sendable (PageRef) async -> OCRPageText?)? = nil) {
        prefetch([PrefetchGroup(refs: refs, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                highlightColor: highlightColor, ocr: ocr)])
    }

    private func prefetch(_ group: PrefetchGroup) async {
        let size = group.size, highlightKey = group.highlightKey, highlightRanges = group.highlightRanges
        let highlightColor = group.highlightColor, ocr = group.ocr
        for ref in group.refs {
                guard !Task.isCancelled else { return }
                // Without the OCR text the marks of a recognized page would be wrong (and cached so).
                let text = highlightRanges == nil ? nil : await ocr?(ref)
                guard let request = Request(ref: ref, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                            color: highlightColor, ocr: text, cache: self),
                      images.withLock({ $0.value(for: request.key) }) == nil,
                      disk?.contains(request.diskName) != true else { continue }
                guard !Task.isCancelled else { return }
                queue.prefetch(key: JobKey(cache: id, key: request.key)) { [self] in render(request) }
        }
    }

    /// The cached image for a tile, without rendering or waiting (shown at once when a tile reappears).
    /// Does not check the file on disk; `thumbnail` does.
    public func cachedImage(for ref: PageRef, size: CGSize, highlightKey: String = "", highlighted: Bool,
                            highlightColor: RGBA = .yellow) -> NSImage? {
        guard Self.validSize(size), let stamp = documents.knownStamp(ref.url) else { return nil }
        let key = Self.key(ref: ref, stamp: stamp, size: size, highlightKey: highlightKey, highlighted: highlighted, color: highlightColor,
                           ocrVersion: knownForeignVersion(ref.url, ocrVersion: highlighted ? documents.knownOCRVersion(ref) ?? "" : ""))
        return images.withLock { $0.value(for: key) }
    }

    /// Everything one tile needs, checked and keyed.
    struct Request: Sendable {
        let ref: PageRef
        let size: CGSize
        let stamp: FileStamp
        let key: ImageKey
        let diskName: TileDiskCache.Name
        let source: TileDiskCache.Source
        let highlightRanges: HighlightRanges?
        let color: RGBA
        let ocr: OCRPageText?

        init?(ref: PageRef, size: CGSize, highlightKey: String, highlightRanges: HighlightRanges?, color: RGBA,
              ocr: OCRPageText?, cache: ThumbnailCache) {
            guard ThumbnailCache.validSize(size), let stamp = ThumbnailCache.stamp(of: ref.url) else { return nil }
            cache.documents.noteStamp(stamp, for: ref.url)
            self.ref = ref
            self.size = size
            self.stamp = stamp
            self.highlightRanges = highlightRanges
            self.color = color
            self.ocr = ocr
            let ocrVersion = highlightRanges == nil ? "" : ThumbnailCache.ocrVersion(ocr)
            if highlightRanges != nil { cache.documents.noteOCRVersion(ocrVersion, for: ref) }
            key = ThumbnailCache.key(ref: ref, stamp: stamp, size: size, highlightKey: highlightKey,
                                     highlighted: highlightRanges != nil, color: color,
                                     ocrVersion: cache.foreignVersion(ref.url, ocrVersion: ocrVersion))
            let path = ref.url.standardizedFileURL.path
            source = TileDiskCache.Source(path: path, modifiedAt: stamp.modifiedAt, size: stamp.size)
            // The exact pixel size and the OCR text's version belong in the name too: tiles on disk
            // outlive this run, and a page recognized later gets marks it did not have before.
            let pixels = ThumbnailCache.pixelSize(size, scale: cache.scale)
            diskName = TileDiskCache.name(source: path, parts: [
                "\(ref.pageIndex)",
                stamp.modifiedAt.map { "\($0.timeIntervalSince1970)" } ?? "-", stamp.size.map(String.init) ?? "-",
                "\(pixels.width)x\(pixels.height)", "\(Int((size.width * 10).rounded()))",
                key.highlightKey ?? "<none>", key.colorKey, key.enlarged ? "e" : "x", key.ocrVersion,
            ])
        }
    }

    private static func key(ref: PageRef, stamp: FileStamp, size: CGSize, highlightKey: String, highlighted: Bool,
                            color: RGBA, ocrVersion: String) -> ImageKey {
        ImageKey(ref: ref, stamp: stamp, width: round10(size.width), height: round10(size.height),
                 highlightKey: highlighted ? highlightKey : nil,
                 colorKey: highlighted ? color.key : "",
                 enlarged: highlighted && HighlightGeometry.style(forTileWidth: size.width) == .enlarged,
                 ocrVersion: highlighted || isForeignVersion(ocrVersion) ? ocrVersion : "")
    }

    /// Hash of the OCR text and word boxes ("" = no OCR text): marks change with them (spec 1.2.4 §5).
    static func ocrVersion(_ ocr: OCRPageText?) -> String {
        guard let ocr = OCRHighlights.usable(ocr) else { return "" }
        // Stable across launches (the disk name uses it): SHA-256 of the text and the boxes.
        let text = ocr.text + ocr.words.map { "\($0.range.location),\($0.range.length),\($0.box.minX),\($0.box.minY),\($0.box.width),\($0.box.height)" }.joined(separator: ";")
        return TileDiskCache.name(source: "ocr", parts: [text]).file.prefix(16).description
    }

    static func validSize(_ size: CGSize) -> Bool {
        size.width >= 1 && size.height >= 1 && size.width <= maxPointSide && size.height <= maxPointSide
    }

    private static func round10(_ v: CGFloat) -> Int { Int((v / 10).rounded()) * 10 }

    static func pixelSize(_ size: CGSize, scale: CGFloat, maxPixelSide: CGFloat = maxRenderPixelSide) -> (width: Int, height: Int) {
        let scale = min(scale, maxPixelSide / max(size.width, size.height))
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    private static func stamp(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(modifiedAt: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.intValue)
    }

    /// Height ÷ width of the file's first page as shown (rotation and EXIF orientation applied), for the shape
    /// of its tiles (1.3.4); nil when unknown (unreadable, locked, Word/PowerPoint not laid out yet). A PDF is
    /// opened through the pool like for a tile, so its first tile reuses the document. Blocks: not on the main actor.
    public func pageAspect(of url: URL) -> CGFloat? {
        if ImagePages.isImage(url) { return Self.imageAspect(url) }
        if let foreign, foreign.handles(url) {
            if let tile = foreign.tile(PageRef(url: url, pageIndex: 0)) {
                return tile.size.width > 0 && tile.size.height > 0 ? tile.size.height / tile.size.width : nil
            }
            return foreignDocument(for: url, page: 0, maxPixel: 64)?.page(at: 0).flatMap(Self.aspect(of:))
        }
        guard let stamp = Self.stamp(of: url), let document = documents.checkout(url, stamp: stamp) else { return nil }
        defer { documents.checkin(document, for: url, stamp: stamp) }
        guard document.pageCount > 0 else { return nil }
        return document.page(at: 0).flatMap(Self.aspect(of:))
    }

    /// Height ÷ width of a page's crop box as shown (quarter turns swap the sides).
    static func aspect(of page: PDFPage) -> CGFloat? {
        let box = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let shown = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard shown.width > 0, shown.height > 0 else { return nil }
        return shown.height / shown.width
    }

    /// From the image header only (no decoding); EXIF orientations 5…8 turn the image a quarter.
    static func imageAspect(_ url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGFloat(width / height) : CGFloat(height / width)
    }

    private func forget(_ url: URL) {
        documents.forget(url)
        images.withLock { $0.removeAll { $0.ref.url == url } }
        forgetForeignVersion(url)
    }

    /// Runs on a render thread.
    private func render(_ request: Request) -> NSImage? {
        // Rendered meanwhile (a prefetch, or a request that shared no job with this one).
        if let cached = images.withLock({ $0.value(for: request.key) }) { return cached }
        let ref = request.ref, size = request.size
        // Images are decoded at the tile's size and not kept as documents (a decoded photo is 10+ MB;
        // the rendered thumbnail is cached below like any other).
        let isImage = ImagePages.isImage(ref.url)
        let rendered: (image: CGImage, bytes: Int)?
        if isImage {
            let pixels = Int((max(size.width, size.height) * scale).rounded(.up))
            guard let document = ImageDocument.make(ref.url, maxPixel: min(pixels, Int(Self.maxRenderPixelSide))) else { return nil }
            rendered = draw(document, request)
        } else if let foreign, foreign.handles(ref.url), let tile = foreign.tile(ref) {
            // Word (office-speed): drawn straight into the bitmap, no PDF page in between (~0.5 ms instead of ~6 ms).
            rendered = render(tile, request)
        } else if foreign?.handles(ref.url) == true {
            // Word/PowerPoint: a one-page document from the provider, not pooled (like images).
            guard let document = foreignDocument(for: ref.url, page: ref.pageIndex, maxPixel: Self.foreignMaxPixel(size, scale: scale))
            else { return nil }
            rendered = draw(document, request, pageIndex: 0)
        } else {
            guard let document = documents.checkout(ref.url, stamp: request.stamp) else { return nil }
            rendered = draw(document, request)
            documents.checkin(document, for: ref.url, stamp: request.stamp)
        }
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered.image, size: size)
        images.withLock { $0.insert(image, for: request.key, cost: rendered.bytes) }
        disk?.store(rendered.image, named: request.diskName, source: request.source)
        return image
    }

    func draw(_ document: PDFDocument, _ request: Request, pageIndex: Int? = nil,
              maxPixelSide: CGFloat = maxRenderPixelSide) -> (image: CGImage, bytes: Int)? {
        let pageIndex = pageIndex ?? request.ref.pageIndex
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return nil }
        return render(page, size: request.size, highlightRanges: request.highlightRanges, color: request.color, ocr: request.ocr,
                      maxPixelSide: maxPixelSide)
    }

    private func render(_ page: PDFPage, size: CGSize, highlightRanges: HighlightRanges?, color: RGBA,
                        ocr: OCRPageText?, maxPixelSide: CGFloat) -> (image: CGImage, bytes: Int)? {
        let box = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let shown = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        return render(shown: shown, box: box, size: size, highlightRanges: highlightRanges, color: color,
                      maxPixelSide: maxPixelSide, transform: { page.transform($0, for: .cropBox) },
                      draw: { ctx in if !ScannedPage.draw(page, in: ctx) { page.draw(with: .cropBox, to: ctx) } },
                      matches: { highlightRanges in
            if let ocr = OCRHighlights.usable(ocr) {
                return OCRHighlights.pageRects(ocr, highlightRanges: highlightRanges, page: page)
            } else if let text = page.string, !text.isEmpty {
                return Self.highlightRects(on: page, text: text, ranges: highlightRanges(text))
            }
            return []
        })
    }

    /// A tile the provider draws directly: page space is the tile's points (no crop box, no rotation); marks from
    /// the stored word boxes (`ocr`, the index) or else the tile's own words.
    private func render(_ tile: ForeignTile, _ request: Request) -> (image: CGImage, bytes: Int)? {
        let box = CGRect(origin: .zero, size: tile.size)
        let ocr = request.ocr
        return render(shown: tile.size, box: box, size: request.size, highlightRanges: request.highlightRanges,
                      color: request.color, maxPixelSide: Self.maxRenderPixelSide, transform: { _ in }, draw: tile.draw,
                      matches: { highlightRanges in
            let words = OCRHighlights.usable(ocr) ?? { let own = tile.text(); return OCRPageText(text: own.text, words: own.words) }()
            return OCRHighlights.normalizedBoxes(words, highlightRanges: highlightRanges)
                .map { OCRMapping.pageRect($0, cropBox: box, rotation: 0) }
        })
    }

    /// Draws a page of `shown` size (points as displayed; `box` its unrotated crop box) fitted into a tile of `size`
    /// on white, then the marks: `matches` gives match rectangles in page space, `transform` maps page space onto the
    /// fitted, displayed page.
    private func render(shown: CGSize, box: CGRect, size: CGSize, highlightRanges: HighlightRanges?, color: RGBA,
                        maxPixelSide: CGFloat, transform: (CGContext) -> Void, draw: (CGContext) -> Void,
                        matches: (HighlightRanges) -> [CGRect]) -> (image: CGImage, bytes: Int)? {
        let scale = min(self.scale, maxPixelSide / max(size.width, size.height))
        let (pixelWidth, pixelHeight) = Self.pixelSize(size, scale: self.scale, maxPixelSide: maxPixelSide)
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        guard shown.width > 0, shown.height > 0 else { return nil }
        let fit = min(size.width / shown.width, size.height / shown.height)
        let drawn = CGSize(width: shown.width * fit, height: shown.height * fit)

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: drawn))
        ctx.scaleBy(x: fit, y: fit)
        ctx.interpolationQuality = .high

        ctx.saveGState()
        draw(ctx)
        ctx.restoreGState()

        if let highlightRanges {
            let rects = matches(highlightRanges)
            if !rects.isEmpty {
                let style = HighlightGeometry.style(forTileWidth: size.width)
                let layout = HighlightGeometry.layout(matchRects: rects, pageBounds: box, scale: fit, style: style)
                transform(ctx)
                ctx.setBlendMode(.multiply)
                let opacity = style == .exact ? HighlightGeometry.exactOpacity : HighlightGeometry.enlargedOpacity
                ctx.setFillColor(Self.cgColor(color, alpha: opacity))
                ctx.fill(layout.boxes)
                // Stripes at the page's left edge, full colour: where on the page the hits are.
                ctx.setBlendMode(.normal)
                ctx.setFillColor(Self.cgColor(color, alpha: 1))
                let width = HighlightGeometry.stripeWidth / fit
                ctx.fill(layout.stripes.map { CGRect(x: box.minX, y: $0.lowerBound, width: width, height: $0.upperBound - $0.lowerBound) })
            }
        }
        guard let cgImage = ctx.makeImage() else { return nil }
        return (cgImage, cgImage.bytesPerRow * cgImage.height)
    }

    /// Page-space rectangles of each range, one per line the range spans.
    private static func highlightRects(on page: PDFPage, text: String, ranges: [Range<String.Index>]) -> [CGRect] {
        ranges.flatMap { range -> [CGRect] in
            guard range.upperBound <= text.endIndex else { return [] }   // defensive: indices must be into `text`
            let nsRange = NSRange(range, in: text)
            guard nsRange.length > 0, let selection = page.selection(for: nsRange) else { return [] }
            return selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        }
    }
}

/// Open `PDFDocument`s, pooled per file: a render thread checks one out, so pages of the same file
/// render in parallel on separate instances (PDFKit objects are not shared between threads). Files
/// that cannot be opened are remembered (negative cache) until they change.
final class DocumentPool: @unchecked Sendable {
    private struct Entry {
        let stamp: ThumbnailCache.FileStamp
        var idle: [PDFDocument]
        var unreadable: Bool
    }

    private static let log = Logger(subsystem: "local.pdfsucher", category: "ThumbnailCache")
    private let lock = NSLock()
    private var entries: LRUCache<URL, Entry>
    /// Last stamp seen per file, for `ThumbnailCache.cachedImage`.
    private var stamps: [URL: ThumbnailCache.FileStamp] = [:]
    /// Last OCR version seen per highlighted page, for `ThumbnailCache.cachedImage`.
    private var ocrVersions: [PageRef: String] = [:]
    private let instancesPerFile: Int
    /// Idle documents beyond the first of each file, over all files.
    private let extraLimit: Int
    private var opened = 0

    init(limit: Int, instancesPerFile: Int, extraLimit: Int = .max) {
        entries = LRUCache(limit: limit)
        self.instancesPerFile = max(instancesPerFile, 1)
        self.extraLimit = max(extraLimit, 0)
    }

    var count: Int { lock.withLock { entries.count } }
    var openCount: Int { lock.withLock { opened } }

    func noteStamp(_ stamp: ThumbnailCache.FileStamp, for url: URL) { lock.withLock { stamps[url] = stamp } }
    func knownStamp(_ url: URL) -> ThumbnailCache.FileStamp? { lock.withLock { stamps[url] } }
    func noteOCRVersion(_ version: String, for ref: PageRef) { lock.withLock { ocrVersions[ref] = version } }
    func knownOCRVersion(_ ref: PageRef) -> String? { lock.withLock { ocrVersions[ref] } }
    /// Idle documents kept for a file (tests).
    func idleCount(_ url: URL) -> Int { lock.withLock { entries.value(for: url)?.idle.count ?? 0 } }

    /// An open document of this version of the file, or nil if it cannot be opened or is locked.
    func checkout(_ url: URL, stamp: ThumbnailCache.FileStamp) -> PDFDocument? {
        lock.lock()
        if var entry = entries.value(for: url), entry.stamp == stamp {
            if entry.unreadable { lock.unlock(); return nil }
            if let document = entry.idle.popLast() {
                entries.insert(entry, for: url)
                lock.unlock()
                return document
            }
        } else {
            entries.insert(Entry(stamp: stamp, idle: [], unreadable: false), for: url)
        }
        opened += 1
        lock.unlock()

        var document = PDFDocument(url: url)
        if document == nil {
            Self.log.error("Cannot open PDF \(url.path, privacy: .public)")
        } else if document?.isLocked == true {
            Self.log.error("PDF is locked: \(url.path, privacy: .public)")
            document = nil
        }
        if document == nil {
            lock.withLock { entries.insert(Entry(stamp: stamp, idle: [], unreadable: true), for: url) }
        }
        return document
    }

    /// Returns a document for reuse; dropped if the file changed or left the pool meanwhile, or if the
    /// file already has `instancesPerFile` idle ones (an extra opened for a parallel render is closed).
    func checkin(_ document: PDFDocument, for url: URL, stamp: ThumbnailCache.FileStamp) {
        lock.withLock {
            guard var entry = entries.value(for: url), entry.stamp == stamp, !entry.unreadable,
                  entry.idle.count < instancesPerFile else { return }
            entry.idle.append(document)
            entries.insert(entry, for: url)
            // Too many extras over all files: the least recently used files give theirs back first.
            var extras = entries.keysLeastRecentFirst.reduce(0) { $0 + max((entries.peek($1)?.idle.count ?? 0) - 1, 0) }
            for key in entries.keysLeastRecentFirst where extras > extraLimit {
                guard var other = entries.peek(key), other.idle.count > 1 else { continue }
                let drop = min(other.idle.count - 1, extras - extraLimit)
                other.idle.removeLast(drop)
                extras -= drop
                entries.replace(other, for: key)
            }
        }
    }

    func forget(_ url: URL) {
        lock.withLock {
            entries.removeValue(for: url)
            stamps.removeValue(forKey: url)
            ocrVersions = ocrVersions.filter { $0.key.url != url }
        }
    }
}

/// Minimal least-recently-used map bounded by entry count and optional total cost.
/// O(n) bookkeeping, fine for the few hundred entries used here.
struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: (value: Value, cost: Int)] = [:]
    private var order: [Key] = []            // least recent first
    private var totalCost = 0
    let limit: Int
    let costLimit: Int

    init(limit: Int, costLimit: Int = .max) {
        self.limit = max(limit, 1)
        self.costLimit = max(costLimit, 0)
    }

    var count: Int { storage.count }

    /// Keys from least to most recently used.
    var keysLeastRecentFirst: [Key] { order }

    /// The value without marking it used.
    func peek(_ key: Key) -> Value? { storage[key]?.value }

    /// Replaces a value without marking it used (no-op for an unknown key).
    mutating func replace(_ value: Value, for key: Key) {
        guard let old = storage[key] else { return }
        storage[key] = (value, old.cost)
    }

    mutating func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        touch(key)
        return entry.value
    }

    /// Inserts and evicts least-recently-used entries until both limits hold (the new entry stays).
    mutating func insert(_ value: Value, for key: Key, cost: Int = 0) {
        if let old = storage[key] { totalCost -= old.cost }
        storage[key] = (value, cost)
        totalCost += cost
        touch(key)
        while order.count > 1, order.count > limit || totalCost > costLimit {
            evict(order.removeFirst())
        }
    }

    mutating func removeValue(for key: Key) {
        guard storage[key] != nil else { return }
        order.removeAll { $0 == key }
        evict(key)
    }

    mutating func removeAll(where predicate: (Key) -> Bool) {
        for key in order where predicate(key) { evict(key) }
        order.removeAll(where: predicate)
    }

    private mutating func evict(_ key: Key) {
        if let old = storage.removeValue(forKey: key) { totalCost -= old.cost }
    }

    private mutating func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
