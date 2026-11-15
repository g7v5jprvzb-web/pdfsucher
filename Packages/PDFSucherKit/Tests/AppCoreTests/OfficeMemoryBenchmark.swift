import CoreGraphics
import Darwin
import Foundation
import ImageIO
import IndexKit
import OfficeKit
import OutputKit
import SlideKit
import SlideKitAdapter
import Synchronization
import Testing
import TestSupport
import UniformTypeIdentifiers

/// Memory of the Office layout phase and of slide tiles (1.3.2), opt-in:
///
/// ```
/// PDFSUCHER_MEMBENCH=1 PDFSUCHER_MEMBENCH_LAYOUT=2 PDFSUCHER_MEMBENCH_DECKS=4 \
///   scripts/test.sh --no-parallel --filter OfficeMemoryBenchmark
/// ```
///
/// One configuration per process (the process peak is per process): `PDFSUCHER_MEMBENCH_LAYOUT` = PowerPoint layouts
/// at once in the index run (0 = no index run), `PDFSUCHER_MEMBENCH_DECKS` = `SlideDeckCache` capacity for tiles
/// drawn at the same time as the index run (0 = no tiles), `PDFSUCHER_MEMBENCH_PIXEL` = tile size (long side, default
/// 512), `PDFSUCHER_MEMBENCH_RENDERER=quicklook` = Quick Look instead of SlideKit for the layout. Synthetic decks only (no customer files): 8 decks × 30
/// slides, each slide a distinct 3000 × 2250 PNG over the whole slide plus text; generated once into the temp folder.
/// Office's own fonts: off in test processes (`FontResolver.officeFontRoots` is `.none`); for numbers with the
/// fonts an installed Office brings, add `PDFSUCHER_TEST_OFFICE_FONTS=1` (reads Office's real font folders and cache).
@Suite("Office memory benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_MEMBENCH"] == "1"))
struct OfficeMemoryBenchmark {
    static let deckCount = 8, slidesPerDeck = 30
    static let imageSize = CGSize(width: 3000, height: 2250)

    static func env(_ key: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
    }

    /// The decks, generated once (a marker file says they are complete).
    static func corpus() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSucherMemBench-v1", isDirectory: true)
        let marker = dir.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) { return dir }
        try? FileManager.default.removeItem(at: dir)
        let decks = dir.appendingPathComponent("decks", isDirectory: true)
        try FileManager.default.createDirectory(at: decks, withIntermediateDirectories: true)
        var images: [Data] = []
        for i in 0..<slidesPerDeck {
            let image = try ImageFixtures.render(text: "Bild \(i + 1)", size: imageSize)
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            images.append(data as Data)
        }
        for d in 0..<deckCount {
            let slides = (0..<slidesPerDeck).map { "Deck \(d + 1) Folie \($0 + 1)\nUmsatz Planung Vertrag Angebot Kündigung" }
            try OfficeFixtures.pptx(slides: slides, slideImages: images, name: "Deck\(d + 1).pptx", in: decks)
        }
        try Data().write(to: marker)
        return dir
    }

    /// phys_footprint now and the process peak (bytes).
    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }

    static func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    @Test func measure() async throws {
        let layoutAtOnce = Self.env("PDFSUCHER_MEMBENCH_LAYOUT", 2)
        let deckCapacity = Self.env("PDFSUCHER_MEMBENCH_DECKS", 0)
        let maxPixel = Self.env("PDFSUCHER_MEMBENCH_PIXEL", 512)
        let quickLook = ProcessInfo.processInfo.environment["PDFSUCHER_MEMBENCH_RENDERER"] == "quicklook"
        let corpus = try Self.corpus()
        let decks = corpus.appendingPathComponent("decks", isDirectory: true)
        let deckURLs = try FileManager.default.contentsOfDirectory(at: decks, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pptx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Font registration once before the baseline (the app does it before the first layout too).
        FontResolverWarmup.run()
        let base = Self.footprint()
        let peak = Mutex<UInt64>(base.now)
        let sampling = Mutex(true)
        let sampler = Thread {
            while sampling.withLock({ $0 }) {
                let now = Self.footprint().now
                peak.withLock { $0 = max($0, now) }
                usleep(2_000)
            }
        }
        sampler.start()
        let clock = ContinuousClock()
        let started = clock.now

        async let layoutRun: Int = {
            guard layoutAtOnce > 0 else { return 0 }
            let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent("membench-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: indexURL) }
            let store = try IndexStore(fileURL: indexURL, root: decks)
            let slideRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("membench-slides-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: slideRoot) }
            let slideCache = SlideCache(root: slideRoot)
            let powerpoint: any PageLayoutSource = quickLook ? QuickLookSlideSource(cache: slideCache)
                                                             : SlideKitLayoutSource(fontSubstitution: .powerPoint)
            let source = OfficeLayoutSource(powerpoint: powerpoint)
            let indexer = Indexer(root: decks, store: store, layout: source, layoutConcurrency: layoutAtOnce)
            let report = try await indexer.update { _ in }
            return report.layout.laidOut
        }()
        async let tiles: Int = {
            guard deckCapacity > 0 else { return 0 }
            let pages = SlideKitPages(fontSubstitution: .powerPoint, decks: SlideDeckCache(capacity: deckCapacity))
            var drawn = 0
            for url in deckURLs {
                for i in 0..<Self.slidesPerDeck where pages.thumbnail(PageRef(url: url, pageIndex: i), maxPixel: maxPixel) != nil {
                    drawn += 1
                }
            }
            return drawn
        }()
        let (indexed, drawn) = try await (layoutRun, tiles)
        let elapsed = clock.now - started
        sampling.withLock { $0 = false }
        let after = Self.footprint()
        let sampledPeak = peak.withLock { $0 }
        let line = "MEMBENCH \(quickLook ? "quicklook" : "slidekit") layout=\(layoutAtOnce) decks=\(deckCapacity) px=\(maxPixel): indexed \(indexed), tiles \(drawn), "
            + "\(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))); "
            + "base \(Self.mb(base.now)), sampled peak +\(Self.mb(sampledPeak - base.now)), "
            + "process peak \(Self.mb(after.peak)), after \(Self.mb(after.now))"
        print(line)
        #expect(indexed > 0 || drawn > 0)
    }
}

/// Registers Office's fonts (blocking, idempotent) before a measurement.
enum FontResolverWarmup {
    static func run() { OfficeDisplay.prewarmFonts() }
}
