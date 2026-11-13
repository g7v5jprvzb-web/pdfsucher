// SearchHistory.swift — 1.2.2 §1: the last search terms, newest first
import Foundation
import Observation

/// Terms whose search „arrived“ (a pause with hits, Return, an arrow into the grid, a tile, a tick).
/// Trimmed, case-insensitively unique, at most `limit`; a typing prefix saved shortly before the full
/// term is replaced by it. Persisted in `UserDefaults`.
@MainActor @Observable public final class SearchHistory {
    public static let limitRange = 10...100
    public static let defaultLimit = 30
    /// A prefix saved at most this long before the longer term is replaced (1.5 s pause, then finishing the word).
    public static let prefixWindow: TimeInterval = 10

    enum Key {
        static let entries = "search.history"
        static let enabled = "search.historyEnabled"
        static let limit = "search.historyLimit"
    }

    public private(set) var entries: [String]

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if !isEnabled { clear() }
        }
    }

    public var limit: Int {
        didSet {
            let clamped = Self.clampLimit(limit)
            if clamped != limit { limit = clamped; return }
            defaults.set(limit, forKey: Key.limit)
            trim()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The last save; only a new term saved by the pause may be replaced as a typing prefix (review I1).
    @ObservationIgnored private var lastCommit: (term: String, at: Date, viaPause: Bool, wasNew: Bool)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        let limit = Self.clampLimit((defaults.object(forKey: Key.limit) as? Int) ?? Self.defaultLimit)
        self.limit = limit
        var cleaned: [String] = []
        for raw in defaults.stringArray(forKey: Key.entries) ?? [] {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !cleaned.contains(where: { Self.same($0, term) }) else { continue }
            cleaned.append(term)
        }
        entries = Array(cleaned.prefix(limit))
    }

    /// Saves `term` as the newest entry.
    /// - Parameter viaPause: saved by the pause after typing (may be a typing prefix), not by Return, a click,
    ///   a tick or the list.
    public func commit(_ term: String, now: Date = Date(), viaPause: Bool = false) {
        let term = Self.clean(term)
        guard isEnabled, !term.isEmpty else { return }
        // The newest entry again (arrow keys held, a refresh): nothing to do, the prefix window stays (review I2/M2).
        if entries.first == term { return }
        if let last = lastCommit, last.viaPause, last.wasNew, let first = entries.first, Self.same(first, last.term),
           now.timeIntervalSince(last.at) <= Self.prefixWindow,
           term.count > first.count, term.lowercased().hasPrefix(first.lowercased()) {
            entries.removeFirst()
        }
        let wasNew = !entries.contains { Self.same($0, term) }
        entries.removeAll { Self.same($0, term) }
        entries.insert(term, at: 0)
        lastCommit = (term, now, viaPause, wasNew)
        trim()
        save()
    }

    public func clear() {
        entries.removeAll()
        lastCommit = nil
        save()
    }

    private func trim() {
        if entries.count > limit { entries.removeLast(entries.count - limit); save() }
    }

    private func save() { defaults.set(entries, forKey: Key.entries) }

    /// The one trimming rule (review M4).
    public static func clean(_ term: String) -> String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: .caseInsensitive) == .orderedSame }

    static func clampLimit(_ value: Int) -> Int { min(max(value, limitRange.lowerBound), limitRange.upperBound) }
}
