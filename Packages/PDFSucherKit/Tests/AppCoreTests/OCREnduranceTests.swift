import AppKit
import Darwin
import Foundation
import IndexKit
import OfficeKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Endurance run (coordinator's night brief, spec 1.2 §3/§4/§9): a folder with 200 scan pages and 200 photos
/// is indexed and recognized with real Vision; recognition is stopped half-way, the app „restarts“ (new
/// AppModel and new FolderIndex on the same index file), recognition finishes, and a second restart
/// recognizes nothing again. Opt-in:
/// `PDFSUCHER_E2E=1 scripts/test.sh -c release --filter ocrEnduranceStopRestart`.
@MainActor @Suite("OCR endurance")
struct OCREnduranceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_E2E"] == "1"), .timeLimit(.minutes(60)))
    func ocrEnduranceStopRestart() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("quelle", isDirectory: true)
        let scans = root.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        for d in 0..<50 {
            try PDFFixtures.makePDF(at: root.appendingPathComponent(String(format: "text%02d.pdf", d)),
                                    pages: (0..<5).map { "Vertrag Nummer \(d) Seite \($0) mit Kündigungsfrist" })
        }
        for s in 0..<20 {
            let images = try (0..<10).map { p in
                try OCRFixtures.textImage(["Scanseite Prüfvermerk", "Akte \(s) Blatt \(p)"], size: CGSize(width: 1654, height: 2339), fontSize: 48).image
            }
            try OCRFixtures.makeScanPDF(at: scans.appendingPathComponent(String(format: "scan%02d.pdf", s)), images: images)
        }
        for f in 0..<200 {
            try OCRFixtures.write(try OCRFixtures.textImage(["Fotobeleg Quittung", "Beleg \(f)"], size: CGSize(width: 2000, height: 1500), fontSize: 56).image,
                                  to: scans.appendingPathComponent(String(format: "foto%03d.jpg", f)), type: .jpeg)
        }
        let indexURL = base.appendingPathComponent("index.sqlite")
        let defaults = UserDefaults(suiteName: "OCREndurance-\(UUID().uuidString)")!
        let clock = ContinuousClock()
        let footprintStart = Self.footprintMB()
        var log: [String] = []

        // Start 1: add the folder, stop recognition once ~25 % are done.
        var model: AppModel? = Self.makeModel(defaults: defaults, indexURL: indexURL)
        let t0 = clock.now
        await model!.add([root])
        var counts = (pages: 0, images: 0)
        while counts.pages + counts.images < 100 {
            try await Task.sleep(for: .milliseconds(200))
            counts = await model!.ocrCounts(for: root) ?? (0, 0)
            #expect(clock.now - t0 < .seconds(600), "recognition makes progress")
        }
        model!.stopRecognition()
        await model!.waitUntilIdle()
        let stopped = await model!.ocrCounts(for: root) ?? (0, 0)
        try await Task.sleep(for: .seconds(3))
        let later = await model!.ocrCounts(for: root) ?? (0, 0)
        #expect(later == stopped, "nothing restarts after ✕")
        #expect(stopped.pages + stopped.images < 400)
        log.append("Start 1: angehalten nach \(Self.ms(clock.now - t0)) bei \(stopped.pages) Seiten / \(stopped.images) Bildern")
        // Finished pages stay searchable.
        model!.queryText = "fotobeleg"
        await model!.waitForSearch()
        let partialPhotos = model!.hits.count
        model!.queryText = "scanseite"
        await model!.waitForSearch()
        let partialScanPages = model!.hits.reduce(0) { $0 + $1.pageHits.count }
        #expect(partialPhotos == stopped.images && partialScanPages == stopped.pages,
                "found \(partialPhotos) photos / \(partialScanPages) scan pages, recognized \(stopped)")

        // Start 2 („App beendet und neu gestartet“): recognition resumes where it stopped and finishes.
        model = nil
        model = Self.makeModel(defaults: defaults, indexURL: indexURL)
        let t1 = clock.now
        await model!.restoreSources()
        try await Self.waitUntilCurrent(model!)
        let full = await model!.ocrCounts(for: root) ?? (0, 0)
        #expect(full.pages == 200 && full.images == 200)
        log.append("Start 2: Rest erkannt in \(Self.ms(clock.now - t1)), jetzt \(full.pages) Seiten / \(full.images) Bilder")
        for (query, docs, pages) in [("fotobeleg", 200, 200), ("scanseite", 20, 200), ("kündigungsfrist", 50, 250), ("\"Akte 7 Blatt 3\"", 1, 1)] {
            model!.queryText = query
            await model!.waitForSearch()
            #expect(model!.hits.count == docs && model!.hits.reduce(0) { $0 + $1.pageHits.count } == pages,
                    "\(query): \(model!.hits.count) documents")
        }
        let footprintFull = Self.footprintMB()

        // Start 3: nothing left to recognize.
        model = nil
        model = Self.makeModel(defaults: defaults, indexURL: indexURL)
        let t2 = clock.now
        await model!.restoreSources()
        try await Self.waitUntilCurrent(model!)
        let reopen = clock.now - t2
        #expect(await model!.ocrCounts(for: root).map { $0 == full } == true)
        #expect(reopen < .seconds(10), "restart recognized again: \(Self.ms(reopen))")
        let again = try await FolderIndex(root: root.standardizedFileURL, indexURL: indexURL, slideCache: testSlideCache).recognize { _ in }
        #expect(again.recognized == 0)
        model!.queryText = "quittung"
        await model!.waitForSearch()
        #expect(model!.hits.count == 200)
        log.append("Start 3: aktuell nach \(Self.ms(reopen)), erneut erkannt: \(again.recognized)")
        log.append("Speicher (phys_footprint): Start \(footprintStart) MB, nach voller Erkennung \(footprintFull) MB, Ende \(Self.footprintMB()) MB")
        print("\nOCR-Dauertest: 50 Text-PDFs, 20 Scan-PDFs × 10 Seiten, 200 Fotos\n" + log.joined(separator: "\n") + "\n")
        model = nil
        if ProcessInfo.processInfo.environment["PDFSUCHER_LEAKS"] == "1" { print(Self.leaksSummary()) }
    }

    /// `/usr/bin/leaks` on this process (run with `MallocStackLogging=lite` for stacks); its summary lines.
    private static func leaksSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = ["\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "leaks: not started" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try? text.write(toFile: NSTemporaryDirectory() + "pdfsucher-leaks.txt", atomically: true, encoding: .utf8)
        return "leaks (Exit \(process.terminationStatus)): " + text.split(separator: "\n").filter { $0.contains("leaks for") || $0.contains("Leak:") || $0.contains("ROOT LEAK") }.prefix(40).joined(separator: "\n")
    }

    private static func makeModel(defaults: UserDefaults, indexURL: URL) -> AppModel {
        AppModel(settings: GridSettings(defaults: defaults), defaults: defaults, environment: QuietEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { try FolderIndex(root: $0.standardizedFileURL, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
    }

    private static func waitUntilCurrent(_ model: AppModel) async throws {
        let clock = ContinuousClock(), start = clock.now
        while true {
            switch model.indexStatus {
            case .upToDate, .problems: await model.waitUntilIdle(); return
            default:
                #expect(clock.now - start < .seconds(900), "index not current: \(model.indexStatus)")
                if clock.now - start > .seconds(900) { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func ms(_ d: Duration) -> String {
        String(format: "%.1f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

@MainActor private final class QuietEnvironment: AppEnvironment {
    func chooseSources() -> [URL] { [] }
    func chooseSaveLocation(defaultName: String) -> URL? { nil }
    func runPrint(_ operation: NSPrintOperation) {}
    func openInPreview(_ url: URL) {}
    func openWithDefaultApp(_ url: URL) {}
    func confirmDeleteIndex(question: String) -> Bool { false }
}
