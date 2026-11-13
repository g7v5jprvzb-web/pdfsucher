import AppKit
import Foundation
import PDFKit
import Synchronization
import Testing
import OutputKit
import TestSupport
@testable import ViewerUI

/// Spec 1.2.3: parallel rendering, order, cancellation, prefetch and the disk cache.
@Suite("TileRenderQueue")
struct TileRenderQueueTests {
    /// Blocks the queue's only thread until `release` is called, so the order of waiting jobs is visible.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let didStart = Mutex(false)
        func wait() { didStart.withLock { $0 = true }; semaphore.wait() }
        func release() { semaphore.signal() }
        func started() async throws { while !didStart.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) } }
    }

    static func image() -> NSImage { NSImage(size: CGSize(width: 1, height: 1)) }

    @Test func visibleBeforePrefetchAndNewestFirst() async throws {
        let queue = TileRenderQueue(workers: 1)
        let gate = Gate()
        let order = Mutex<[String]>([])
        queue.prefetch(key: "gate") { gate.wait(); return nil }
        try await gate.started()
        queue.prefetch(key: "p1") { order.withLock { $0.append("p1") }; return nil }
        queue.prefetch(key: "p2") { order.withLock { $0.append("p2") }; return nil }
        let v1 = Task { await queue.image(key: "v1", priority: .visible) { order.withLock { $0.append("v1") }; return Self.image() } }
        while queue.pendingCount < 3 { try await Task.sleep(for: .milliseconds(1)) }
        let v2 = Task { await queue.image(key: "v2", priority: .visible) { order.withLock { $0.append("v2") }; return Self.image() } }
        while queue.pendingCount < 4 { try await Task.sleep(for: .milliseconds(1)) }
        gate.release()
        _ = await (v1.value, v2.value)
        while order.withLock({ $0.count }) < 4 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(order.withLock { $0 } == ["v2", "v1", "p2", "p1"])
    }

    @Test func cancelledRequestNeverRuns() async throws {
        let queue = TileRenderQueue(workers: 1)
        let gate = Gate()
        let ran = Mutex(false)
        queue.prefetch(key: "gate") { gate.wait(); return nil }
        try await gate.started()
        let task = Task { await queue.image(key: "x", priority: .visible) { ran.withLock { $0 = true }; return Self.image() } }
        while queue.pendingCount < 1 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(queue.pendingCount == 0)
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran.withLock { $0 } == false)
    }

    @Test func sameKeySharesOneJob() async throws {
        let queue = TileRenderQueue(workers: 2)
        let runs = Mutex(0)
        let gate = Gate()
        let work: @Sendable () -> NSImage? = { runs.withLock { $0 += 1 }; gate.wait(); return Self.image() }
        let a = Task { await queue.image(key: "k", priority: .visible, work: work) }
        try await gate.started()
        let b = Task { await queue.image(key: "k", priority: .visible, work: work) }
        try await Task.sleep(for: .milliseconds(20))
        gate.release()
        let (x, y) = await (a.value, b.value)
        #expect(x != nil && x === y)
        #expect(runs.withLock { $0 } == 1)
    }

    @Test func oldPrefetchesAreDropped() async throws {
        let queue = TileRenderQueue(workers: 1, maxPrefetch: 3)
        let gate = Gate()
        queue.prefetch(key: "gate") { gate.wait(); return nil }
        try await gate.started()
        for i in 0..<10 { queue.prefetch(key: i) { nil } }
        #expect(queue.pendingCount == 3)
        gate.release()
    }

    @Test func rendersInParallel() async throws {
        let queue = TileRenderQueue(workers: 4)
        let running = Mutex((now: 0, peak: 0))
        await withTaskGroup(of: NSImage?.self) { group in
            for i in 0..<8 {
                group.addTask {
                    await queue.image(key: i, priority: .visible) {
                        running.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        Thread.sleep(forTimeInterval: 0.05)
                        running.withLock { $0.now -= 1 }
                        return Self.image()
                    }
                }
            }
            for await _ in group {}
        }
        #expect(running.withLock { $0.peak } >= 3)
    }
}

@Suite("ThumbnailCache 1.2.3")
struct ThumbnailCacheParallelTests {
    private func fixture(pages: Int) throws -> URL {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("doc.pdf")
        try PDFFixtures.makePDF(at: url, pages: (0..<pages).map { "Seite \($0) Vertragsende" })
        return url
    }

    private func diskCache() throws -> TileDiskCache {
        TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
    }

    @Test func manyPagesOfOneFileRenderCorrectlyAtOnce() async throws {
        let url = try fixture(pages: 24)
        let cache = ThumbnailCache()
        let size = CGSize(width: 100, height: 141)
        let images = await withTaskGroup(of: (Int, NSImage?).self) { group in
            for i in 0..<24 { group.addTask { (i, await cache.thumbnail(for: PageRef(url: url, pageIndex: i), size: size)) } }
            var result: [Int: NSImage] = [:]
            for await (i, image) in group { result[i] = image }
            return result
        }
        #expect(images.count == 24)
        // One document per render thread at most.
        #expect(cache.documentOpenCount <= TileRenderQueue.shared.workers)
        #expect(cache.cachedDocumentCount == 1)
    }

    @Test func diskCacheServesAnotherInstanceWithoutRendering() async throws {
        let url = try fixture(pages: 2)
        let disk = try diskCache()
        let ref = PageRef(url: url, pageIndex: 1)
        let size = CGSize(width: 200, height: 283)
        let first = try #require(await ThumbnailCache(disk: disk).thumbnail(for: ref, size: size))
        disk.flush()
        #expect(disk.byteCount > 0)
        let second = ThumbnailCache(disk: disk)
        let again = try #require(await second.thumbnail(for: ref, size: size))
        #expect(second.documentOpenCount == 0, "read from disk, not rendered")
        #expect(again.size == first.size)
        // Same pixels (HEIC is lossy: compare loosely).
        let a = PixelProbe(first), b = PixelProbe(again)
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.boundingBox(where: PixelProbe.isDark) != nil)
        let boxA = try #require(a.boundingBox(where: PixelProbe.isDark)), boxB = try #require(b.boundingBox(where: PixelProbe.isDark))
        #expect(abs(boxA.minX - boxB.minX) <= 2 && abs(boxA.maxY - boxB.maxY) <= 2)
    }

    @Test func diskTileKeepsTransparentMargins() async throws {
        let url = try fixture(pages: 1)
        let disk = try diskCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let wide = CGSize(width: 300, height: 141)    // page is narrower: transparent left and right
        _ = await ThumbnailCache(disk: disk).thumbnail(for: ref, size: wide)
        disk.flush()
        let image = try #require(await ThumbnailCache(disk: disk).thumbnail(for: ref, size: wide))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.alphaInfo != .none && cg.alphaInfo != .noneSkipFirst && cg.alphaInfo != .noneSkipLast)
    }

    @Test func changedFileMissesTheDiskCache() async throws {
        let url = try fixture(pages: 1)
        let disk = try diskCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let size = CGSize(width: 100, height: 141)
        _ = await ThumbnailCache(disk: disk).thumbnail(for: ref, size: size)
        disk.flush()
        try PDFFixtures.makePDF(at: url, pages: ["Ganz anderer Inhalt"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let cache = ThumbnailCache(disk: disk)
        _ = await cache.thumbnail(for: ref, size: size)
        #expect(cache.documentOpenCount == 1, "rendered anew")
    }

    @Test func highlightsAndOCRAreSeparateDiskTiles() {
        let a = TileDiskCache.name(for: ["/x.pdf", "0", "q"])
        #expect(a == TileDiskCache.name(for: ["/x.pdf", "0", "q"]))
        #expect(a != TileDiskCache.name(for: ["/x.pdf", "0", "r"]))
    }

    @Test func trimKeepsTheLimit() async throws {
        let url = try fixture(pages: 12)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"), byteLimit: 20_000)
        let cache = ThumbnailCache(disk: disk)
        for i in 0..<12 { _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: i), size: CGSize(width: 300, height: 424)) }
        disk.flush()
        disk.trimNow()
        #expect(disk.byteCount <= 20_000)
    }

    @Test func removeAllEmptiesTheDiskCache() async throws {
        let url = try fixture(pages: 3)
        let disk = try diskCache()
        let cache = ThumbnailCache(disk: disk)
        for i in 0..<3 { _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: i), size: CGSize(width: 100, height: 141)) }
        disk.flush()
        #expect(disk.byteCount > 0)
        disk.removeAll()
        #expect(disk.byteCount == 0)
        #expect(SettingsView.tileCacheSize(5 << 20).contains("MB"))
    }

    @Test func prefetchFillsTheCache() async throws {
        let url = try fixture(pages: 6)
        let cache = ThumbnailCache()
        let size = CGSize(width: 100, height: 141)
        let refs = (0..<6).map { PageRef(url: url, pageIndex: $0) }
        cache.prefetch(refs, size: size)
        for _ in 0..<200 where cache.cachedImageCount < 6 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.cachedImageCount == 6)
        _ = await cache.thumbnail(for: refs[0], size: size)   // records the stamp
        #expect(cache.cachedImage(for: refs[3], size: size, highlighted: false) != nil)
        #expect(cache.cachedImage(for: refs[3], size: size, highlighted: true) == nil)
    }
}
