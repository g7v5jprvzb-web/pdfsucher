import CoreGraphics
import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// 1.4.0 P3: a gentle stop starts no further layout but keeps the ones in progress.
@Suite("Layout sanft anhalten")
struct GentleLayoutStopTests {
    final class SlowLayout: PageLayoutSource, Sendable {
        func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
            try await Task.sleep(for: .milliseconds(80))
            return LayoutResult(pages: [LaidOutPage(text: "Seite \(url.lastPathComponent)", words: [], size: CGSize(width: 10, height: 10))],
                                renderer: "slow", layoutVersion: 1)
        }
        func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("slow", 1) }
    }

    @Test func runningLayoutsFinishAndTheRestWaits() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<8 { try Data("x\(i)".utf8).write(to: root.appendingPathComponent("d\(i).docx")) }
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let stops = Mutex(0)
        let indexer = Indexer(root: root, store: store, layout: SlowLayout(), layoutConcurrency: 2, layoutDuringUpdate: false,
                              stopRequests: { stops.withLock { $0 } })
        _ = try await indexer.update { _ in }
        #expect(try store.pendingLayoutJobs().count == 8)
        await #expect(throws: CancellationError.self) {
            _ = try await indexer.layOutPending { progress in
                if progress.done == 1 { stops.withLock { $0 += 1 } }          // after the first file: stop gently
            }
        }
        let left = try store.pendingLayoutJobs().count
        #expect(left == 6, "the first file and the one still running are stored, nothing else started")
        #expect(try store.match("Seite", in: .words).count == 2)
        #expect(try await indexer.layOutPending { _ in }.laidOut == 6)
    }
}
