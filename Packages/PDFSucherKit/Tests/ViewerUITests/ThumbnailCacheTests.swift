import Testing
import AppKit
import Foundation
import PDFKit
import OutputKit
import TestSupport
@testable import ViewerUI

@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    private static let text = "Vertragsende 2024 und weitere Worte"

    private func fixture(rotation: Int = 0) throws -> URL {
        let dir = try PDFFixtures.tempDirectory()
        let url = dir.appendingPathComponent("doc.pdf")
        try PDFFixtures.makePDF(at: url, pages: [Self.text, "Zweite Seite"])
        if rotation != 0 {
            let doc = try #require(PDFDocument(url: url))
            doc.page(at: 0)!.rotation = rotation
            #expect(doc.write(to: url))
        }
        return url
    }

    /// Highlights every occurrence of "Vertragsende" in the page text PDFKit hands over.
    private static let highlightVertrag: HighlightRanges = { text in
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while let r = text.range(of: "Vertragsende", range: start..<text.endIndex) {
            result.append(r)
            start = r.upperBound
        }
        return result
    }

    @Test func thumbnailForMissingFileIsNil() async throws {
        let cache = ThumbnailCache()
        let ref = PageRef(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf"), pageIndex: 0)
        #expect(await cache.thumbnail(for: ref, size: CGSize(width: 100, height: 141)) == nil)
    }

    @Test func thumbnailForPageOutOfRangeIsNil() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        #expect(await cache.thumbnail(for: PageRef(url: url, pageIndex: 2), size: CGSize(width: 100, height: 141)) == nil)
        #expect(await cache.thumbnail(for: PageRef(url: url, pageIndex: -1), size: CGSize(width: 100, height: 141)) == nil)
    }

    @Test func thumbnailForNonPDFIsNil() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: url)
        #expect(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141)) == nil)
    }

    @Test func thumbnailForFileDeletedAfterCachingIsNil() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        #expect(await cache.thumbnail(for: ref, size: CGSize(width: 100, height: 141)) != nil)
        try FileManager.default.removeItem(at: url)
        #expect(await cache.thumbnail(for: ref, size: CGSize(width: 100, height: 141)) == nil)
    }

    @Test func thumbnailHasRequestedSize() async throws {
        let url = try fixture()
        let image = try #require(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 123, height: 174)))
        #expect(image.size == CGSize(width: 123, height: 174))
    }

    @Test func cachedSecondCallIsFast() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let size = CGSize(width: 200, height: 283)
        let first = await cache.thumbnail(for: ref, size: size, highlightKey: "q", highlightRanges: Self.highlightVertrag)
        let clock = ContinuousClock()
        var second: NSImage?
        let elapsed = await clock.measure {
            second = await cache.thumbnail(for: ref, size: size, highlightKey: "q", highlightRanges: Self.highlightVertrag)
        }
        #expect(first != nil)
        #expect(second === first)
        #expect(elapsed < .milliseconds(5))
    }

    @Test func cacheKeyIncludesHighlightKeyAndRoundedSize() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let a = await cache.thumbnail(for: ref, size: CGSize(width: 200, height: 283), highlightKey: "a", highlightRanges: Self.highlightVertrag)
        let b = await cache.thumbnail(for: ref, size: CGSize(width: 200, height: 283), highlightKey: "b", highlightRanges: Self.highlightVertrag)
        let a2 = await cache.thumbnail(for: ref, size: CGSize(width: 201, height: 284), highlightKey: "a", highlightRanges: Self.highlightVertrag)
        let a3 = await cache.thumbnail(for: ref, size: CGSize(width: 260, height: 368), highlightKey: "a", highlightRanges: Self.highlightVertrag)
        #expect(a != nil && b != nil)
        #expect(a !== b)
        #expect(a2 === a)
        #expect(a3 !== a)
    }

    @Test func evictsBeyondCountLimit() async throws {
        let url = try fixture()
        let cache = ThumbnailCache(countLimit: 2)
        let size = CGSize(width: 100, height: 141)
        let p0 = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: 1), size: size)
        _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 300, height: 424))
        #expect(cache.cachedImageCount == 2)
        let p0again = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        #expect(p0again !== p0)
    }

    @Test(arguments: [0, 90])
    func highlightCoversMatchedText(rotation: Int) async throws {
        let url = try fixture(rotation: rotation)
        let ref = PageRef(url: url, pageIndex: 0)
        let size = rotation == 0 ? CGSize(width: 400, height: 566) : CGSize(width: 566, height: 400)
        let plain = try #require(await ThumbnailCache().thumbnail(for: ref, size: size))
        let marked = try #require(await ThumbnailCache().thumbnail(for: ref, size: size, highlightKey: "v", highlightRanges: Self.highlightVertrag))
        #expect(PixelProbe(plain).boundingBox(where: PixelProbe.isYellow) == nil)
        let yellow = try #require(PixelProbe(marked).boundingBox(where: PixelProbe.isYellow))
        let ink = try #require(PixelProbe(plain).boundingBox(where: PixelProbe.isDark))
        #expect(yellow.intersects(ink), "highlight \(yellow) must lie on the text \(ink)")
        // One word, not the whole page: well under 5 % of the bitmap.
        #expect(yellow.width * yellow.height < 0.05 * CGFloat(PixelProbe(marked).width * PixelProbe(marked).height))
    }

    @Test func fileChangedOnDiskIsReloaded() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let size = CGSize(width: 100, height: 141)
        let before = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        #expect(before != nil)
        try PDFFixtures.makePDF(at: url, pages: ["Ganz anderer Inhalt"])
        // Force a different modification date even on coarse-grained file systems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let after = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        #expect(after != nil)
        #expect(after !== before)
        #expect(await cache.thumbnail(for: PageRef(url: url, pageIndex: 1), size: size) == nil, "page 2 no longer exists")
    }

    @Test func evictsBeyondByteLimit() async throws {
        let url = try fixture()
        // 100×141 pt at scale 1 ≈ 56 KB per image; allow room for one only.
        let cache = ThumbnailCache(countLimit: 300, byteLimit: 80_000, scale: 1)
        let size = CGSize(width: 100, height: 141)
        _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: 1), size: size)
        #expect(cache.cachedImageCount == 1)
    }

    @Test func cancelledRequestRendersNothing() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let task = Task { await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141)) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(cache.cachedImageCount == 0)
    }

    @Test func highlightedImageNeverSharesKeyWithPlainImage() async throws {
        let url = try fixture()
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let size = CGSize(width: 200, height: 283)
        let plain = await cache.thumbnail(for: ref, size: size)
        let marked = await cache.thumbnail(for: ref, size: size, highlightRanges: Self.highlightVertrag)
        #expect(plain != nil && marked != nil)
        #expect(plain !== marked)
    }

    @Test func unreadableFileIsNotReparsedOnEveryRequest() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: url)
        let cache = ThumbnailCache()
        for _ in 0..<3 { _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141)) }
        #expect(cache.documentOpenCount == 1)
    }

    @Test func documentIsOpenedOnceWhileCached() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let urls = try (0..<3).map { i -> URL in
            let u = dir.appendingPathComponent("d\(i).pdf")
            try PDFFixtures.makePDF(at: u, pages: ["Seite eins", "Seite zwei"])
            return u
        }
        let cache = ThumbnailCache(documentLimit: 2)
        let size = CGSize(width: 100, height: 141)
        _ = await cache.thumbnail(for: PageRef(url: urls[0], pageIndex: 0), size: size)
        _ = await cache.thumbnail(for: PageRef(url: urls[0], pageIndex: 1), size: size)
        #expect(cache.documentOpenCount == 1)
        _ = await cache.thumbnail(for: PageRef(url: urls[1], pageIndex: 0), size: size)
        _ = await cache.thumbnail(for: PageRef(url: urls[2], pageIndex: 0), size: size)   // evicts d0
        _ = await cache.thumbnail(for: PageRef(url: urls[0], pageIndex: 0), size: CGSize(width: 300, height: 424))
        #expect(cache.documentOpenCount == 4)
    }

    /// Fixed mode with 1 page per row on a wide screen gives tiles taller than 4096 pt: they must still
    /// render, at a capped resolution (review of Task 5.4).
    @Test func hugeTileRendersAtCappedResolution() async throws {
        let url = try fixture()
        let size = CGSize(width: 3000, height: 4242)
        let image = try #require(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: size))
        #expect(image.size == size)
        var rect = CGRect(origin: .zero, size: size)
        let bitmap = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let longSide = max(bitmap.width, bitmap.height)
        #expect(longSide <= Int(ThumbnailCache.maxRenderPixelSide), "\(bitmap.width)×\(bitmap.height)")
        #expect(longSide >= Int(ThumbnailCache.maxRenderPixelSide) - 1)
    }

    @Test func absurdSizeDoesNotTrap() async throws {
        let url = try fixture()
        #expect(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 1e30, height: 1e30)) == nil)
    }

    @Test func emptyRangesDrawNoHighlight() async throws {
        let url = try fixture()
        let image = try #require(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 400, height: 566), highlightKey: "none", highlightRanges: { _ in [] }))
        #expect(PixelProbe(image).boundingBox(where: PixelProbe.isYellow) == nil)
    }
}

@Suite("LRUCache")
struct LRUCacheTests {
    @Test func hitRefreshesRecency() {
        var lru = LRUCache<String, Int>(limit: 2)
        lru.insert(1, for: "a")
        lru.insert(2, for: "b")
        _ = lru.value(for: "a")
        lru.insert(3, for: "c")
        #expect(lru.value(for: "a") == 1)
        #expect(lru.value(for: "b") == nil)
        #expect(lru.value(for: "c") == 3)
    }

    @Test func costLimitEvictsOldest() {
        var lru = LRUCache<String, Int>(limit: 10, costLimit: 100)
        lru.insert(1, for: "a", cost: 60)
        lru.insert(2, for: "b", cost: 60)
        #expect(lru.count == 1)
        #expect(lru.value(for: "b") == 2)
        lru.insert(3, for: "b", cost: 10)   // replacing updates the cost
        lru.insert(4, for: "c", cost: 80)
        #expect(lru.count == 2)
    }
}

/// Reads RGBA pixels of an NSImage, in top-left-origin pixel coordinates.
struct PixelProbe {
    let width: Int, height: Int
    private var data: [UInt8]

    init(_ image: NSImage) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        width = cg.width
        height = cg.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func isYellow(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g > 200 && b < 190 }
    static func isDark(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r < 100 && g < 100 && b < 100 }

    func boundingBox(where test: (UInt8, UInt8, UInt8) -> Bool) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard data[i + 3] > 0, test(data[i], data[i + 1], data[i + 2]) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
