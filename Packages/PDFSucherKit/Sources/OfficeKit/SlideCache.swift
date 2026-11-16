import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Identifies one rendering of one file: SHA-256 over the standardized path, the size and the modification date
/// (milliseconds). A changed file, or the same name in another folder, gets a different key.
public struct SlideCacheKey: Sendable, Hashable {
    /// Hex digest; also the entry's folder name.
    public let id: String

    public init(url: URL, fileSize: Int64, modifiedAt: Date) {
        let ms = Int64((modifiedAt.timeIntervalSince1970 * 1000).rounded())
        let text = "\(url.standardizedFileURL.path)|\(fileSize)|\(ms)"
        id = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SlideCacheError: Error, Equatable {
    case noImages
    case encodingFailed(slide: Int)
    /// `append` or `commit` on a `SlideCacheWriter` that was already committed or discarded.
    case writerClosed
}

/// On-disk cache of rendered slide images: one folder per key under `root`, files `0.heic`, `1.heic`, …
///
/// Format: HEIC at quality 0.85, long side at most 2800 px (never upscaled): at least 200 dpi when a 16:9 slide
/// (960 pt wide) is output at slide size (spec §5a), sharp at high tile zoom, small on disk.
///
/// The type holds no state besides `root`; the file system is the state, so it is safe from several threads.
/// `store` and `SlideCacheWriter` write into a uniquely named `<key>.<UUID>.tmp` folder and then move it into place, so a reader sees
/// the old or the new complete entry (best effort: replacing an existing folder uses `replaceItemAt`, which is not
/// documented as atomic for directories, in practice it behaves atomically on APFS). If the entry already exists (e.g. two concurrent
/// stores), it is replaced. Callers treat a nil from `image(for:slide:)` / `slideCount(for:)` as a cache miss.
///
/// Requires HEIC encoding (Apple Silicon, macOS 26); there is deliberately no format fallback. When encoding
/// fails, `store` throws `SlideCacheError.encodingFailed` and removes its `.tmp` folder, so no partial entry stays.
public final class SlideCache: Sendable {
    public static let maxLongSide = 2800
    public static let quality = 0.85

    /// `~/Library/Application Support/PDFSucher/SlideCache`; created on the first `store`.
    public static let shared: SlideCache = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return SlideCache(root: base.appendingPathComponent("PDFSucher/SlideCache", isDirectory: true))
    }()

    private let root: URL
    /// Keys whose entry folder `slideCount(for:)` already touched in this process (one `SlideCache` per root).
    private let touched = Mutex<Set<String>>([])

    public init(root: URL) { self.root = root }

    private func folder(for key: SlideCacheKey) -> URL { root.appendingPathComponent(key.id, isDirectory: true) }

    /// Writes all `images` as one entry (see `beginEntry`); replaces an existing entry. On any error the `.tmp`
    /// folder is removed and the old entry (if any) stays.
    public func store(_ images: [CGImage], for key: SlideCacheKey) throws {
        guard !images.isEmpty else { throw SlideCacheError.noImages }
        let writer = try beginEntry(for: key)
        for image in images { try writer.append(image) }
        try writer.commit()
    }

    /// Starts an entry that is written one slide at a time, so a caller never has to hold all slide images in
    /// memory: each `append` encodes and writes `<n>.heic` into the writer's own `<key>.<UUID>.tmp` folder right
    /// away, `commit` publishes the folder like `store`, `discard` (or dropping the writer without commit) removes it.
    public func beginEntry(for key: SlideCacheKey) throws -> SlideCacheWriter {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent("\(key.id).\(UUID().uuidString).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        return SlideCacheWriter(tmp: tmp, final: folder(for: key))
    }

    public func image(for key: SlideCacheKey, slide: Int) -> CGImage? {
        let url = folder(for: key).appendingPathComponent("\(slide).heic")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The slide image scaled down so its long side is at most `maxPixel` (decoded at that size, for thumbnails).
    public func image(for key: SlideCacheKey, slide: Int, maxPixel: Int) -> CGImage? {
        let url = folder(for: key).appendingPathComponent("\(slide).heic")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Number of slide files of a complete entry (`0.heic … (n-1).heic` all present); nil when missing or incomplete.
    /// The first call per key in this process that finds a complete entry sets its folder's modification date to
    /// now, marking it as used for `prune(notUsedSince:)`.
    public func slideCount(for key: SlideCacheKey) -> Int? {
        let folder = folder(for: key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let present = Set(names)
        let count = names.filter { $0.hasSuffix(".heic") }.count
        guard count > 0, (0..<count).allSatisfy({ present.contains("\($0).heic") }) else { return nil }
        // Remembered only after a successful touch: a failed one is tried again on the next call.
        if !touched.withLock({ $0.contains(key.id) }),
           (try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)) != nil {
            touched.withLock { _ = $0.insert(key.id) }
        }
        return count
    }

    /// Removes every entry not in `keeping`, plus leftover `.tmp` folders. Continues past a failing item and
    /// rethrows the first error at the end. Must not run concurrently with `store` or an open `SlideCacheWriter`
    /// (it would delete their `.tmp` folder; the writer then fails and closes); meant for app start and "Cache leeren".
    public func prune(keeping keys: Set<SlideCacheKey>) throws {
        let keep = Set(keys.map(\.id))
        var firstError: Error?
        for name in try existingNames() where name.hasSuffix(".tmp") || !keep.contains(name) {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Removes every entry (complete or not) whose folder was last changed or used (`slideCount(for:)` touches it)
    /// before `cutoff` (1.3 Teil B, age limit at app start); returns how many. Skips `.tmp` folders, so it is safe
    /// next to an open `SlideCacheWriter`. Continues past a failing item and rethrows the first error at the end.
    /// Race: an entry read (and touched) between the date check and the removal is removed anyway; its reader
    /// gets a cache miss, which the app treats like any missing slide (laid out again, `AppModel.slidesMissing`).
    @discardableResult
    public func prune(notUsedSince cutoff: Date) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        var firstError: Error?
        for name in try existingNames() where !name.hasSuffix(".tmp") {
            let url = root.appendingPathComponent(name)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  date < cutoff else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return removed
    }

    /// Removes the least recently used entries (oldest folder date first, as `prune(notUsedSince:)` reads it) until
    /// the complete entries together take at most `maxBytes` (audit 2026-11-15: the age limit alone let the cache grow
    /// without bound for 180 days). Skips `.tmp` folders like `prune(notUsedSince:)`, with the same race. Returns how
    /// many; continues past a failing item and rethrows the first error at the end.
    @discardableResult
    public func prune(keepingAtMostBytes maxBytes: Int) throws -> Int {
        let fm = FileManager.default
        var entries: [(url: URL, date: Date, bytes: Int)] = []
        for name in try existingNames() where !name.hasSuffix(".tmp") {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let date = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
            let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let bytes = files.reduce(0) { sum, file in
                sum + (((try? fm.attributesOfItem(atPath: url.appendingPathComponent(file).path))?[.size] as? Int) ?? 0)
            }
            entries.append((url, date, bytes))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        var removed = 0
        var firstError: Error?
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            do {
                try fm.removeItem(at: entry.url)
                total -= entry.bytes
                removed += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return removed
    }

    /// Removes `.tmp` folders of writers that crashed or were killed (1.3 Teil B, app start): those whose folder
    /// date is before `cutoff`. An open writer's folder changes with every `append` (a new file in it), so a young
    /// one — a writer still working, possibly in another process — is never touched; the app passes a day.
    /// Complete entries are left alone. Returns how many; continues past a failing item and rethrows the first error.
    @discardableResult
    public func pruneAbandonedWrites(notChangedSince cutoff: Date) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        var firstError: Error?
        for name in try existingNames() where name.hasSuffix(".tmp") {
            let url = root.appendingPathComponent(name)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  date < cutoff else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return removed
    }

    /// Removes every entry and every `.tmp` folder („Folien-Cache leeren“). Like `prune(keeping:)` it must not run
    /// next to an open writer: its next `append`/`commit` fails and no entry is published (the app stops the
    /// layout first). Continues past an item that cannot be removed (e.g. the `.tmp` folder of a cancelled render
    /// that is still appending) and rethrows the first error at the end, so everything else is gone.
    public func clear() throws {
        var firstError: Error?
        for name in try existingNames() {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Size of every file in the cache in bytes (settings „Speicher“), `.tmp` folders included.
    public var byteCount: Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.totalFileAllocatedSize ?? values.fileSize ?? 0
        }
        return total
    }

    private func existingNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    static func write(_ image: CGImage, to url: URL, slide: Int) throws {
        let scaled = downscaled(image)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw SlideCacheError.encodingFailed(slide: slide) }
        CGImageDestinationAddImage(destination, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SlideCacheError.encodingFailed(slide: slide) }
    }

    /// Scales so the long side is at most `maxLongSide`; smaller images are returned unchanged.
    private static func downscaled(_ image: CGImage) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > maxLongSide else { return image }
        let factor = Double(maxLongSide) / Double(longSide)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let info = (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }
}

/// One cache entry being written slide by slide (from `SlideCache.beginEntry(for:)`).
///
/// Thread-safe; calls are serialized. After `commit` or `discard` the writer is closed: `append` and `commit` throw
/// `SlideCacheError.writerClosed`, `discard` does nothing. A failing `append` or `commit` discards the writer (the
/// `.tmp` folder is removed, an existing entry stays). A writer released while still open removes its `.tmp` folder,
/// so an error or a cancellation in the caller never leaves a partial entry.
public final class SlideCacheWriter: Sendable {
    private let tmp: URL
    private let final: URL
    /// Number of slides written so far; nil once closed.
    private let written = Mutex<Int?>(0)

    init(tmp: URL, final: URL) {
        self.tmp = tmp
        self.final = final
    }

    deinit { discard() }

    /// Downscales, HEIC-encodes and writes `image` as the next slide (`0.heic`, `1.heic`, …).
    public func append(_ image: CGImage) throws {
        try written.withLock { count in
            guard let index = count else { throw SlideCacheError.writerClosed }
            do {
                try autoreleasepool {
                    try SlideCache.write(image, to: tmp.appendingPathComponent("\(index).heic"), slide: index)
                }
                count = index + 1
            } catch {
                count = nil
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        }
    }

    /// Publishes the entry atomically (replacing an existing one). Throws `noImages` when nothing was appended.
    public func commit() throws {
        try written.withLock { count in
            guard let written = count else { throw SlideCacheError.writerClosed }
            count = nil
            let fm = FileManager.default
            do {
                guard written > 0 else { throw SlideCacheError.noImages }
                if fm.fileExists(atPath: final.path) {
                    _ = try fm.replaceItemAt(final, withItemAt: tmp)
                } else {
                    do { try fm.moveItem(at: tmp, to: final) } catch {
                        // Lost a race against a concurrent store of the same key.
                        _ = try fm.replaceItemAt(final, withItemAt: tmp)
                    }
                }
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
    }

    /// Removes the `.tmp` folder; no effect after `commit` or a previous `discard`.
    public func discard() {
        written.withLock { count in
            guard count != nil else { return }
            count = nil
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
