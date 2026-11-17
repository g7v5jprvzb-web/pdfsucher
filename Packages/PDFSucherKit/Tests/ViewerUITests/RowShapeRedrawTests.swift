import AppKit
import Foundation
import IndexKit
import OutputKit
import SearchKit
import SwiftUI
import Testing
import TestSupport
@testable import ViewerUI

#if DEBUG
/// 1.4.1: a row stayed empty (no tiles, no hint) under a file name in the result list. The lazy grid had built the row
/// before its page shape was known (empty stand-in), the tile prefetcher then looked the shape up, and when the row came
/// into view its own lookup task found the shape known and returned without redrawing: the stand-in stayed.
@Suite("Row shape redraw")
@MainActor
struct RowShapeRedrawTests {
    @Test func rowBuiltBeforeThePrefetcherKnewTheShapeShowsItsTiles() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("p.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let hit = DocumentHit(url: url, relativePath: "p.pdf", modifiedAt: Date(), pageHits: [], totalMatches: 0,
                              relevance: 0, sourceRoot: url.deletingLastPathComponent(), pageCount: 1, kind: .pdf)
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.RowShape.\(UUID())")!))
        model.hits = [hit]
        let shapes = PageShapes(), cache = ThumbnailCache(scale: 1)
        var tileAppeared = false
        let host = NSHostingView(rootView: DocumentRow(
            hit: hit, baseTileSize: CGSize(width: 100, height: 141), shapes: shapes, model: model, cache: cache,
            folderUnreachable: false, highlightKey: "", highlightRanges: nil,
            onTileAppear: { _ in tileAppeared = true }, onFocusTile: { _ in }))
        _ = host.fittingSize                                   // built ahead, not shown yet: no lookup task runs
        await shapes.resolve(hit, revision: 0, cache: cache)   // the prefetcher knows the shape first

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host                               // the row comes into view
        window.orderFrontRegardless()
        for _ in 0..<100 where !tileAppeared {
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(20))
        }
        window.contentView = nil
        window.close()
        #expect(tileAppeared, "the row must show its tiles once the shape is known")
    }
}
#endif
