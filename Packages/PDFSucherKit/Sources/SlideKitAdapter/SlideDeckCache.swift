// SlideDeckCache.swift — SlideKit adapter for the Office integration: opened decks shared by pages and tiles.
import Foundation
import Synchronization
import SlideKit

/// Opened `SlideDeck`s for the viewer, tiles and output, at most `capacity`, least recently used dropped first.
/// A deck is kept per file version (the resolved, standardized path with the file's size and modification date,
/// as the `Indexer` compares them) and per `FontSubstitution`: a changed file or another setting opens a new deck,
/// so stale layouts, text or images are never served.
///
/// Memory: a deck keeps its parsed slides, laid-out text and decoded images (SlideKit's image cache allows up to
/// `ImageDecoder.maxCacheBytes` per deck), so `capacity` is small. Dropping a deck frees it only once no
/// `SlidePDFPage` (viewer, preview, merge) holds it any more.
///
/// Errors: a file that cannot be read (gone, no permission, I/O) throws the file system's error and is not
/// remembered, so the next request tries again. A file that reads but is no presentation (`SlideKitError`) is
/// remembered apart from the decks (at most `failureCapacity` versions), so tiles of a damaged deck do not reopen it
/// for every request and damaged files never push real decks out.
///
/// Opening happens outside the lock; when two threads open the same new deck at once, the first stored one wins
/// and both get it. Safe from any thread.
public final class SlideDeckCache: Sendable {
    /// Shared by the `SlideKitPages` of the app unless they get their own.
    /// Two decks (1.3.2): drawn at tile/preview size a deck keeps up to ~375 MB of decoded images (synthetic deck,
    /// docs/performance.md „1.3.2“); four decks reached 1.5 GB. Reopening a deck costs 20–130 ms.
    public static let shared = SlideDeckCache(capacity: 2)

    struct Key: Hashable {
        let path: String
        let fileSize: Int64
        let modifiedAt: Date
        let fontSubstitution: FontSubstitution
    }

    private struct Entry {
        let deck: SlideDeck
        var lastUse: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var failures: [Key: SlideKitError] = [:]
        var tick: UInt64 = 0
    }

    let capacity: Int
    private let failureCapacity: Int
    private let state = Mutex(State())

    /// `capacity` > 0: decks kept at once. `failureCapacity` > 0: unreadable file versions remembered.
    public init(capacity: Int = 4, failureCapacity: Int = 64) {
        precondition(capacity > 0 && failureCapacity > 0, "SlideDeckCache: capacities must be positive")
        self.capacity = capacity
        self.failureCapacity = failureCapacity
    }

    /// The deck of `url` opened with `fontSubstitution`. Throws `SlideKitError` for a file that is no readable
    /// presentation, or the file system's error when the file cannot be read.
    public func deck(for url: URL, fontSubstitution: FontSubstitution) throws -> SlideDeck {
        let key = try Self.key(for: url, fontSubstitution: fontSubstitution)
        let hit = state.withLock { state -> Result<SlideDeck, SlideKitError>? in
            if let failure = state.failures[key] { return .failure(failure) }
            guard state.entries[key] != nil else { return nil }
            state.tick += 1
            state.entries[key]!.lastUse = state.tick
            return .success(state.entries[key]!.deck)
        }
        if let hit { return try hit.get() }
        let opened: SlideDeck
        do {
            opened = try Self.open(url, fontSubstitution: fontSubstitution)
        } catch let error as SlideKitError {
            state.withLock { state in
                if state.failures.count >= failureCapacity { state.failures.removeAll() }
                state.failures[key] = error
            }
            throw error
        }
        return state.withLock { state in
            state.tick += 1
            if let stored = state.entries[key] {
                state.entries[key]!.lastUse = state.tick
                return stored.deck
            }
            if state.entries.count >= capacity,
               let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                state.entries.removeValue(forKey: oldest)
            }
            state.entries[key] = Entry(deck: opened, lastUse: state.tick)
            return opened
        }
    }

    /// Drops every deck and remembered failure (e.g. after the font setting changed, to free memory at once).
    public func removeAll() {
        state.withLock { $0.entries.removeAll(); $0.failures.removeAll() }
    }

    var count: Int { state.withLock { $0.entries.count } }
    /// Whether the deck of this file version and setting is kept (tests; no file is opened).
    func contains(_ url: URL, fontSubstitution: FontSubstitution) -> Bool {
        guard let key = try? Self.key(for: url, fontSubstitution: fontSubstitution) else { return false }
        return state.withLock { $0.entries[key] != nil }
    }
    var failureCount: Int { state.withLock { $0.failures.count } }

    /// Opens `url` (as given; the system follows a symbolic link, the name keeps its extension). Reads one byte
    /// first, so a file that cannot be read throws its file system error, not `SlideKitError.malformed`.
    static func open(_ url: URL, fontSubstitution: FontSubstitution) throws -> SlideDeck {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
        return try SlideDeck(url: url, fontSubstitution: fontSubstitution)
    }

    static func key(for url: URL, fontSubstitution: FontSubstitution) throws -> Key {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Key(path: resolved.path, fileSize: Int64(values.fileSize ?? 0),
                   modifiedAt: values.contentModificationDate ?? .distantPast, fontSubstitution: fontSubstitution)
    }
}
