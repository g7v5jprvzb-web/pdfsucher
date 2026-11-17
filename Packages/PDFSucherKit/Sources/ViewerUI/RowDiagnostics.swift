// RowDiagnostics.swift — 1.4.2: diagnosis log of the result rows (empty rows in 1.4.1)
import Foundation
import IndexKit
import SearchKit
import os

/// Records how result rows get their page shape and tiles, to find rows that stay empty (1.4.1: a row built before its
/// shape was known kept its empty stand-in). Off by default; switched with `IndexMetrics.rows` (Settings → Speicher →
/// „Diagnose-Protokoll für Ergebniszeilen“, defaults `rowDiagnosticsEnabled`).
///
/// Writes `~/Library/Logs/PDFSucher/ui-rows-<date>.jsonl` and the same events to the unified log (subsystem
/// `local.pdfsucher`, category `Rows`). Privacy as in the indexing log: a file appears only as `file` (hash of the path)
/// and `ext`, never with its name, path or text.
///
/// Events: `hits` (a new result list: `gen`, `count`), `row_built` (first build in a result list, or the stand-in
/// state changed: `placeholder`), `shape_request` (`source` row/prefetch, `joined` when a lookup was already running),
/// `shape_loaded` (`ms`, `source`, `found`), `row_redraw` (`reason`), `row_visible`, `row_hidden`, and `row_stuck`: a
/// visible row still showing the stand-in after `stuckAfter` (with `shape_stored`, `lookup_pending`, `builds`,
/// `visible_ms`, `last_redraw_ms`, `last_redraw`). The watchdog runs only while the log is on and rows are visible.
/// Off: every call returns after one atomic load.
@MainActor final class RowDiagnostics {
    enum Source: String { case row, prefetch }

    private struct Row {
        var placeholder = false
        var builds = 0
        var builtInGeneration = -1
        var visibleSince: ContinuousClock.Instant?
        var lastRedraw: (at: ContinuousClock.Instant, reason: String)?
        var stuckReported = false
    }

    let metrics: IndexMetrics
    let stuckAfter: Duration
    /// The shapes this log describes (`PageShapes` owns it): shape stored / lookup pending for `row_stuck`.
    weak var shapes: PageShapes?
    private static let logger = Logger(subsystem: "local.pdfsucher", category: "Rows")
    private var rows: [URL: Row] = [:]
    private var index: [URL: Int] = [:]
    private var generation = 0
    private var watchdog: Task<Void, Never>?

    init(metrics: IndexMetrics = .rows, stuckAfter: Duration = .seconds(2)) {
        self.metrics = metrics
        self.stuckAfter = stuckAfter
    }

    var isEnabled: Bool { metrics.isEnabled }

    /// A new result list (search, early rows, filter): numbers it and notes each row's position.
    func hitsChanged(_ hits: [DocumentHit]) {
        guard isEnabled else { return }
        generation += 1
        index = Dictionary(hits.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { a, _ in a })
        log("hits", ["count": hits.count])
    }

    /// The row's body was built; `placeholder` = it shows the empty stand-in (shape not known yet).
    func built(_ url: URL, placeholder: Bool) {
        guard isEnabled else { return }
        var row = rows[url] ?? Row()
        row.builds += 1
        let changed = row.builtInGeneration != generation || row.placeholder != placeholder
        row.placeholder = placeholder
        row.builtInGeneration = generation
        rows[url] = row
        if changed { log("row_built", fields(url, ["placeholder": placeholder, "builds": row.builds])) }
    }

    func shapeRequested(_ url: URL, source: Source, joined: Bool) {
        guard isEnabled else { return }
        log("shape_request", fields(url, ["source": source.rawValue, "joined": joined]))
    }

    func shapeLoaded(_ url: URL, source: Source, ms: Double, found: Bool) {
        guard isEnabled else { return }
        log("shape_loaded", fields(url, ["source": source.rawValue, "ms": ms, "found": found]))
    }

    /// The row asked SwiftUI to draw it again (`reason`: why).
    func redraw(_ url: URL, reason: String) {
        guard isEnabled else { return }
        rows[url, default: Row()].lastRedraw = (ContinuousClock.now, reason)
        log("row_redraw", fields(url, ["reason": reason]))
    }

    func visible(_ url: URL) {
        guard isEnabled else { return }
        var row = rows[url] ?? Row()
        row.visibleSince = ContinuousClock.now
        row.stuckReported = false
        rows[url] = row
        log("row_visible", fields(url, ["placeholder": row.placeholder]))
        startWatchdog()
    }

    func hidden(_ url: URL) {
        guard isEnabled else { return }
        rows[url, default: Row()].visibleSince = nil
        log("row_hidden", fields(url, [:]))
    }

    /// Reports each visible row that still shows the stand-in `stuckAfter` after it came into view (once per showing).
    /// Returns the rows reported (tests).
    @discardableResult
    func checkStuck(now: ContinuousClock.Instant = .now) -> [URL] {
        guard isEnabled else { return [] }
        var reported: [URL] = []
        for (url, row) in rows {
            guard let since = row.visibleSince, row.placeholder, !row.stuckReported, now - since >= stuckAfter else { continue }
            rows[url]?.stuckReported = true
            reported.append(url)
            var extra: [String: Any] = ["builds": row.builds, "visible_ms": IndexMetrics.ms(now - since),
                                        "shape_stored": shapes?.hasEntry(url) ?? false,
                                        "lookup_pending": shapes?.isPending(url) ?? false]
            if let redraw = row.lastRedraw {
                extra["last_redraw_ms"] = IndexMetrics.ms(now - redraw.at)
                extra["last_redraw"] = redraw.reason
            }
            log("row_stuck", fields(url, extra), level: .error)
        }
        return reported
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isEnabled, self.rows.values.contains(where: { $0.visibleSince != nil }) else { break }
                self.checkStuck()
            }
            self?.watchdog = nil
        }
    }

    private func fields(_ url: URL, _ extra: [String: Any]) -> [String: Any] {
        var fields = extra
        fields["file"] = IndexMetrics.hash(url)
        fields["ext"] = url.pathExtension.lowercased()
        if let row = index[url] { fields["row"] = row }
        return fields
    }

    private func log(_ event: String, _ fields: [String: Any], level: OSLogType = .info) {
        var fields = fields
        fields["gen"] = generation
        metrics.log(event, fields)
        let text = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Self.logger.log(level: level, "\(event, privacy: .public) \(text, privacy: .public)")
    }
}
