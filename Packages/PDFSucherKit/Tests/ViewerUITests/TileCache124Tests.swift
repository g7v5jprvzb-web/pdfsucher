import AppKit
import IndexKit
import Foundation
import OutputKit
import PDFKit
import SearchKit
import Testing
import TestSupport
@testable import ViewerUI

/// Spec 1.2.4: bounded disk writes, batched prefetch, per-PDF tile folders with cleanup, one pooled
/// document per file.
@Suite("Tile cache 1.2.4", .timeLimit(.minutes(2)))
struct TileCache124Tests {
    private func fixture(_ name: String = "doc.pdf", pages: Int, in dir: URL? = nil) throws -> URL {
        let url = try (dir ?? PDFFixtures.tempDirectory()).appendingPathComponent(name)
        try PDFFixtures.makePDF(at: url, pages: (0..<pages).map { "Seite \($0) Vertragsende" })
        return url
    }

    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    private func tileFiles(_ disk: TileDiskCache) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: disk.versionDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != TileDiskCache.sourceFileName }
        }
    }

    /// Every file below the version folder (diagnosis in failure messages).
    private func diskListing(_ disk: TileDiskCache) -> [String] {
        let all = FileManager.default.enumerator(atPath: disk.directory.path)?.allObjects as? [String] ?? []
        return all.sorted()
    }

    // MARK: §1 bounded writes

    @Test func pendingWritesAreBounded() throws {
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"), pendingWriteLimit: 4)
        disk.flush()                                       // the launch cleanup first
        let source = TileDiskCache.Source(path: "/x.pdf", modifiedAt: nil, size: 1)
        disk.suspendWritesForTesting()
        let names = (0..<10).map { TileDiskCache.name(source: "/x.pdf", parts: ["\($0)"]) }
        for name in names { disk.store(image(), named: name, source: source) }
        #expect(disk.pendingWriteCount == 4, "the waiting list holds at most the limit")
        #expect(disk.droppedWriteCount == 6)
        disk.resumeWritesForTesting()
        disk.flush()
        #expect(Set(tileFiles(disk)) == Set(names.suffix(4).map(\.file)), "the newest ones are written")
    }

    @Test func removeAllDropsPendingWritesFirst() async throws {
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"), pendingWriteLimit: 8)
        disk.flush()
        let source = TileDiskCache.Source(path: "/x.pdf", modifiedAt: nil, size: 1)
        disk.suspendWritesForTesting()
        for i in 0..<5 { disk.store(image(), named: TileDiskCache.name(source: "/x.pdf", parts: ["\(i)"]), source: source) }
        let clearing = Task.detached { await disk.removeAll() }
        for _ in 0..<200 where disk.pendingWriteCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(disk.pendingWriteCount == 0, "dropped before waiting for the queue")
        disk.resumeWritesForTesting()
        await clearing.value
        disk.flush()
        #expect(tileFiles(disk).isEmpty)
    }

    // MARK: §3 folders, cleanup, limit

    @Test func defaultLimitIsOneGB() throws {
        #expect(TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles")).byteLimit == 1 << 30)
    }

    @Test func changedFileReplacesItsTiles() async throws {
        let url = try fixture(pages: 2)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        let size = CGSize(width: 100, height: 141)
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 1), size: size)
        disk.flush()
        #expect(tileFiles(disk).count == 2, "on disk: \(diskListing(disk)), writes: \(disk.counters), pending \(disk.pendingWriteCount), dropped \(disk.droppedWriteCount)")
        try PDFFixtures.makePDF(at: url, pages: ["Neu", "Neu"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: size)
        disk.flush()
        #expect(tileFiles(disk).count == 1, "the old version's tiles are gone")
    }

    @Test func pruneRemovesGoneAndChangedPDFs() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let kept = try fixture("kept.pdf", pages: 1, in: dir)
        let gone = try fixture("gone.pdf", pages: 1, in: dir)
        let changed = try fixture("changed.pdf", pages: 1, in: dir)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        let size = CGSize(width: 100, height: 141)
        for url in [kept, gone, changed] { _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: size) }
        disk.flush()
        #expect(tileFiles(disk).count == 3)
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: changed.path)
        disk.pruneStale(under: dir)
        disk.flush()
        #expect(tileFiles(disk).count == 1)
        let keptFolder = TileDiskCache.name(source: kept.standardizedFileURL.path, parts: []).folder
        #expect(FileManager.default.fileExists(atPath: disk.folderURL(keptFolder).path))
    }

    /// Review I2: an unmounted volume or a folder that is not there right now keeps its tiles.
    @Test func pruneKeepsTilesOfUnreachableFolders() async throws {
        let parent = try PDFFixtures.tempDirectory()
        let dir = parent.appendingPathComponent("Volume", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try fixture("a.pdf", pages: 1, in: dir)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141))
        disk.flush()
        try FileManager.default.moveItem(at: dir, to: parent.appendingPathComponent("Unmounted", isDirectory: true))
        disk.pruneStale(under: dir)                         // an index run of the source while it is unplugged
        disk.flush()
        #expect(tileFiles(disk).count == 1, "the folder is gone for now, not the PDF")
    }

    /// Review M6: a path with a line break survives the `source` file.
    @Test func sourceWithLineBreakRoundTrips() {
        let source = TileDiskCache.Source(path: "/a/b\nc.pdf", modifiedAt: Date(timeIntervalSince1970: 1_000), size: 42)
        let read = TileDiskCache.Source(text: source.text)
        #expect(read.map { $0.matches(source) } == true)
    }

    /// Flaky test of 1.2.4 (root cause): the date read back from `source` could be a hair later than the
    /// file's own date (1970-seconds text vs. 2001-based `Date`), so a tile of the same version counted
    /// as older and was dropped. The same version must never count as older after the round trip.
    @Test func roundTripNeverLooksOlder() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let date = Date(timeIntervalSinceReferenceDate: Double.random(in: 700_000_000...800_000_000, using: &generator))
            let live = TileDiskCache.Source(path: "/x.pdf", modifiedAt: date, size: 1)
            let stored = TileDiskCache.Source(text: live.text)!
            #expect(!live.isOlder(than: stored), "\(date.timeIntervalSinceReferenceDate)")
            if live.isOlder(than: stored) { return }
        }
        let older = TileDiskCache.Source(path: "/x.pdf", modifiedAt: Date(timeIntervalSinceReferenceDate: 1_000), size: 1)
        let newer = TileDiskCache.Source(path: "/x.pdf", modifiedAt: Date(timeIntervalSinceReferenceDate: 2_000), size: 1)
        #expect(older.isOlder(than: newer) && !newer.isOlder(than: older))
    }

    /// Review M7: a tile of an older version of the file (its render started before the change) does not
    /// wipe the newer version's tiles.
    @Test func olderVersionDoesNotReplaceNewer() throws {
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        disk.flush()
        let newer = TileDiskCache.Source(path: "/x.pdf", modifiedAt: Date(timeIntervalSince1970: 2_000), size: 1)
        let older = TileDiskCache.Source(path: "/x.pdf", modifiedAt: Date(timeIntervalSince1970: 1_000), size: 1)
        disk.store(image(), named: TileDiskCache.name(source: "/x.pdf", parts: ["new"]), source: newer)
        disk.flush()
        disk.store(image(), named: TileDiskCache.name(source: "/x.pdf", parts: ["old"]), source: older)
        disk.flush()
        #expect(tileFiles(disk) == [TileDiskCache.name(source: "/x.pdf", parts: ["new"]).file])
    }

    /// Review M2: a long continuous scroll still prefetches (at least every `maxWait`), not only when it stops.
    @MainActor @Test func continuousScrollStillPrefetches() async throws {
        let prefetcher = TilePrefetcher()
        prefetcher.delay = .milliseconds(80)
        prefetcher.maxWait = .milliseconds(200)
        let context = TilePrefetcher.Context(cache: ThumbnailCache(), hits: [], columns: 4, tileSize: { _ in CGSize(width: 100, height: 141) },
                                             showAll: false, highlightKey: "", highlightRanges: nil, color: .yellow, ocr: nil)
        for i in 0..<14 {                                  // an appear event every 50 ms for 700 ms
            prefetcher.rowAppeared("row\(i)", context)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(prefetcher.batches >= 2, "sent \(prefetcher.batches) batches during the scroll")
    }

    @Test func removeTilesUnderAFolder() async throws {
        let a = try PDFFixtures.tempDirectory(), b = try PDFFixtures.tempDirectory()
        let inA = try fixture("a.pdf", pages: 1, in: a), inB = try fixture("b.pdf", pages: 1, in: b)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        for url in [inA, inB] { _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141)) }
        disk.flush()
        disk.removeTiles(under: a)
        disk.flush()
        #expect(tileFiles(disk).count == 1)
    }

    @Test func otherFormatsAreRemovedAtLaunch() throws {
        let root = try PDFFixtures.tempDirectory().appendingPathComponent("Tiles")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v1/abc"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("0123456789abcdef"))      // the flat 1.2.3 layout
        let disk = TileDiskCache(directory: root)
        disk.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["v\(TileDiskCache.formatVersion)"])
    }

    // MARK: §4 documents

    @Test func poolBoundsExtraDocumentsOverAllFiles() throws {
        let a = try fixture("a.pdf", pages: 3), b = try fixture("b.pdf", pages: 3)
        let pool = DocumentPool(limit: 5, instancesPerFile: 3, extraLimit: 2)
        let stamp = ThumbnailCache.FileStamp(modifiedAt: Date(), size: 1)
        let docsA = (0..<3).compactMap { _ in pool.checkout(a, stamp: stamp) }
        for doc in docsA { pool.checkin(doc, for: a, stamp: stamp) }
        #expect(pool.idleCount(a) == 3, "parallel renders of one file keep their documents")
        let docsB = (0..<3).compactMap { _ in pool.checkout(b, stamp: stamp) }
        for doc in docsB { pool.checkin(doc, for: b, stamp: stamp) }
        #expect(pool.idleCount(b) == 3)
        #expect(pool.idleCount(a) == 1, "the older file gives its extras back")
        #expect(pool.openCount == 6)
    }

    // MARK: §2 prefetch

    @Test func newPrefetchReplacesTheOld() async throws {
        let url = try fixture(pages: 12)
        let queue = TileRenderQueue(workers: 1)
        let cache = ThumbnailCache(disk: nil, queue: queue)
        let gate = DispatchSemaphore(value: 0)
        let blocker = Task { await queue.image(key: "block", priority: .visible) { gate.wait(); return nil } }
        for _ in 0..<200 where queue.startedCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let size = CGSize(width: 100, height: 141)
        cache.prefetch((0..<6).map { PageRef(url: url, pageIndex: $0) }, size: size)
        for _ in 0..<200 where queue.pendingCount < 6 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(queue.pendingCount == 6)
        cache.prefetch((6..<9).map { PageRef(url: url, pageIndex: $0) }, size: size)
        for _ in 0..<200 where queue.pendingCount != 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(queue.pendingCount == 3, "the old batch left the queue")
        gate.signal()
        _ = await blocker.value
    }

    @MainActor @Test func planCoversTheAreaNextToTheVisibleTiles() {
        let folder = URL(fileURLWithPath: "/d", isDirectory: true)
        func hit(_ name: String, pages: Int) -> DocumentHit {
            DocumentHit(url: folder.appendingPathComponent(name), relativePath: name, modifiedAt: .distantPast, pageHits: [],
                        totalMatches: 0, relevance: 0, sourceRoot: folder, pageCount: pages)
        }
        let hits = [hit("a.pdf", pages: 20), hit("b.pdf", pages: 20), hit("c.pdf", pages: 20), hit("d.pdf", pages: 20), hit("e.pdf", pages: 20)]
        let plan = TilePrefetcher.plan(hits: hits, visible: [hits[0].id, hits[1].id], lastTile: [hits[0].id: 5], columns: 4,
                                       showAll: false, highlighted: false)
        func pages(_ name: String) -> [Int] { plan.plain.filter { $0.url.lastPathComponent == name }.map(\.pageIndex) }
        #expect(pages("a.pdf") == [6, 7, 8, 9], "after the last visible tile")
        #expect(pages("b.pdf") == [4, 5, 6, 7], "no tile report: the screen after the first one")
        #expect(pages("c.pdf") == [0, 1, 2, 3] && pages("d.pdf") == [0, 1, 2, 3], "two rows below")
        #expect(pages("e.pdf").isEmpty)
        #expect(plan.marked.isEmpty)
    }

    // MARK: §5 OCR version

    @Test func ocrVersionFollowsTextAndBoxes() {
        let word = OCRWord(range: NSRange(location: 0, length: 7), box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        let moved = OCRWord(range: NSRange(location: 0, length: 7), box: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.05))
        let a = ThumbnailCache.ocrVersion(OCRPageText(text: "Vertrag", words: [word]))
        #expect(a == ThumbnailCache.ocrVersion(OCRPageText(text: "Vertrag", words: [word])))
        #expect(a != ThumbnailCache.ocrVersion(OCRPageText(text: "Vertrag", words: [moved])), "same counts, other boxes")
        #expect(ThumbnailCache.ocrVersion(nil) == "")
    }
}
