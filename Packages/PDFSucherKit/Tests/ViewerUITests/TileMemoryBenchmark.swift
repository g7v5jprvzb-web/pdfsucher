import AppKit
import Darwin
import Foundation
import OutputKit
import PDFKit
import Testing
import TestSupport
@testable import ViewerUI

/// Memory and responsiveness of tiles while scrolling fast through scanned PDFs (spec 1.2.4 §6).
/// Opt-in, synthetic corpus: `PDFSUCHER_TILEMEM=1 scripts/test.sh -c release --filter TileMemoryBenchmark`.
/// Uses only API that 1.2.3 already had, so the same file measures before and after. Prints; asserts nothing.
@Suite("TileMemoryBenchmark", .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_TILEMEM"] == "1"), .serialized)
struct TileMemoryBenchmark {
    static let size = CGSize(width: 200, height: 283)
    static let columns = 6, visibleRows = 3

    @Test(.timeLimit(.minutes(20))) func fastScrollMemory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tilemem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // 12 scan PDFs × 30 A4 pages at 150 dpi (one image per page, like a scanner).
        let images = try (0..<6).map { i in
            try OCRFixtures.textImage((0..<30).map { "Zeile \($0) Seite \(i) Vertrag Kündigung Miete" },
                                      size: CGSize(width: 1240, height: 1754), fontSize: 30).image
        }
        var files: [URL] = []
        for f in 0..<12 {
            let url = base.appendingPathComponent(String(format: "scan%02d.pdf", f))
            try OCRFixtures.makeScanPDF(at: url, images: (0..<30).map { images[($0 + f) % images.count] })
            files.append(url)
        }
        let rows: [[PageRef]] = files.flatMap { url in
            stride(from: 0, to: 30, by: Self.columns).map { start in (start..<min(start + Self.columns, 30)).map { PageRef(url: url, pageIndex: $0) } }
        }
        let disk = TileDiskCache(directory: base.appendingPathComponent("tiles", isDirectory: true))
        let cache = ThumbnailCache(disk: disk)
        let peak = PeakFootprint()
        let sampler = Task.detached { while !Task.isCancelled { peak.sample(); try? await Task.sleep(for: .milliseconds(10)) } }
        let startedBefore = TileRenderQueue.shared.startedCountForBenchmark
        let clock = ContinuousClock()
        let footprintStart = PeakFootprint.current()

        // Scroll one row every 16 ms; the view's 1.2.3 call pattern: each appearing tile prefetches the
        // tiles to its right, each appearing row the first tiles of the next two rows.
        var visibleTasks: [Task<Void, Never>] = []
        for r in 0..<(rows.count - Self.visibleRows) {
            visibleTasks.forEach { $0.cancel() }
            visibleTasks = rows[r..<(r + Self.visibleRows)].flatMap { $0 }.map { ref in
                Task { _ = await cache.thumbnail(for: ref, size: Self.size) }
            }
            let appearing = rows[r + Self.visibleRows - 1]
            for (i, _) in appearing.enumerated() {
                cache.prefetch(Array(appearing.dropFirst(i + 1)), size: Self.size)
            }
            for next in rows.dropFirst(r + Self.visibleRows).prefix(2) { cache.prefetch(next, size: Self.size) }
            try await Task.sleep(for: .milliseconds(16))
        }
        let stop = clock.now
        for task in visibleTasks { await task.value }
        let lastVisible = clock.now - stop
        let flushStart = clock.now
        disk.flush()
        let backlog = clock.now - flushStart
        sampler.cancel()
        let started = TileRenderQueue.shared.startedCountForBenchmark - startedBefore
        print("""

        TILEMEM: 12 Scan-PDFs × 30 Seiten, \(rows.count) Reihen à \(Self.columns), 1 Reihe / 16 ms, Kachel 200×283 pt Retina
        TILEMEM: Speicher (phys_footprint) Start \(footprintStart) MB, Spitze \(peak.peakMB) MB
        TILEMEM: gerenderte Kacheln \(started), letzte sichtbare Kachel nach dem Anhalten \(Self.ms(lastVisible)) ms
        TILEMEM: Platten-Rückstand nach dem Anhalten \(Self.ms(backlog)) ms

        """)
    }

    static func ms(_ d: Duration) -> Int { Int(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
}

final class PeakFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    var peakMB: Int { lock.withLock { peak } }
    func sample() { let now = Self.current(); lock.withLock { peak = max(peak, now) } }

    static func current() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

extension TileRenderQueue {
    /// Jobs started so far (benchmark).
    var startedCountForBenchmark: Int { startedCount }
}
