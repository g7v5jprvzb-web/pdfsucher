import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// index-speed-1: phase 1 writes its batches in a separate writer (order kept, bounded, nothing lost on cancel) and
/// extracts the largest files first.
@Suite("Phase-1 writer")
struct IndexerWriterTests {
    final class Written: Sendable {
        private let batches = Mutex<[[Int]]>([])
        func withLock<T>(_ body: (inout [[Int]]) -> T) -> T { batches.withLock { body(&$0) } }
    }

    /// Records each batch after `delay`; fails batches containing `failOn`.
    func writer(_ written: Written, delay: TimeInterval = 0, failOn: Int? = nil, maxInFlight: Int = 2) -> BatchWriter<[Int]> {
        BatchWriter(maxInFlight: maxInFlight) { batch in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if let failOn, batch.contains(failOn) { throw CocoaError(.fileWriteUnknown) }
            written.withLock { $0.append(batch) }
            return delay * 1000
        }
    }

    @Test func batchesAreWrittenInOrder() async {
        let written = Written()
        let w = writer(written, delay: 0.005)
        for i in 0..<8 { try? await w.submit([i * 2, i * 2 + 1]) }
        #expect(await w.drain() == nil)
        #expect(written.withLock { $0 } == (0..<8).map { [$0 * 2, $0 * 2 + 1] })
    }

    @Test func atMostTwoBatchesAreInFlightAndSubmitWaits() async {
        let written = Written()
        let w = writer(written, delay: 0.03)
        let start = ContinuousClock.now
        for i in 0..<5 { try? await w.submit([i]) }
        let submitting = ContinuousClock.now - start
        #expect(w.peakInFlight == 2)
        #expect(w.waitMs > 0)
        // 5 batches of 30 ms with 2 in flight: the fifth submit could only start after the third finished.
        #expect(submitting >= .milliseconds(60))
        #expect(await w.drain() == nil)
        #expect(written.withLock { $0.count } == 5)
    }

    @Test func aFailedWriteStopsEveryLaterOne() async {
        let written = Written()
        let w = writer(written, delay: 0.01, failOn: 2, maxInFlight: 10)
        for i in 0..<5 { try? await w.submit([i]) }
        #expect(await w.drain() != nil)
        #expect(written.withLock { $0 } == [[0], [1]], "nothing after the failed batch is written")
    }

    @Test func emptyBatchesAreNotWritten() async {
        let written = Written()
        let w = writer(written)
        try? await w.submit([])
        #expect(await w.drain() == nil)
        #expect(written.withLock { $0.isEmpty })
    }

    @Test func largestFilesComeFirst() {
        func file(_ path: String, _ size: Int64) -> (file: ScannedFile, isNew: Bool) {
            (ScannedFile(relativePath: path, url: URL(fileURLWithPath: "/x/" + path), fileSize: size, modifiedAt: .distantPast), true)
        }
        var work = [file("a.pdf", 10), file("b.pdf", 300), file("d.pdf", 20), file("c.pdf", 20)]
        Indexer.sortForExtraction(&work)
        #expect(work.map(\.file.relativePath) == ["b.pdf", "c.pdf", "d.pdf", "a.pdf"])
    }

    /// Cancelling while batches are written still stores every file extracted until then (the writer is drained).
    @Test func cancelWhileWritingKeepsEveryFinishedFile() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<60 { try PDFFixtures.makePDF(at: root.appendingPathComponent(String(format: "d%02d.pdf", i)), pages: ["Text \(i)"]) }
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let indexer = Indexer(root: root, store: store, source: PacedSource(), batchSize: 3)
        let finished = Mutex(0)
        let run = Task {
            try await indexer.update { progress in
                finished.withLock { $0 = max($0, progress.done) }
            }
        }
        while finished.withLock({ $0 }) < 20 { try await Task.sleep(for: .milliseconds(2)) }
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let reported = finished.withLock { $0 }
        let stored = try store.documents().count
        #expect(reported < 60, "cancelled mid-run")
        #expect(stored >= reported, "every file reported finished is stored")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.documents().count == stored, "no write outlives the cancelled run")
        // The next run finds them unchanged.
        let next = try await Indexer(root: root, store: store, batchSize: 3).update { _ in }
        #expect(next.unchanged >= reported)
        #expect(next.added + next.unchanged == 60)
    }
}

/// A little time per file, so cancellation lands while batches are in flight.
private struct PacedSource: TextSource {
    func pages(of url: URL) throws -> [PageText] {
        Thread.sleep(forTimeInterval: 0.01)
        // Much text, so writing a batch (both FTS indexes) takes a while and is still running at the cancel.
        let text = (0..<20_000).map { "w\($0 &* 7919 % 100_003)" }.joined(separator: " ")
        return [PageText(pageIndex: 0, text: "Seite \(url.lastPathComponent) " + text)]
    }
}
