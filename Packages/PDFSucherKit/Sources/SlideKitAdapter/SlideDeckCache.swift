// SlideDeckCache.swift — SlideKit adapter for the Office integration: opened decks shared by pages and tiles.
import Dispatch
import Foundation
import Synchronization
import SlideKit

/// Opened `SlideDeck`s for the viewer, tiles and output, at most `capacity` decks and at most `maxBytes` of decoded
/// images over all of them, least recently used dropped first; the deck just asked for always stays (also alone above
/// `maxBytes`). A deck is kept per file version (the resolved, standardized path with the file's size and
/// modification date, as the `Indexer` compares them) and per `FontSubstitution`: a changed file or another setting
/// opens a new deck, so stale layouts, text or images are never served.
///
/// Memory: a deck keeps its parsed slides, laid-out text and decoded images (SlideKit's image cache allows up to
/// `ImageDecoder.maxCacheBytes` per deck). Decks grow while they are drawn, so the bound is checked at every request
/// (`SlideDeck.cachedImageBytes`; text and slide models are small beside the images and not counted). Dropping a deck
/// frees it only once no `SlidePDFPage` (viewer, preview, merge) holds it any more.
///
/// Errors: a file that cannot be read (gone, no permission, I/O) throws the file system's error and is not
/// remembered, so the next request tries again. A file that reads but is no presentation (`SlideKitError`) is
/// remembered apart from the decks (at most `failureCapacity` versions), so tiles of a damaged deck do not reopen it
/// for every request and damaged files never push real decks out.
///
/// One open per deck (office-speed): the first request that misses opens the deck outside the lock; requests for the
/// same key meanwhile wait for it and get its deck or its error (six tile workers used to open and parse one deck six
/// times). Safe from any thread; a waiter blocks its thread for the 20–150 ms an open takes.
public final class SlideDeckCache: Sendable {
    /// Shared by the `SlideKitPages` of the app unless they get their own.
    /// office-speed: 10 decks and 400 MB of decoded images (1.3.2 kept two decks: one drawn at preview size holds up
    /// to ~375 MB, docs/performance.md „1.3.2“; a raster of 7 decks reopened them for every tile, „office-speed“).
    public static let shared = SlideDeckCache(capacity: 10, maxBytes: 400 * 1024 * 1024)

    struct Key: Hashable {
        let path: String
        let fileSize: Int64
        let modifiedAt: Date
        let fontSubstitution: FontSubstitution
        /// Office's fonts were registered when the deck was opened (`SlideDeck.officeFontsReady`); a deck opened
        /// before draws with substitutes without waiting and is not used once they are there (office-speed).
        let fontsReady: Bool
    }

    private struct Entry {
        let deck: SlideDeck
        var lastUse: UInt64
    }

    /// An open in progress: its result, set once, then `done` is left.
    private final class Opening: Sendable {
        let done = DispatchGroup()
        let result = Mutex<Result<SlideDeck, any Error>?>(nil)
        init() { done.enter() }

        func finish(_ result: Result<SlideDeck, any Error>) {
            self.result.withLock { $0 = result }
            done.leave()
        }

        func wait() throws -> SlideDeck {
            done.wait()
            return try result.withLock { $0! }.get()
        }
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var opening: [Key: Opening] = [:]
        var failures: [Key: SlideKitError] = [:]
        var tick: UInt64 = 0
        var opens = 0
    }

    let capacity: Int
    let maxBytes: Int
    private let failureCapacity: Int
    private let state = Mutex(State())

    /// `capacity` > 0: decks kept at once. `maxBytes`: decoded image bytes kept over all decks. `failureCapacity` > 0:
    /// unreadable file versions remembered.
    public init(capacity: Int = 4, maxBytes: Int = .max, failureCapacity: Int = 64) {
        precondition(capacity > 0 && failureCapacity > 0, "SlideDeckCache: capacities must be positive")
        self.capacity = capacity
        self.maxBytes = maxBytes
        self.failureCapacity = failureCapacity
    }

    private enum Lookup {
        case hit(SlideDeck)
        case failed(SlideKitError)
        case wait(Opening)
        case open(Opening)
    }

    /// The deck of `url` opened with `fontSubstitution`. Throws `SlideKitError` for a file that is no readable
    /// presentation, or the file system's error when the file cannot be read.
    public func deck(for url: URL, fontSubstitution: FontSubstitution) throws -> SlideDeck {
        let key = try Self.key(for: url, fontSubstitution: fontSubstitution)
        let lookup = state.withLock { state -> Lookup in
            if let failure = state.failures[key] { return .failed(failure) }
            if state.entries[key] != nil {
                state.tick += 1
                state.entries[key]!.lastUse = state.tick
                trim(&state, keeping: key)
                return .hit(state.entries[key]!.deck)
            }
            if let opening = state.opening[key] { return .wait(opening) }
            let opening = Opening()
            state.opening[key] = opening
            state.opens += 1
            return .open(opening)
        }
        let opening: Opening
        switch lookup {
        case .hit(let deck): return deck
        case .failed(let error): throw error
        case .wait(let other): return try other.wait()
        case .open(let mine): opening = mine
        }
        let opened: SlideDeck
        do {
            opened = try Self.open(url, fontSubstitution: fontSubstitution, waitsForFonts: key.fontsReady)
        } catch {
            state.withLock { state in
                state.opening[key] = nil
                if let error = error as? SlideKitError {
                    if state.failures.count >= failureCapacity { state.failures.removeAll() }
                    state.failures[key] = error
                }
            }
            opening.finish(.failure(error))
            throw error
        }
        state.withLock { state in
            state.opening[key] = nil
            state.tick += 1
            state.entries[key] = Entry(deck: opened, lastUse: state.tick)
            trim(&state, keeping: key)
        }
        opening.finish(.success(opened))
        return opened
    }

    /// The deck of this file version and setting if it is open now, else nil; opens nothing and changes no order
    /// (the index layout borrows the viewer's decks without pushing them out).
    public func openDeck(for url: URL, fontSubstitution: FontSubstitution) -> SlideDeck? {
        guard let key = try? Self.key(for: url, fontSubstitution: fontSubstitution) else { return nil }
        return state.withLock { $0.entries[key]?.deck }
    }

    /// Drops the least recently used decks (never `kept`) while more than `capacity` or more than `maxBytes` remain.
    private func trim(_ state: inout State, keeping kept: Key) {
        var bytes = maxBytes == .max ? 0 : state.entries.values.reduce(0) { $0 + $1.deck.cachedImageBytes }
        while state.entries.count > 1, state.entries.count > capacity || bytes > maxBytes,
              let oldest = state.entries.filter({ $0.key != kept }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            if maxBytes != .max { bytes -= oldest.value.deck.cachedImageBytes }
            state.entries.removeValue(forKey: oldest.key)
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
    /// Decks opened so far (tests: one open per deck).
    var opens: Int { state.withLock { $0.opens } }
    /// Decoded image bytes of the kept decks now (tests).
    var totalImageBytes: Int { state.withLock { $0.entries.values.reduce(0) { $0 + $1.deck.cachedImageBytes } } }

    /// Opens `url` (as given; the system follows a symbolic link, the name keeps its extension). Reads one byte
    /// first, so a file that cannot be read throws its file system error, not `SlideKitError.malformed`.
    static func open(_ url: URL, fontSubstitution: FontSubstitution, waitsForFonts: Bool = true) throws -> SlideDeck {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
        return try SlideDeck(url: url, fontSubstitution: fontSubstitution, waitsForFonts: waitsForFonts)
    }

    static func key(for url: URL, fontSubstitution: FontSubstitution) throws -> Key {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Key(path: resolved.path, fileSize: Int64(values.fileSize ?? 0),
                   modifiedAt: values.contentModificationDate ?? .distantPast, fontSubstitution: fontSubstitution,
                   fontsReady: SlideDeck.officeFontsReady)
    }
}
