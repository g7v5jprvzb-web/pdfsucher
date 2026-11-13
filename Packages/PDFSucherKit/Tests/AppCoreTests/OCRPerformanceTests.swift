import AppKit
import Foundation
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.2 §9: search stays < 200 ms from the last keystroke with OCR text in the index, and the main
/// thread is never blocked while recognition runs. Opt-in:
/// `PDFSUCHER_E2E=1 scripts/test.sh -c release --filter searchAndResponsivenessWithOCR`.
@MainActor @Suite("OCR performance")
struct OCRPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_E2E"] == "1"), .timeLimit(.minutes(60)))
    func searchAndResponsivenessWithOCR() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("quelle", isDirectory: true)
        var rng = SeededGenerator(seed: 12)
        let words = PerfCorpus.wordList(using: &rng)
        for d in 0..<1_000 {
            let dir = root.appendingPathComponent(String(format: "text%02d", d / 50), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try PDFFixtures.makePDF(at: dir.appendingPathComponent(String(format: "dok%04d.pdf", d)),
                                    pages: (0..<20).map { _ in PerfCorpus.page(words, using: &rng) })
        }
        // 20 scan PDFs × 10 pages and 100 photos, each with a few corpus words plus a marker.
        let scans = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        func lines() -> [String] { (0..<6).map { _ in (0..<4).map { _ in words[Int.random(in: 0..<200, using: &rng)] }.joined(separator: " ") } }
        for s in 0..<20 {
            let images = try (0..<10).map { _ in try OCRFixtures.textImage(["Scanseite Prüfvermerk"] + lines(), size: CGSize(width: 1654, height: 2339), fontSize: 48).image }
            try OCRFixtures.makeScanPDF(at: scans.appendingPathComponent(String(format: "scan%02d.pdf", s)), images: images)
        }
        for f in 0..<100 {
            try OCRFixtures.write(try OCRFixtures.textImage(["Fotobeleg Quittung"] + lines(), size: CGSize(width: 2000, height: 1500), fontSize: 56).image,
                                  to: scans.appendingPathComponent(String(format: "foto%03d.jpg", f)), type: .jpeg)
        }

        let indexURL = base.appendingPathComponent("index.sqlite")
        let model = AppModel(settings: GridSettings(defaults: UserDefaults(suiteName: "OCRPerf-\(UUID().uuidString)")!),
                             defaults: UserDefaults(suiteName: "OCRPerf-\(UUID().uuidString)")!,
                             environment: PerfEnvironment(), debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL) })
        let clock = ContinuousClock()

        // Main-thread latency while phase 1 and phase 2 run: a 10 ms ticker on the main actor.
        let ticker = MainTicker()
        let ticking = Task { @MainActor in await ticker.run() }
        let start = clock.now
        await model.add([root])
        var phase2Start: ContinuousClock.Instant?
        while true {
            if case .recognizing = model.indexStatus, phase2Start == nil { phase2Start = clock.now; ticker.reset() }
            if model.indexStatus == .upToDate || { if case .problems = model.indexStatus { return true } else { return false } }() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await model.waitUntilIdle()
        ticking.cancel()
        let total = clock.now - start
        let ocrDuration = phase2Start.map { clock.now - $0 } ?? .zero
        let counts = await model.ocrCounts(for: root)

        let queries = ["scanseite", "fotobeleg", "prüfvermerk quittung", words[3].lowercased(), "\(words[5].lowercased().prefix(4))*", "*\(words[7].lowercased().suffix(4))", "ver*"]
        var rows: [String] = []
        var worstFirst: Duration = .zero
        for q in queries {
            var full: [Duration] = [], first: [Duration] = []
            let mark = FirstHits()
            model.onHitsPublished = { if !$0.isEmpty { mark.set() } }
            for _ in 0..<5 {
                model.queryText = ""
                await model.waitUntilIdle()
                let t0 = clock.now
                mark.reset(t0)
                model.queryText = q
                await model.waitForSearch()
                let d = clock.now - t0
                full.append(d)
                first.append(mark.elapsed ?? d)
            }
            full.sort(); first.sort()
            worstFirst = max(worstFirst, first[2])
            rows.append("| `\(q)` | \(model.hits.count) | \(model.hits.reduce(0) { $0 + $1.pageHits.count }) | \(ms(first[2] + .milliseconds(50))) | \(ms(full[2] + .milliseconds(50))) |")
        }
        print("""

        OCR-E2E: 1.000 Text-PDFs × 20 Seiten + 20 Scan-PDFs × 10 Seiten + 100 Fotos; Kerne \(ProcessInfo.processInfo.activeProcessorCount)
        Gesamt bis aktuell \(ms(total)), davon Texterkennung \(ms(ocrDuration)); erkannt: \(counts.map { "\($0.pages) Seiten, \($0.images) Bilder" } ?? "-")
        Hauptthread während der Erkennung: längste Verzögerung \(ms(ticker.worst)) (Ticker 10 ms, \(ticker.ticks) Ticks)
        | Eingabe | Dokumente | Seiten | erste Reihen (+50 ms) | vollständig (+50 ms) |
        |---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        """)
        #expect(counts?.pages == 200 && counts?.images == 100)
        #expect(ticker.worst < .milliseconds(100), "main thread blocked for \(ms(ticker.worst))")
        #expect(worstFirst + .milliseconds(50) < .milliseconds(200))
    }

    private func ms(_ d: Duration) -> String {
        String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
}

/// Records how late a 10 ms timer on the main actor fires.
@MainActor private final class MainTicker {
    private(set) var worst: Duration = .zero
    private(set) var ticks = 0
    func reset() { worst = .zero; ticks = 0 }
    func run() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let planned = clock.now + .milliseconds(10)
            try? await Task.sleep(until: planned, clock: clock)
            ticks += 1
            worst = max(worst, clock.now - planned)
        }
    }
}

private final class FirstHits: @unchecked Sendable {
    private let lock = NSLock()
    private var start = ContinuousClock.now
    private var first: ContinuousClock.Instant?
    func reset(_ s: ContinuousClock.Instant) { lock.withLock { start = s; first = nil } }
    func set() { lock.withLock { if first == nil { first = .now } } }
    var elapsed: Duration? { lock.withLock { first.map { $0 - start } } }
}

@MainActor private final class PerfEnvironment: AppEnvironment {
    func chooseSources() -> [URL] { [] }
    func chooseSaveLocation(defaultName: String) -> URL? { nil }
    func runPrint(_ operation: NSPrintOperation) {}
    func openInPreview(_ url: URL) {}
    func confirmDeleteIndex(question: String) -> Bool { false }
}
