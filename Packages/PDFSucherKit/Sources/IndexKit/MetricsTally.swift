// MetricsTally.swift — summed measurements for the measurement log (1.5.0)
import Foundation
import Synchronization

/// Frequent measurements (tile draws, waits at the TextKit lock) summed per event and key and written to the measurement
/// log every `every` (default 5 s) as one line per key: the key fields, `count`, and per value `<name>_sum_ms` and
/// `<name>_max_ms`. Off (log off): one atomic load per `add`.
public final class MetricsTally: Sendable {
    public static let shared = MetricsTally(metrics: .shared)

    private struct Sum {
        var count = 0
        var sums: [String: Double] = [:]
        var maxima: [String: Double] = [:]
        var tags: [String: Int] = [:]
    }
    private struct State {
        var sums: [String: (event: String, key: [String: String], sum: Sum)] = [:]
        var scheduled = false
    }

    private let metrics: IndexMetrics
    private let every: Duration
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "local.pdfsucher.metrics-tally", qos: .utility)

    public init(metrics: IndexMetrics, every: Duration = .seconds(5)) {
        self.metrics = metrics
        self.every = every
    }

    /// Adds one measurement: `values` in ms; `tag` (e.g. the cache that answered) is counted as `<tag>` in `tags`.
    public func add(_ event: String, key: [String: String], ms values: [String: Double], tag: String? = nil) {
        guard metrics.isEnabled else { return }
        let id = event + "|" + key.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let schedule = state.withLock { s -> Bool in
            var entry = s.sums[id] ?? (event, key, Sum())
            entry.sum.count += 1
            for (name, value) in values {
                entry.sum.sums[name, default: 0] += value
                entry.sum.maxima[name] = max(entry.sum.maxima[name] ?? 0, value)
            }
            if let tag { entry.sum.tags[tag, default: 0] += 1 }
            s.sums[id] = entry
            if s.scheduled { return false }
            s.scheduled = true
            return true
        }
        if schedule {
            let (seconds, atto) = every.components
            queue.asyncAfter(deadline: .now() + Double(seconds) + Double(atto) / 1e18) { [self] in flush() }
        }
    }

    /// Writes the sums so far (tests; otherwise every `every`).
    public func flush() {
        let sums = state.withLock { s in
            defer { s.sums = [:]; s.scheduled = false }
            return s.sums.values
        }
        for (event, key, sum) in sums {
            var fields: [String: Any] = key
            fields["count"] = sum.count
            for (name, value) in sum.sums { fields["\(name)_sum_ms"] = (value * 10).rounded() / 10 }
            for (name, value) in sum.maxima { fields["\(name)_max_ms"] = (value * 10).rounded() / 10 }
            if !sum.tags.isEmpty { fields["tags"] = sum.tags }
            metrics.log(event, fields)
        }
    }
}
