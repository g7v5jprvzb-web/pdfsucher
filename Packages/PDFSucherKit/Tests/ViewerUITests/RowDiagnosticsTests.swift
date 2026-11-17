import AppKit
import Foundation
import IndexKit
import OutputKit
import SearchKit
import SwiftUI
import Testing
import TestSupport
@testable import ViewerUI

/// 1.4.2: diagnosis log of the result rows (`ui-rows-<date>.jsonl`).
@Suite("Row diagnostics")
@MainActor
struct RowDiagnosticsTests {
    private func events(_ metrics: IndexMetrics) throws -> [[String: Any]] {
        metrics.flush()
        return try metrics.logFiles().flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
    }

    private func hit(_ url: URL) -> DocumentHit {
        DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: Date(), pageHits: [], totalMatches: 0,
                    relevance: 0, sourceRoot: url.deletingLastPathComponent(), pageCount: 1, kind: .pdf)
    }

    @Test func offWritesNothing() throws {
        let metrics = IndexMetrics(directory: try PDFFixtures.tempDirectory(), prefix: "ui-rows")
        let diagnostics = RowDiagnostics(metrics: metrics, stuckAfter: .zero)
        let url = URL(fileURLWithPath: "/x/Geheim.pdf")
        diagnostics.hitsChanged([hit(url)])
        diagnostics.built(url, placeholder: true)
        diagnostics.visible(url)
        #expect(diagnostics.checkStuck(now: .now + .seconds(5)).isEmpty)
        metrics.flush()
        #expect(metrics.logFiles().isEmpty)
    }

    @Test func watchdogReportsAVisibleRowStillWaiting() throws {
        let metrics = IndexMetrics(directory: try PDFFixtures.tempDirectory(), prefix: "ui-rows")
        metrics.setEnabled(true)
        let diagnostics = RowDiagnostics(metrics: metrics, stuckAfter: .seconds(2))
        let waiting = URL(fileURLWithPath: "/Bücher/Geheim.pdf"), fine = URL(fileURLWithPath: "/x/ok.pdf")
        diagnostics.hitsChanged([hit(fine), hit(waiting)])
        diagnostics.built(waiting, placeholder: true)       // the 1.4.1 empty row: built without shape, never redrawn
        diagnostics.built(fine, placeholder: false)
        diagnostics.visible(waiting)
        diagnostics.visible(fine)
        #expect(diagnostics.checkStuck(now: .now + .seconds(1)).isEmpty)          // not long enough yet
        #expect(diagnostics.checkStuck(now: .now + .seconds(3)) == [waiting])
        #expect(diagnostics.checkStuck(now: .now + .seconds(6)).isEmpty)          // once per showing

        let all = try events(metrics)
        let stuck = try #require(all.first { $0["event"] as? String == "row_stuck" })
        #expect(stuck["file"] as? String == IndexMetrics.hash(waiting) && stuck["ext"] as? String == "pdf")
        #expect(stuck["row"] as? Int == 1 && stuck["gen"] as? Int == 1)
        #expect(stuck["shape_stored"] as? Bool == false && stuck["lookup_pending"] as? Bool == false)
        #expect((stuck["visible_ms"] as? Double ?? 0) >= 2000)
        #expect(Set(all.compactMap { $0["event"] as? String }).isSuperset(of: ["hits", "row_built", "row_visible", "row_stuck"]))
        // Privacy: no file name or path.
        let text = try metrics.logFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!text.contains("Geheim") && !text.contains("Bücher") && !text.contains("ok.pdf"))
    }

#if DEBUG
    /// The flow of `RowShapeRedrawTests` with the log on: the row reports its stand-in, the prefetcher's lookup, the
    /// redraw with the shape already known, and no `row_stuck`.
    @Test func fixedFlowIsLoggedAndNeverStuck() async throws {
        let metrics = IndexMetrics(directory: try PDFFixtures.tempDirectory(), prefix: "ui-rows")
        metrics.setEnabled(true)
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("p.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let hit = hit(url)
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.RowDiag.\(UUID())")!))
        model.hits = [hit]
        let diagnostics = RowDiagnostics(metrics: metrics, stuckAfter: .milliseconds(300))
        let shapes = PageShapes(diagnostics: diagnostics), cache = ThumbnailCache(scale: 1)
        diagnostics.hitsChanged([hit])
        var tileAppeared = false
        let host = NSHostingView(rootView: DocumentRow(
            hit: hit, baseTileSize: CGSize(width: 100, height: 141), shapes: shapes, model: model, cache: cache,
            folderUnreachable: false, highlightKey: "", highlightRanges: nil,
            onTileAppear: { _ in tileAppeared = true }, onFocusTile: { _ in }))
        _ = host.fittingSize
        shapes.request(hit, revision: 0, cache: cache)                 // the prefetcher
        for _ in 0..<100 where !shapes.isResolved(url, revision: 0) { try await Task.sleep(for: .milliseconds(10)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<100 where !tileAppeared {
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tileAppeared)
        #expect(diagnostics.checkStuck(now: .now + .seconds(5)).isEmpty)
        window.contentView = nil
        window.close()

        let all = try events(metrics)
        func has(_ event: String, _ key: String, _ value: String) -> Bool {
            all.contains { $0["event"] as? String == event && "\($0[key] ?? "")" == value }
        }
        #expect(has("row_built", "placeholder", "1") || has("row_built", "placeholder", "true"))
        #expect(has("shape_request", "source", "prefetch") && has("shape_loaded", "source", "prefetch"))
        #expect(has("row_redraw", "reason", "shape_known_at_task"))
        #expect(!all.contains { $0["event"] as? String == "row_stuck" })
    }
#endif
}
