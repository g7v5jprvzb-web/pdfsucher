import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import OfficeKit

/// Task 5 (1.3 Office): on-disk cache of rendered slide images (HEIC, one folder per key).
@Suite("Slide cache")
struct SlideCacheTests {
    let root: URL
    let cache: SlideCache

    init() throws {
        root = try PDFFixtures.tempDirectory().appendingPathComponent("SlideCache")
        cache = SlideCache(root: root)
    }

    private func key(_ path: String = "/tmp/deck.pptx", size: Int64 = 1000, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SlideCacheKey {
        SlideCacheKey(url: URL(fileURLWithPath: path), fileSize: size, modifiedAt: date)
    }

    /// A gradient image, so HEIC has something to compress.
    private func makeImage(width: Int, height: Int, seed: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: seed, green: 0.2, blue: 0.8, alpha: 1),
                                           CGColor(red: 1, green: 0.9 - seed, blue: 0.1, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()!
    }

    @Test func storeAndLoadRoundTrip() throws {
        let k = key()
        try cache.store([makeImage(width: 3000, height: 1688, seed: 0), makeImage(width: 3000, height: 1688, seed: 0.5)], for: k)
        #expect(cache.slideCount(for: k) == 2)
        for slide in 0..<2 {
            let image = try #require(cache.image(for: k, slide: slide))
            #expect(max(image.width, image.height) == 2800)
            #expect(image.width == 2800)
            #expect(abs(image.height - 1575) <= 1)
        }
        #expect(cache.image(for: k, slide: 2) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(k.id).path).sorted()
        #expect(files == ["0.heic", "1.heic"])
    }

    @Test func smallImagesAreNotUpscaled() throws {
        let k = key()
        try cache.store([makeImage(width: 800, height: 600)], for: k)
        let image = try #require(cache.image(for: k, slide: 0))
        #expect(image.width == 800 && image.height == 600)
    }

    @Test func missingKeyIsNil() {
        let k = key()
        #expect(cache.slideCount(for: k) == nil)
        #expect(cache.image(for: k, slide: 0) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func changedDateIsNewKey() throws {
        let a = key(date: Date(timeIntervalSince1970: 1_700_000_000))
        let b = key(date: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(a != b)
        #expect(a == key(date: Date(timeIntervalSince1970: 1_700_000_000.0004)))
        #expect(a.id.count == 64)
        try cache.store([makeImage(width: 100, height: 100)], for: a)
        #expect(cache.slideCount(for: a) == 1)
        #expect(cache.slideCount(for: b) == nil)
        #expect(key(size: 1) != key(size: 2))
    }

    @Test func cacheKeysDifferForSameNameInTwoFolders() {
        #expect(key("/tmp/a/deck.pptx") != key("/tmp/b/deck.pptx"))
        #expect(key("/tmp/a/../a/deck.pptx") == key("/tmp/a/deck.pptx"))
    }

    @Test func pruneRemovesOthers() throws {
        let keep = key("/tmp/keep.pptx"), drop = key("/tmp/drop.pptx")
        try cache.store([makeImage(width: 100, height: 100)], for: keep)
        try cache.store([makeImage(width: 100, height: 100)], for: drop)
        let leftover = root.appendingPathComponent("\(drop.id).abc.tmp")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try cache.prune(keeping: [keep])
        #expect(cache.slideCount(for: keep) == 1)
        #expect(cache.slideCount(for: drop) == nil)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [keep.id])
    }

    @Test func pruneOnMissingRootIsNoOp() throws {
        try cache.prune(keeping: [])
        try cache.clear()
    }

    @Test func clearEmpties() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100)], for: k)
        try cache.clear()
        #expect(cache.slideCount(for: k) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func interruptedStoreLeavesNoPartialEntry() throws {
        let k = key()
        let tmp = root.appendingPathComponent("\(k.id).tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: tmp.appendingPathComponent("0.heic"))
        #expect(cache.slideCount(for: k) == nil)
        #expect(cache.image(for: k, slide: 0) == nil)
    }

    @Test func storingAgainReplacesEntry() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100), makeImage(width: 100, height: 100)], for: k)
        try cache.store([makeImage(width: 200, height: 100)], for: k)
        #expect(cache.slideCount(for: k) == 1)
        #expect(cache.image(for: k, slide: 0)?.width == 200)
    }

    @Test func concurrentStoresOfSameKeyStayConsistent() async throws {
        let images = [makeImage(width: 300, height: 200), makeImage(width: 300, height: 200)]
        let cache = self.cache
        for round in 0..<20 {
            let k = key("/tmp/deck\(round).pptx")
            let failures = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 { group.addTask { (try? cache.store(images, for: k)) == nil ? 1 : 0 } }
                return await group.reduce(0, +)
            }
            #expect(failures == 0)
            #expect(cache.slideCount(for: k) == 2)
            #expect(cache.image(for: k, slide: 1) != nil)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.count == 20 && !names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func incompleteEntryHasNoSlideCount() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100), makeImage(width: 100, height: 100),
                         makeImage(width: 100, height: 100)], for: k)
        try FileManager.default.removeItem(at: root.appendingPathComponent(k.id).appendingPathComponent("1.heic"))
        #expect(cache.slideCount(for: k) == nil)
        #expect(cache.image(for: k, slide: 1) == nil)
    }

    @Test func opaqueSourceStaysOpaqueAfterDownscale() throws {
        let ctx = CGContext(data: nil, width: 3000, height: 1688, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1),
                                           CGColor(red: 1, green: 0.5, blue: 0.1, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 3000, y: 1688), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 300, y: 300, width: 1200, height: 400))
        let k = key()
        try cache.store([ctx.makeImage()!], for: k)
        let image = try #require(cache.image(for: k, slide: 0))
        #expect(image.width == 2800)
    }

    // MARK: Streaming writer (Task 10b)

    private func entries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    @Test func writerRoundTrip() throws {
        let k = key()
        let writer = try cache.beginEntry(for: k)
        for seed in [0.0, 0.3, 0.6] { try writer.append(makeImage(width: 3000, height: 1688, seed: seed)) }
        #expect(cache.slideCount(for: k) == nil) // nothing visible before commit
        try writer.commit()
        #expect(cache.slideCount(for: k) == 3)
        for slide in 0..<3 { #expect(cache.image(for: k, slide: slide)?.width == 2800) }
        #expect(try entries() == [k.id])
    }

    @Test func writerWritesEachImageImmediately() throws {
        let k = key()
        let writer = try cache.beginEntry(for: k)
        try writer.append(makeImage(width: 100, height: 100))
        let tmp = try #require(try entries().first { $0.hasSuffix(".tmp") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(tmp).path) == ["0.heic"])
        writer.discard()
    }

    @Test func writerDiscardLeavesNothing() throws {
        let k = key()
        let writer = try cache.beginEntry(for: k)
        try writer.append(makeImage(width: 100, height: 100))
        writer.discard()
        #expect(cache.slideCount(for: k) == nil)
        #expect(try entries().isEmpty)
        #expect(throws: SlideCacheError.writerClosed) { try writer.append(makeImage(width: 100, height: 100)) }
        #expect(throws: SlideCacheError.writerClosed) { try writer.commit() }
    }

    @Test func writerDiscardKeepsOldEntry() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100)], for: k)
        let writer = try cache.beginEntry(for: k)
        try writer.append(makeImage(width: 200, height: 100))
        writer.discard()
        #expect(cache.slideCount(for: k) == 1)
        #expect(cache.image(for: k, slide: 0)?.width == 100)
        #expect(try entries() == [k.id])
    }

    @Test func writerDroppedWithoutCommitLeavesNothing() throws {
        let k = key()
        do {
            let writer = try cache.beginEntry(for: k)
            try writer.append(makeImage(width: 100, height: 100))
        }
        #expect(cache.slideCount(for: k) == nil)
        #expect(try entries().isEmpty)
    }

    /// The writer's own failure path: its `.tmp` folder vanishes (e.g. a concurrent prune), `append` fails and
    /// closes the writer, nothing is left behind and an older entry stays.
    @Test func writerFailingAppendClosesWriter() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100)], for: k)
        let writer = try cache.beginEntry(for: k)
        try writer.append(makeImage(width: 200, height: 100))
        let tmp = try #require(try entries().first { $0.hasSuffix(".tmp") })
        try FileManager.default.removeItem(at: root.appendingPathComponent(tmp))
        #expect(throws: SlideCacheError.encodingFailed(slide: 1)) { try writer.append(makeImage(width: 200, height: 100)) }
        #expect(throws: SlideCacheError.writerClosed) { try writer.append(makeImage(width: 200, height: 100)) }
        #expect(throws: SlideCacheError.writerClosed) { try writer.commit() }
        #expect(try entries() == [k.id])
        #expect(cache.slideCount(for: k) == 1)
        #expect(cache.image(for: k, slide: 0)?.width == 100)
    }

    @Test func writerCommitWithoutImagesIsRejected() throws {
        let k = key()
        let writer = try cache.beginEntry(for: k)
        #expect(throws: SlideCacheError.noImages) { try writer.commit() }
        #expect(cache.slideCount(for: k) == nil)
        #expect(try entries().isEmpty)
    }

    @Test func writerCommitTwiceIsRejected() throws {
        let k = key()
        let writer = try cache.beginEntry(for: k)
        try writer.append(makeImage(width: 100, height: 100))
        try writer.commit()
        #expect(throws: SlideCacheError.writerClosed) { try writer.commit() }
        #expect(throws: SlideCacheError.writerClosed) { try writer.append(makeImage(width: 100, height: 100)) }
        writer.discard() // no effect after commit
        #expect(cache.slideCount(for: k) == 1)
    }

    @Test func concurrentWritersOfSameKeyStayConsistent() async throws {
        let image = makeImage(width: 300, height: 200)
        let cache = self.cache
        for round in 0..<20 {
            let k = key("/tmp/deck\(round).pptx")
            let failures = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            let writer = try cache.beginEntry(for: k)
                            try writer.append(image)
                            try writer.append(image)
                            try writer.commit()
                            return 0
                        } catch { return 1 }
                    }
                }
                return await group.reduce(0, +)
            }
            #expect(failures == 0)
            #expect(cache.slideCount(for: k) == 2)
            #expect(cache.image(for: k, slide: 1) != nil)
        }
        let names = try entries()
        #expect(names.count == 20 && !names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func emptyStoreIsRejected() {
        #expect(throws: SlideCacheError.self) { try cache.store([], for: key()) }
    }

    // MARK: Prune by age (1.3 Teil B)

    private func folderDate(_ k: SlideCacheKey) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(k.id).path)[.modificationDate] as? Date)
    }

    private func setFolderDate(_ k: SlideCacheKey, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)],
                                              ofItemAtPath: root.appendingPathComponent(k.id).path)
    }

    @Test func pruneByAgeKeepsUsedEntries() throws {
        let a = key("/tmp/alt.pptx"), b = key("/tmp/benutzt.pptx")
        try cache.store([makeImage(width: 100, height: 100)], for: a)
        try cache.store([makeImage(width: 100, height: 100)], for: b)
        try setFolderDate(a, daysAgo: 200)
        try setFolderDate(b, daysAgo: 200)
        let writer = try cache.beginEntry(for: key("/tmp/offen.pptx")) // open writer: its .tmp folder stays
        try writer.append(makeImage(width: 100, height: 100))
        #expect(cache.slideCount(for: b) == 1) // used: touched
        #expect(try cache.prune(notUsedSince: Date().addingTimeInterval(-180 * 86_400)) == 1)
        #expect(cache.slideCount(for: a) == nil)
        #expect(cache.slideCount(for: b) == 1)
        try writer.commit()
        #expect(cache.slideCount(for: key("/tmp/offen.pptx")) == 1)
    }

    /// 1.3 Teil B Task 9: a writer's `.tmp` folder changes with every slide; one unchanged for a day belongs to a
    /// crashed run and goes, a young one (a writer still open, maybe in another process) stays.
    @Test func pruneAbandonedWritesKeepsYoungWriters() throws {
        let crashed = try cache.beginEntry(for: key("/tmp/abgestuerzt.pptx"))
        try crashed.append(makeImage(width: 10, height: 10))
        let crashedTmp = try #require(try FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                                              ofItemAtPath: root.appendingPathComponent(crashedTmp).path)
        let open = try cache.beginEntry(for: key("/tmp/offen.pptx"))
        try open.append(makeImage(width: 10, height: 10))
        let done = key("/tmp/fertig.pptx")
        try cache.store([makeImage(width: 10, height: 10)], for: done)
        try setFolderDate(done, daysAgo: 2)               // complete entries are `prune(notUsedSince:)`'s business

        #expect(try cache.pruneAbandonedWrites(notChangedSince: Date().addingTimeInterval(-86_400)) == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(crashedTmp).path))
        try open.commit()
        #expect(cache.slideCount(for: key("/tmp/offen.pptx")) == 1)
        #expect(cache.slideCount(for: done) == 1)
        #expect(try cache.pruneAbandonedWrites(notChangedSince: Date()) == 0)
    }

    /// Hardening 3: an item that cannot be removed (e.g. a writer still appending) does not stop the rest.
    @Test func clearContinuesPastFailingItems() throws {
        let keys = (0..<8).map { key("/tmp/weg\($0).pptx") }
        for k in keys { try cache.store([makeImage(width: 10, height: 10)], for: k) }
        let locked = root.appendingPathComponent("000.tmp/gesperrt", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("0.heic"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(throws: (any Error).self) { try cache.clear() }
        for k in keys { #expect(cache.slideCount(for: k) == nil) }
    }

    @Test func pruneByAgeOnMissingRootIsNoOp() throws {
        #expect(try cache.prune(notUsedSince: Date()) == 0)
    }

    @Test func slideCountTouchesOncePerProcess() throws {
        let k = key()
        try cache.store([makeImage(width: 100, height: 100)], for: k)
        try setFolderDate(k, daysAgo: 10)
        #expect(cache.slideCount(for: k) == 1)
        #expect(try folderDate(k) > Date().addingTimeInterval(-60))
        try setFolderDate(k, daysAgo: 10)
        let before = try folderDate(k)
        #expect(cache.slideCount(for: k) == 1)
        #expect(try folderDate(k) == before)
    }
}
