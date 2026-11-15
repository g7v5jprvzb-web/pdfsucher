// ThumbnailCache+Preview.swift — 1.3.4 Vorschau-Puffer: pictures for the large preview's stand-in.
// Kept apart from ThumbnailCache.swift, which only opens a few members for it, so merges of the tile cache stay simple.
import AppKit
import Foundation
import OutputKit
import PDFKit
import SearchKit
import Synchronization

extension ThumbnailCache {
    /// Long side of a preview picture at most (≈ 22 MB for an A4 page, spec 1.3.4).
    static let previewMaxPixelSide: CGFloat = 2_800

    /// A preview picture and how long drawing it took (a slow page is handed to the PDFView later).
    struct PreviewRender: @unchecked Sendable {
        let image: CGImage
        let millis: Double
    }

    /// A render job of the preview (never shares a job with a tile of the same key).
    private struct PreviewJobKey: Hashable { let cache: UUID; let key: ImageKey }

    /// The page drawn aspect-fit into `size` points at the cache's scale (long side at most `previewMaxPixelSide`),
    /// with marks like a tile, on the render threads at `priority`. Not kept in memory or on disk. nil for files the
    /// Word/PowerPoint provider draws, missing or unreadable files, and when the calling task is cancelled.
    func previewImage(for ref: PageRef, size: CGSize, highlightKey: String = "", highlightRanges: HighlightRanges? = nil,
                      highlightColor: RGBA = .yellow, ocr: OCRPageText? = nil,
                      priority: TileRenderQueue.Priority) async -> PreviewRender? {
        guard foreign?.handles(ref.url) != true,
              let request = Request(ref: ref, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                    color: highlightColor, ocr: ocr, cache: self) else { return nil }
        let millis = Mutex(0.0)
        let image = await queue.image(key: PreviewJobKey(cache: id, key: request.key), priority: priority) { [self] in
            let started = ContinuousClock.now
            defer {
                let elapsed = ContinuousClock.now - started
                millis.withLock { $0 = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15 }
            }
            return renderPreview(request).map { NSImage(cgImage: $0, size: size) }
        }
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return PreviewRender(image: cgImage, millis: millis.withLock { $0 })
    }

    /// Runs on a render thread: an image file decoded at the picture's size, a PDF page from the document pool.
    private func renderPreview(_ request: Request) -> CGImage? {
        let ref = request.ref
        if ImagePages.isImage(ref.url) {
            let pixels = Int((max(request.size.width, request.size.height) * scale).rounded(.up))
            guard let document = ImageDocument.make(ref.url, maxPixel: min(pixels, Int(Self.previewMaxPixelSide))) else { return nil }
            return draw(document, request, maxPixelSide: Self.previewMaxPixelSide)?.image
        }
        guard let document = documents.checkout(ref.url, stamp: request.stamp) else { return nil }
        defer { documents.checkin(document, for: ref.url, stamp: request.stamp) }
        return draw(document, request, maxPixelSide: Self.previewMaxPixelSide)?.image
    }

    /// The largest tile of `ref` in memory with these marks, whatever its size (the stand-in shows it enlarged).
    /// Only tiles of the file version seen last. Main actor safe: no file access.
    func bestCachedImage(for ref: PageRef, highlightKey: String, highlighted: Bool, highlightColor: RGBA = .yellow) -> NSImage? {
        guard let stamp = documents.knownStamp(ref.url) else { return nil }
        let wantedHighlight: String? = highlighted ? highlightKey : nil
        let colorKey = highlighted ? highlightColor.key : ""
        return images.withLock { lru in
            lru.keysLeastRecentFirst
                .filter { $0.ref == ref && $0.stamp == stamp && $0.highlightKey == wantedHighlight && $0.colorKey == colorKey }
                .max { $0.width < $1.width }
                .flatMap { lru.peek($0) }
        }
    }

    /// The tile of `ref` on disk at the size the grid asked for last, without rendering; nil when there is none.
    func storedImage(for ref: PageRef, highlightKey: String = "", highlightRanges: HighlightRanges? = nil,
                     highlightColor: RGBA = .yellow, ocr: OCRPageText? = nil) async -> NSImage? {
        guard let disk, let size = lastTileSize.withLock({ $0 }),
              let request = Request(ref: ref, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                    color: highlightColor, ocr: ocr, cache: self),
              let stored = await disk.image(named: request.diskName) else { return nil }
        return NSImage(cgImage: stored, size: size)
    }
}
