// TileDiskCache.swift — 1.2.3 tile cache
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import os

/// Rendered tiles on disk (spec 1.2.3), so a page drawn once shows at once again: after scrolling
/// back, after the memory cache let it go, and after a restart.
///
/// - Lives in `~/Library/Caches/local.pdfsucher/Tiles` (macOS may purge it; nothing is lost).
/// - One HEIC file per tile (keeps transparency, about a tenth of PNG); PNG if HEIC cannot be written.
/// - The name is a hash of everything the picture depends on, including the file's modification date
///   and size: a changed file never shows an old tile, its old tiles simply age out.
/// - Bounded: when over `byteLimit`, the least recently used files go until 3/4 of it is left.
public final class TileDiskCache: Sendable {
    public static let standard: TileDiskCache = {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return TileDiskCache(directory: caches.appendingPathComponent("local.pdfsucher/Tiles", isDirectory: true))
    }()

    /// Bump when the drawing changes, so old tiles are not shown.
    static let formatVersion = "1"
    private static let log = Logger(subsystem: "local.pdfsucher", category: "TileDiskCache")

    public let directory: URL
    public let byteLimit: Int
    private let writes = DispatchQueue(label: "local.pdfsucher.tiles.disk", qos: .utility)
    private let reads = DispatchQueue(label: "local.pdfsucher.tiles.read", qos: .userInitiated, attributes: .concurrent)
    private let writesSinceTrim = Mutex(0)
    private static let trimEvery = 200

    public init(directory: URL, byteLimit: Int = 512 << 20) {
        self.directory = directory
        self.byteLimit = max(byteLimit, 0)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writes.async { [self] in trim() }
    }

    /// File name for the parts a tile depends on.
    static func name(for parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(([formatVersion] + parts).joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    func contains(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }

    /// The stored tile, decoded off the calling thread; nil if there is none or it cannot be read.
    func image(named name: String) async -> CGImage? {
        let url = url(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = await withCheckedContinuation { continuation in
            reads.async { continuation.resume(returning: Self.decode(url)) }
        }
        if image != nil {
            // Recently used: keep it at the next trim.
            writes.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        } else {
            writes.async { try? FileManager.default.removeItem(at: url) }   // damaged: render again
        }
        return image
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Writes in the background; the file appears complete or not at all.
    func store(_ image: CGImage, named name: String) {
        writes.async { [self] in
            let target = url(for: name)
            let temp = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
            guard Self.encode(image, to: temp, type: .heic) || Self.encode(image, to: temp, type: .png) else {
                Self.log.error("Cannot write tile \(name, privacy: .public)")
                try? FileManager.default.removeItem(at: temp)
                return
            }
            if rename(temp.path, target.path) != 0 { try? FileManager.default.removeItem(at: temp) }
            let due = writesSinceTrim.withLock { count -> Bool in
                count += 1
                if count >= Self.trimEvery { count = 0; return true }
                return false
            }
            if due { trim() }
        }
    }

    static func encode(_ image: CGImage, to url: URL, type: UTType) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Total size of the stored tiles in bytes.
    public var byteCount: Int { entries().reduce(0) { $0 + $1.size } }

    /// Removes every stored tile.
    public func removeAll() {
        writes.sync {
            for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    /// Waits for pending writes (tests).
    func flush() { writes.sync {} }

    /// Trims now (tests).
    func trimNow() { writes.sync { trim() } }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    /// Drops the least recently used tiles until 3/4 of the limit is left (runs on `writes`).
    private func trim() {
        let all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }
        for entry in all.sorted(by: { $0.date < $1.date }) where total > byteLimit / 4 * 3 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
