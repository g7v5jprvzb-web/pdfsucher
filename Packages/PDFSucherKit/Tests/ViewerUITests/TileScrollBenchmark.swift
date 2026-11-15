import AppKit
import Foundation
import PDFKit
import Testing
import OutputKit
@testable import ViewerUI

/// Measures how long tiles take to appear while scrolling fast (Kachel-Cache, spec 1.2.3).
/// Opt-in, on real files: `PDFSUCHER_TILES=/a.pdf:/b.pdf swift test -c release --filter TileScrollBenchmark`.
/// Prints a table; asserts nothing (numbers depend on the files).
@Suite("TileScrollBenchmark", .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_TILES"] != nil), .serialized)
struct TileScrollBenchmark {
    static let size = CGSize(width: 200, height: 283)
    static let columns = 6, visibleRows = 3

    static var files: [URL] {
        (ProcessInfo.processInfo.environment["PDFSUCHER_TILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }

    /// Grid rows of `columns` pages, across all files (first 120 pages each).
    static func rows() -> [[PageRef]] {
        files.flatMap { url -> [[PageRef]] in
            let count = min(PDFDocument(url: url)?.pageCount ?? 0, 120)
            return stride(from: 0, to: count, by: columns).map { start in
                (start..<min(start + columns, count)).map { PageRef(url: url, pageIndex: $0) }
            }
        }
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
    static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
    static func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }

    @Test func singleRenderCost() async throws {
        let clock = ContinuousClock()
        for url in Self.files {
            let cache = ThumbnailCache()
            let count = min(PDFDocument(url: url)?.pageCount ?? 0, 40)
            var times: [Double] = []
            for page in 0..<count {
                let t = await clock.measure { _ = await cache.thumbnail(for: PageRef(url: url, pageIndex: page), size: Self.size) }
                times.append(Self.ms(t))
            }
            print(String(format: "RENDER %@: %d pages, first %.0f ms, median %.0f ms, p95 %.0f ms, max %.0f ms",
                         url.lastPathComponent, count, times.first ?? 0, Self.median(Array(times.dropFirst())),
                         Self.p95(times), times.max() ?? 0))
        }
    }

    /// The window moves one row every `stepMS`; tiles that leave are cancelled like `.task` does.
    /// Reports how long after scrolling stops the last visible tile is ready, and per-tile latency.
    @Test(arguments: [16, 50, 150])
    func fastScroll(stepMS: Int) async throws {
        try await scroll(stepMS: stepMS, cache: ThumbnailCache(), prefetch: false, label: "plain   ")
        try await scroll(stepMS: stepMS, cache: ThumbnailCache(), prefetch: true, label: "prefetch")
        let disk = TileDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID())"))
        try await scroll(stepMS: stepMS, cache: ThumbnailCache(disk: disk), prefetch: true, label: "disk 1st")
        disk.flush()
        try await scroll(stepMS: stepMS, cache: ThumbnailCache(disk: disk), prefetch: true, label: "disk 2nd")
        await disk.removeAll()
        try? FileManager.default.removeItem(at: disk.directory)        // no tiles-UUID folders left behind
    }

    func scroll(stepMS: Int, cache: ThumbnailCache, prefetch: Bool, label: String) async throws {
        let rows = Self.rows()
        guard rows.count > Self.visibleRows else { return }
        let clock = ContinuousClock()
        let start = clock.now
        var tasks: [PageRef: Task<Duration?, Never>] = [:]
        func show(_ ref: PageRef) {
            let appeared = clock.now
            tasks[ref] = Task {
                let image = await cache.thumbnail(for: ref, size: Self.size)
                return image == nil || Task.isCancelled ? nil : clock.now - appeared
            }
        }
        for ref in rows.prefix(Self.visibleRows).flatMap({ $0 }) { show(ref) }
        let steps = rows.count - Self.visibleRows
        for top in 1...steps {
            try await Task.sleep(for: .milliseconds(stepMS))
            for ref in rows[top - 1] { tasks.removeValue(forKey: ref)?.cancel() }
            for ref in rows[top + Self.visibleRows - 1] { show(ref) }
            if prefetch { cache.prefetch(rows.dropFirst(top + Self.visibleRows).prefix(2).flatMap { $0 }, size: Self.size) }
        }
        let stopped = clock.now
        var latencies: [Double] = []
        for task in tasks.values { if let d = await task.value { latencies.append(Self.ms(d)) } }
        let settled = clock.now
        print(String(format: "SCROLL %@ step %3d ms: %d rows in %.0f ms; after stop the last visible tile took %.0f ms; visible tiles: median %.0f ms, max %.0f ms",
                     label, stepMS, rows.count, Self.ms(stopped - start), Self.ms(settled - stopped),
                     Self.median(latencies), latencies.max() ?? 0))
    }

    /// Scanned pages: how many take the fast path, how close they look to PDFKit, and the time saved.
    @Test func scannedPagesMatchPDFKit() throws {
        let size = CGSize(width: 400, height: 566)
        for url in Self.files {
            guard let doc = PDFDocument(url: url) else { continue }
            var fast = 0, worst = 0.0, fastMS = 0.0, slowMS = 0.0
            let count = min(doc.pageCount, 20)
            for i in 0..<count {
                guard let page = doc.page(at: i), let cg = page.pageRef, ScannedPage.plan(cg) != nil else { continue }
                fast += 1
                var t = Date()
                let a = ScannedPageTests.draw(page, size: size, fast: true)
                fastMS += Date().timeIntervalSince(t) * 1000
                t = Date()
                let b = ScannedPageTests.draw(page, size: size, fast: false)
                slowMS += Date().timeIntervalSince(t) * 1000
                if let a, let b { worst = max(worst, ScannedPageTests.meanDifference(a, b)) }
            }
            print(String(format: "SCAN %@: %d of %d pages fast path, worst mean difference %.1f/255, %.0f ms vs PDFKit %.0f ms per page",
                         url.lastPathComponent, fast, count, worst, fast > 0 ? fastMS / Double(fast) : 0, fast > 0 ? slowMS / Double(fast) : 0))
        }
    }
}
