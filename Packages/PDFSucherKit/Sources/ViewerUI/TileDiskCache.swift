// TileDiskCache.swift — 1.2.3 tile cache; 1.2.4 bounded writes, per-file folders, cleanup
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import os

/// Rendered tiles on disk (spec 1.2.3), so a page drawn once shows at once again: after scrolling
/// back, after the memory cache let it go, and after a restart.
///
/// - Lives in `~/Library/Caches/local.pdfsucher/Tiles/v<format>/<hash of the PDF's path>/` (macOS may
///   purge it; nothing is lost). Each PDF folder holds a `source` file (path, modification date, size):
///   tiles of PDFs that are gone or changed are removed after a source's index run (`pruneStale(under:)`);
///   tiles outside the sources go once the sources are restored (`dropTiles(notUnder:)`). The launch itself
///   reads only the cache's folder (1.3.1: no access to the PDFs, so no macOS access prompt).
/// - One HEIC file per tile (keeps transparency, about a tenth of PNG); PNG if HEIC cannot be written.
/// - The tile's name is a hash of everything the picture depends on: a changed file never shows an old tile.
/// - Bounded: over `byteLimit` (1 GB) the least recently used tiles go until 3/4 of it is left; at most
///   `pendingWriteLimit` tiles wait to be written, older waiting ones are dropped (spec 1.2.4 §1).
public final class TileDiskCache: Sendable {
    public static let standard: TileDiskCache = {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return TileDiskCache(directory: caches.appendingPathComponent("local.pdfsucher/Tiles", isDirectory: true))
    }()

    /// Bump when the drawing changes, so old tiles are not shown (folders of other versions are deleted).
    static let formatVersion = "2"
    static let sourceFileName = "source"
    private static let log = Logger(subsystem: "local.pdfsucher", category: "TileDiskCache")

    /// Where one tile lives: the folder of its PDF and the tile's own name.
    struct Name: Hashable, Sendable {
        let folder: String
        let file: String
    }

    /// The version of a PDF its tiles were drawn from.
    struct Source: Equatable, Sendable {
        let path: String
        let modifiedAt: Date?
        let size: Int?

        /// Date, size, then the path last: a path may contain a line break (review M6). The date is written as
        /// `Date`'s own value (seconds since 2001), so it reads back exactly: in seconds since 1970 it could come
        /// back a hair later, and a tile of the same version counted as older (the flaky test of 1.2.4).
        var text: String {
            [modifiedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "-", size.map(String.init) ?? "-", path].joined(separator: "\n")
        }

        init(path: String, modifiedAt: Date?, size: Int?) {
            self.path = path
            self.modifiedAt = modifiedAt
            self.size = size
        }

        init?(text: String) {
            let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard lines.count == 3, !lines[2].isEmpty else { return nil }
            modifiedAt = Double(lines[0]).map { Date(timeIntervalSinceReferenceDate: $0) }
            size = Int(lines[1])
            path = lines[2]
        }

        /// The file as it is on disk now; nil when it is gone.
        static func current(_ path: String) -> Source? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return Source(path: path, modifiedAt: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.intValue)
        }

        /// This version is older than `other` by more than the tolerance `matches` uses (1 ms).
        func isOlder(than other: Source) -> Bool {
            guard let date = modifiedAt, let otherDate = other.modifiedAt else { return false }
            return otherDate.timeIntervalSince(date) > 0.001
        }

        func matches(_ other: Source) -> Bool {
            guard path == other.path, size == other.size else { return false }
            switch (modifiedAt, other.modifiedAt) {
            case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.001
            case (nil, nil): return true
            default: return false
            }
        }
    }

    private struct Pending {
        var items: [(name: Name, source: Source, image: CGImage)] = []
        var draining = false
        var dropped = 0
    }

    /// The cache's root (all format versions below it).
    public let directory: URL
    /// The current format version's folder.
    let versionDirectory: URL
    public let byteLimit: Int
    public let pendingWriteLimit: Int
    private let writes = DispatchQueue(label: "local.pdfsucher.tiles.disk", qos: .utility)
    /// Decoding from disk: a few at a time (spec 1.2.4 §5).
    private let reads: OperationQueue
    private let pending = Mutex(Pending())
    private let writesSinceTrim = Mutex(0)
    /// What the write queue decided (tests, diagnosis).
    struct Counters: Equatable, Sendable { var written = 0, folderResets = 0, staleDrops = 0, failures = 0 }
    private let counterState = Mutex(Counters())
    var counters: Counters { counterState.withLock { $0 } }
    private static let trimEvery = 200

    public init(directory: URL, byteLimit: Int = 1 << 30, pendingWriteLimit: Int = 32) {
        self.directory = directory
        versionDirectory = directory.appendingPathComponent("v\(Self.formatVersion)", isDirectory: true)
        self.byteLimit = max(byteLimit, 0)
        self.pendingWriteLimit = max(pendingWriteLimit, 1)
        let reads = OperationQueue()
        reads.maxConcurrentOperationCount = 4
        reads.qualityOfService = .userInitiated
        self.reads = reads
        try? FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        // Only the cache's own folder at launch: asking the entries' PDFs here made macOS ask for access to
        // Downloads and Documents (1.3.1). `dropTiles(notUnder:)` and the index runs' `pruneStale(under:)` do that.
        writes.async { [self] in
            removeOtherVersions()
            removeUnreadableFolders()
            trim()
        }
    }

    /// Name for the parts a tile depends on; `source` is the PDF's path (its folder).
    static func name(source: String, parts: [String]) -> Name {
        Name(folder: hash([source]), file: hash([formatVersion, source] + parts))
    }

    private static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func folderURL(_ folder: String) -> URL { versionDirectory.appendingPathComponent(folder, isDirectory: true) }
    func url(for name: Name) -> URL { folderURL(name.folder).appendingPathComponent(name.file) }

    func contains(_ name: Name) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }

    /// The stored tile, decoded off the calling thread; nil if there is none, it cannot be read, or the
    /// calling task was cancelled before decoding started.
    func image(named name: Name) async -> CGImage? {
        let url = url(for: name)
        guard FileManager.default.fileExists(atPath: url.path), !Task.isCancelled else { return nil }
        let cancelled = Mutex(false)
        let decoded: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                reads.addOperation {
                    // Scrolled away before its turn: not decoded at all.
                    continuation.resume(returning: cancelled.withLock { $0 } ? nil : Self.decode(url))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        if decoded != nil {
            // Recently used: keep it at the next trim.
            writes.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        } else if !cancelled.withLock({ $0 }) {
            writes.async { try? FileManager.default.removeItem(at: url) }   // damaged: render again
        }
        return decoded
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Writes in the background; the file appears complete or not at all. At most `pendingWriteLimit`
    /// tiles wait; the oldest waiting one is dropped for a new one (it is rendered again when needed).
    func store(_ image: CGImage, named name: Name, source: Source) {
        let startDrain = pending.withLock { p -> Bool in
            p.items.append((name, source, image))
            if p.items.count > pendingWriteLimit {
                p.dropped += p.items.count - pendingWriteLimit
                p.items.removeFirst(p.items.count - pendingWriteLimit)
            }
            guard !p.draining else { return false }
            p.draining = true
            return true
        }
        if startDrain { writes.async { [self] in drain() } }
    }

    /// Tiles waiting to be written (tests, benchmark).
    var pendingWriteCount: Int { pending.withLock { $0.items.count } }
    /// Tiles dropped because too many waited (tests, benchmark).
    var droppedWriteCount: Int { pending.withLock { $0.dropped } }

    /// Runs on `writes` until nothing waits.
    private func drain() {
        while true {
            let next = pending.withLock { p -> (name: Name, source: Source, image: CGImage)? in
                guard !p.items.isEmpty else { p.draining = false; return nil }
                return p.items.removeFirst()
            }
            guard let next else { return }
            write(next.image, named: next.name, source: next.source)
        }
    }

    private func write(_ image: CGImage, named name: Name, source: Source) {
        let folder = folderURL(name.folder)
        // A new version of the PDF: its old tiles go first (spec 1.2.4 §3).
        let sourceURL = folder.appendingPathComponent(Self.sourceFileName)
        let stored = (try? String(contentsOf: sourceURL, encoding: .utf8)).flatMap(Source.init(text:))
        // A render that started before the file changed must not replace the newer version's tiles (review M7).
        if let stored, stored.path == source.path, source.isOlder(than: stored) {
            counterState.withLock { $0.staleDrops += 1 }
            return
        }
        if stored.map({ !$0.matches(source) }) ?? true {
            if stored != nil { counterState.withLock { $0.folderResets += 1 } }
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? source.text.write(to: sourceURL, atomically: true, encoding: .utf8)
        }
        let target = url(for: name)
        let temp = folder.appendingPathComponent(".\(name.file).\(UUID().uuidString)")
        guard Self.encode(image, to: temp, type: .heic) || Self.encode(image, to: temp, type: .png) else {
            Self.log.error("Cannot write tile \(name.file, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
            counterState.withLock { $0.failures += 1 }
            return
        }
        if rename(temp.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            counterState.withLock { $0.failures += 1 }
        } else {
            counterState.withLock { $0.written += 1 }
        }
        let due = writesSinceTrim.withLock { count -> Bool in
            count += 1
            if count >= Self.trimEvery { count = 0; return true }
            return false
        }
        if due { trim() }
    }

    static func encode(_ image: CGImage, to url: URL, type: UTType) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Total size of the stored tiles in bytes.
    public var byteCount: Int { entries().reduce(0) { $0 + $1.size } }

    /// Removes every stored tile. Tiles still waiting to be written are dropped first; the deleting runs
    /// on the write queue and is awaited without blocking a thread (review I1).
    public func removeAll() async {
        pending.withLock { $0.items.removeAll() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writes.async { [self] in
                let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for url in all { try? FileManager.default.removeItem(at: url) }
                try? FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
                continuation.resume()
            }
        }
    }

    /// Removes the tiles of PDFs under `folder` that are gone or changed (in the background). Called after the
    /// folder's index run, when the app reads that folder anyway. There is no form for all entries: asking the
    /// PDFs of every entry made macOS ask for access to Downloads in 1.3.0 (review of 1.3.1).
    public func pruneStale(under folder: URL) {
        writes.async { [self] in pruneStaleNow(under: folder) }
    }

    /// Removes the tiles of every PDF outside `sources` (the loaded and the remembered missing sources) without
    /// looking at those PDFs (in the background). Called once the sources are restored at launch; the tiles
    /// inside a source are checked by its index run (`pruneStale(under:)`), when the app reads that folder anyway.
    public func dropTiles(notUnder sources: [URL]) {
        writes.async { [self] in
            for (url, source) in sourceFolders() where !sources.contains(where: { Self.isPath(source.path, under: $0) }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Removes the tiles of every PDF under `folder` („Index löschen“; in the background).
    public func removeTiles(under folder: URL) {
        writes.async { [self] in
            for (url, source) in sourceFolders() where Self.isPath(source.path, under: folder) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Waits for pending writes and cleanups (tests).
    func flush() { writes.sync {} }

    /// Trims now (tests).
    func trimNow() { writes.sync { trim() } }

    /// Stops / restarts writing (tests: fill the waiting list).
    func suspendWritesForTesting() { writes.suspend() }
    func resumeWritesForTesting() { writes.resume() }

    // MARK: - On `writes`

    private func pruneStaleNow(under folder: URL) {
        for (url, source) in sourceFolders() {
            guard Self.isPath(source.path, under: folder) else { continue }
            if let current = Source.current(source.path) {
                if !current.matches(source) { try? FileManager.default.removeItem(at: url) }
            } else if FileManager.default.fileExists(atPath: (source.path as NSString).deletingLastPathComponent) {
                try? FileManager.default.removeItem(at: url)        // its folder is there, the PDF is not: deleted
            }
            // Folder not there either: an unmounted volume or share — keep the tiles (review I2).
        }
    }

    /// Folders without a readable `source` (an interrupted first write) cannot be checked: gone.
    private func removeUnreadableFolders() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: versionDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in folders where !FileManager.default.fileExists(atPath: url.appendingPathComponent(Self.sourceFileName).path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeOtherVersions() {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in all where url.lastPathComponent != versionDirectory.lastPathComponent {
            try? FileManager.default.removeItem(at: url)     // older formats and the flat layout of 1.2.3
        }
    }

    private func sourceFolders() -> [(URL, Source)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: versionDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url in
            guard let text = try? String(contentsOf: url.appendingPathComponent(Self.sourceFileName), encoding: .utf8),
                  let source = Source(text: text) else { return nil }
            return (url, source)
        }
    }

    static func isPath(_ path: String, under folder: URL) -> Bool {
        let root = folder.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: versionDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder -> [(url: URL, size: Int, date: Date)] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            return urls.compactMap { url in
                guard url.lastPathComponent != Self.sourceFileName, let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        }
    }

    /// Drops the least recently used tiles until 3/4 of the limit is left.
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
