// 1.3 Office Task 10/10b: measurements with real Word/PowerPoint files (measure, not assert). Opt-in only:
//   PDFSUCHER_OFFICE_PERF=1 scripts/test.sh --filter OfficeRealFilesMeasurement
// One deck per fresh process (clean peak memory): PDFSUCHER_OFFICE_ONLY=<part of the file name>
//   PDFSUCHER_OFFICE_PERF=1 PDFSUCHER_OFFICE_ONLY=<Name> scripts/test.sh --filter OfficeRealFilesMeasurement/measureRealFiles
// Generated Word files with ~10/100/500 pages (spec §12), in their own process:
//   PDFSUCHER_OFFICE_PERF=1 scripts/test.sh --filter OfficeRealFilesMeasurement/measureWordSizes
// Inputs are read only and never copied: ~/Developer/PDFSucher-testdaten/pptx/*.pptx, ~/Developer/PDFSucher-spikes/
// office/in/*.{docx,doc,pptx} and, if present, ~/Developer/PDFSucher-testdaten/docx/*. The Indexer run sees them
// through a temporary folder of symbolic links. Index, slide cache and Quick Look output live in temporary folders.
// Contact sheets (real customer content, never committed) go to PDFSUCHER_OFFICE_SHEETS or
// ~/Developer/PDFSucher-spikes/office-a-measure/; a folder inside this repository is refused. Sheets are made for the
// decks named in PDFSUCHER_OFFICE_SHEET_DECKS (comma-separated parts of file names) or, by default, for the two
// smallest decks with a hidden slide, plus test.docx.
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import IndexKit
import OutputKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import UniformTypeIdentifiers
@testable import OfficeKit

@Suite("Office real files measurement", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_OFFICE_PERF"] == "1"))
struct OfficeRealFilesMeasurement {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let deckFolder = home.appendingPathComponent("Developer/PDFSucher-testdaten/pptx", isDirectory: true)
    static let docxFolder = home.appendingPathComponent("Developer/PDFSucher-testdaten/docx", isDirectory: true)
    static let spikeIn = home.appendingPathComponent("Developer/PDFSucher-spikes/office/in", isDirectory: true)
    static let sheetFolder = ProcessInfo.processInfo.environment["PDFSUCHER_OFFICE_SHEETS"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent("Developer/PDFSucher-spikes/office-a-measure", isDirectory: true)
    /// Root of this repository (…/Packages/PDFSucherKit/Tests/OfficeKitTests/<this file>).
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Contact sheets show customer content: never write them into the repository.
    static var sheetFolderIsOutsideRepo: Bool {
        let folder = sheetFolder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let repo = repoRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return !folder.hasPrefix(repo)
    }
    /// Long side of a grid tile in pixels (about 200 pt at 2× scale).
    static let tilePixel = 400

    static func files(in folder: URL, extensions: Set<String>) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted().map { folder.appendingPathComponent($0) }
    }

    /// Optional filter (substring of the file name), e.g. to look at one deck in a fresh process.
    static let only = ProcessInfo.processInfo.environment["PDFSUCHER_OFFICE_ONLY"]

    static var inputs: [URL] {
        let all = files(in: deckFolder, extensions: ["pptx"])
            + files(in: docxFolder, extensions: ["docx", "doc"])
            + ["test.docx", "test.doc", "test.pptx", "test äöü leer.pptx"].map { spikeIn.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        return only.map { o in all.filter { $0.lastPathComponent.contains(o) } } ?? all
    }

    // MARK: Helpers

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Peak resident size of this process so far (MB).
    static func maxRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
    }

    /// Current physical footprint of this process (MB).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func folderSizeMB(_ url: URL) -> Double {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = e?.nextObject() as? URL { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return Double(total) / 1_048_576
    }

    static func fileSizeMB(_ url: URL) -> Double {
        Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_048_576
    }

    static func short(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().lastPathComponent == "in" ? url.lastPathComponent : String(name.prefix(40))
    }

    static func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    /// Timestamps from the snapshot hook and the generator wrapper.
    final class Clock: Sendable {
        let marks = Mutex<[(String, ContinuousClock.Instant)]>([])
        func mark(_ name: String) { marks.withLock { $0.append((name, .now)) } }
        func time(of name: String) -> ContinuousClock.Instant? { marks.withLock { m in m.first { $0.0 == name }?.1 } }
        func slideStarts() -> [ContinuousClock.Instant] { marks.withLock { m in m.filter { $0.0.hasPrefix("slide") }.map(\.1) } }
    }

    // MARK: Per file

    struct Row {
        var name = "", sizeMB = 0.0, kind = ""
        var total = 0.0, quickLook = 0.0, load = 0.0, imageWait = 0.0, warmUp = 0.0
        var slideTimes: [Double] = []
        var pages = 0, visible = 0, xmlTotal = 0
        var cacheMB = 0.0, rssBefore = 0.0, rssAfter = 0.0, footprintAfter = 0.0, footprintLastSlide = 0.0, rssLastSlide = 0.0, rssBeforeSlides = 0.0
        /// HEIC encoding + writing of all slides again from the cache (≈ the `cache.store` share of the last slide).
        var storeAgain = 0.0
        /// maxrss at the start of every slide (MB), to see whether the peak grows with the slide count.
        var rssPerSlide: [Double] = []
        var error = ""
    }

    static func measureDeck(_ url: URL, cache: SlideCache, cacheRoot: URL) async -> Row {
        var row = Row(name: short(url), sizeMB: fileSizeMB(url), kind: "pptx")
        if let slides = try? PresentationSlides.slides(of: url) {
            row.xmlTotal = slides.count
            row.visible = slides.filter { !$0.hidden }.count
        }
        let clock = Clock()
        let footprints = Mutex<[Double]>([])
        let rss = Mutex<[Double]>([])
        let html = QuickLookHTML()
        let source = QuickLookSlideSource(cache: cache, generate: { file in
            clock.mark("qlStart")
            defer { clock.mark("qlEnd") }
            return try await html.generate(for: file)
        }, snapshotHook: { step, _ in
            switch step {
            case .beforeLoad: clock.mark("load")
            case .afterLoad: clock.mark("loaded")
            case .beforeImageWait: clock.mark("imageWait")
            case .beforeWarmUp:
                clock.mark("warmUp")
                rss.withLock { $0.append(maxRSSMB()) }
            case .beforeSlide(let i):
                clock.mark("slide\(i)")
                footprints.withLock { $0.append(footprintMB()) }
                rss.withLock { $0.append(maxRSSMB()) }
            }
        })
        row.rssBefore = maxRSSMB()
        let start = ContinuousClock.now
        do {
            let result = try await source.layout(of: url, kind: .powerpoint)
            row.pages = result.pages.count
        } catch {
            row.error = "\(error)"
        }
        let end = ContinuousClock.now
        row.total = seconds(end - start)
        if let a = clock.time(of: "qlStart"), let b = clock.time(of: "qlEnd") { row.quickLook = seconds(b - a) }
        if let a = clock.time(of: "load"), let b = clock.time(of: "loaded") { row.load = seconds(b - a) }
        if let a = clock.time(of: "imageWait"), let b = clock.time(of: "warmUp") { row.imageWait = seconds(b - a) }
        let starts = clock.slideStarts()
        if let a = clock.time(of: "warmUp"), let b = starts.first { row.warmUp = seconds(b - a) }
        // Slide i: from its start to the next one's start (includes encoding and writing its image into the cache since
        // Task 10b); the last one until layout returned (also includes publishing the cache entry).
        for (i, s) in starts.enumerated() where i + 1 < starts.count { row.slideTimes.append(seconds(starts[i + 1] - s)) }
        row.rssAfter = maxRSSMB()
        row.footprintAfter = footprintMB()
        if let key = try? QuickLookSlideSource.cacheKey(for: url) {
            row.cacheMB = folderSizeMB(cacheRoot.appendingPathComponent(key.id, isDirectory: true))
        }
        if let last = starts.last { row.slideTimes.append(seconds(end - last)) } // last slide + cache store
        row.footprintLastSlide = footprints.withLock { $0.max() ?? 0 }
        row.rssBeforeSlides = rss.withLock { $0.first ?? 0 }
        row.rssLastSlide = rss.withLock { $0.last ?? 0 }
        row.rssPerSlide = Array(rss.withLock { $0 }.dropFirst()) // first value is from before the warm-up
        if let key = try? QuickLookSlideSource.cacheKey(for: url), let count = cache.slideCount(for: key) {
            let images = (0..<count).compactMap { cache.image(for: key, slide: $0) }
            let scratch = SlideCache(root: cacheRoot.deletingLastPathComponent().appendingPathComponent("SlideCache-again"))
            let s = ContinuousClock.now
            try? scratch.store(images, for: key)
            row.storeAgain = seconds(ContinuousClock.now - s)
            try? scratch.clear()
        }
        return row
    }

    static func measureWord(_ url: URL) async -> Row {
        var row = Row(name: short(url), sizeMB: fileSizeMB(url), kind: url.pathExtension.lowercased())
        row.rssBefore = maxRSSMB()
        let start = ContinuousClock.now
        do {
            let kind = DocumentKind(fileExtension: url.pathExtension) ?? .word
            row.pages = try await TextKitWordSource().layout(of: url, kind: kind).pages.count
        } catch {
            row.error = "\(error)"
        }
        row.total = seconds(ContinuousClock.now - start)
        row.rssAfter = maxRSSMB()
        row.footprintAfter = footprintMB()
        return row
    }

    // MARK: Contact sheet

    /// The first `count` tiles side by side (3 per row) on light grey, as one PNG.
    static func writeSheet(_ images: [CGImage], to url: URL, cell: Int = tilePixel) throws {
        let columns = 3, rows = max(1, (images.count + columns - 1) / columns), gap = 16
        let width = columns * cell + (columns + 1) * gap, height = rows * cell + (rows + 1) * gap
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            let scale = min(Double(cell) / Double(image.width), Double(cell) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            let x = Double(gap + col * (cell + gap)) + (Double(cell) - w) / 2
            let y = Double(height - (gap + row * (cell + gap)) - cell) + (Double(cell) - h) / 2
            ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
        }
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Wraps a layout source and records how long each `layout` call took (under the Indexer's concurrency).
    final class TimingLayoutSource: PageLayoutSource {
        let inner: any PageLayoutSource
        let times = Mutex<[(String, Double)]>([])
        init(_ inner: any PageLayoutSource) { self.inner = inner }
        func renderer(for kind: DocumentKind) -> (name: String, version: Int) { inner.renderer(for: kind) }
        func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
            let start = ContinuousClock.now
            defer { let t = OfficeRealFilesMeasurement.seconds(ContinuousClock.now - start); times.withLock { $0.append((url.lastPathComponent, t)) } }
            return try await inner.layout(of: url, kind: kind)
        }
    }

    // MARK: Test

    @Test(.timeLimit(.minutes(60)))
    func measureRealFiles() async throws {
        // Before any work: contact sheets show customer content and must never land in the repository.
        try #require(Self.sheetFolderIsOutsideRepo, "PDFSUCHER_OFFICE_SHEETS darf nicht im Repository liegen")
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let inputs = Self.inputs
        try #require(!inputs.isEmpty, "keine Testdateien gefunden")
        print("OFFICEPERF docx-Ordner \(Self.docxFolder.path) vorhanden: \(fm.fileExists(atPath: Self.docxFolder.path))")
        print("OFFICEPERF start maxrss \(Self.f(Self.maxRSSMB(), 0)) MB, footprint \(Self.f(Self.footprintMB(), 0)) MB")

        // 1. Each file on its own, one after the other (no concurrency), with stage times.
        let cacheRoot = base.appendingPathComponent("SlideCache-direct", isDirectory: true)
        let cache = SlideCache(root: cacheRoot)
        var rows: [Row] = []
        for url in inputs {
            let row = DocumentKind(fileExtension: url.pathExtension) == .powerpoint
                ? await Self.measureDeck(url, cache: cache, cacheRoot: cacheRoot)
                : await Self.measureWord(url)
            rows.append(row)
            if ["test.docx", "test.doc"].contains(url.lastPathComponent) {
                #expect(row.pages == 3, "\(url.lastPathComponent): 3 Seiten wie das Referenz-PDF")
            }
            let slides = row.slideTimes
            // Median/max without the last slide (its time includes publishing the cache entry), as in performance.md.
            let regular = Array(slides.dropLast())
            let median = regular.isEmpty ? 0 : regular.sorted()[regular.count / 2]
            print("OFFICEPERF row | \(row.name) | \(row.kind) | \(Self.f(row.sizeMB, 1)) MB | total \(Self.f(row.total, 3)) s"
                  + " | QL \(Self.f(row.quickLook)) s | load \(Self.f(row.load)) s | imgWait \(Self.f(row.imageWait)) s"
                  + " | warmUp \(Self.f(row.warmUp)) s | slide median \(Self.f(median, 3)) s"
                  + " max \(Self.f(regular.max() ?? 0, 3)) s last \(Self.f(slides.last ?? 0, 3)) s sum \(Self.f(slides.reduce(0, +))) s"
                  + " | pages \(row.pages) visible \(row.visible) xml \(row.xmlTotal) | cache \(Self.f(row.cacheMB, 1)) MB"
                  + " | maxrss \(Self.f(row.rssBefore, 0))→\(Self.f(row.rssAfter, 0)) MB footprint \(Self.f(row.footprintAfter, 0)) MB"
                  + " (at last slide \(Self.f(row.footprintLastSlide, 0)) MB; maxrss before slides \(Self.f(row.rssBeforeSlides, 0)), at last slide \(Self.f(row.rssLastSlide, 0)) MB) | store again \(Self.f(row.storeAgain)) s"
                  + " | error \(row.error.isEmpty ? "-" : row.error)")
            if !row.rssPerSlide.isEmpty {
                let marks = stride(from: 0, to: row.rssPerSlide.count, by: 10).map { "\($0):\(Self.f(row.rssPerSlide[$0], 0))" }
                print("OFFICEPERF rss \(row.name): maxrss MB at slide " + marks.joined(separator: " ")
                      + " last:\(Self.f(row.rssPerSlide.last ?? 0, 0)) after:\(Self.f(row.rssAfter, 0))")
            }
            if !slides.isEmpty { print("OFFICEPERF slides \(row.name): " + slides.map { Self.f($0, 3) }.joined(separator: " ")) }
        }

        // 2. Thumbnails from the cache: first tile cold (fresh OfficePages, image read from disk), then 6 tiles.
        let pages = OfficePages(cache: cache)
        try fm.createDirectory(at: Self.sheetFolder, withIntermediateDirectories: true)
        let sheetDecks: [URL]
        if let names = ProcessInfo.processInfo.environment["PDFSUCHER_OFFICE_SHEET_DECKS"] {
            let parts = names.split(separator: ",").map(String.init)
            sheetDecks = inputs.filter { url in parts.contains { url.lastPathComponent.contains($0) } }
        } else {
            sheetDecks = Array(zip(inputs, rows).filter { $0.1.kind == "pptx" && $0.1.visible < $0.1.xmlTotal }
                .sorted { $0.1.sizeMB < $1.1.sizeMB }.prefix(2).map(\.0))
        }
        let sheetInputs = sheetDecks + inputs.filter { $0.lastPathComponent == "test.docx" }
        for url in sheetInputs {
            let t0 = ContinuousClock.now
            let first = pages.thumbnail(PageRef(url: url, pageIndex: 0), maxPixel: Self.tilePixel)
            let firstTime = Self.seconds(ContinuousClock.now - t0)
            var images: [CGImage] = first.map { [$0] } ?? []
            let t1 = ContinuousClock.now
            for i in 1..<6 { if let image = pages.thumbnail(PageRef(url: url, pageIndex: i), maxPixel: Self.tilePixel) { images.append(image) } }
            let restTime = Self.seconds(ContinuousClock.now - t1)
            let name = "\(Self.short(url).replacingOccurrences(of: " ", with: "_")).png"
            try Self.writeSheet(images, to: Self.sheetFolder.appendingPathComponent(name))
            print("OFFICEPERF thumb | \(Self.short(url)) | first \(Self.f(firstTime * 1000, 1)) ms | next 5 \(Self.f(restTime * 1000, 1)) ms"
                  + " | tiles \(images.count) | sheet \(name)")
        }

        // 3. A real Indexer run over a folder of symbolic links to the originals (no copies), then an incremental run.
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for url in inputs { try fm.createSymbolicLink(at: root.appendingPathComponent(url.lastPathComponent), withDestinationURL: url) }
        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let indexCache = SlideCache(root: base.appendingPathComponent("SlideCache-indexer", isDirectory: true))
        let timing = TimingLayoutSource(
            OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: indexCache), word: TextKitWordSource()))
        let counting = OfficeEndToEndTests.CountingLayoutSource(timing)
        let rssBefore = Self.maxRSSMB()
        var t0 = ContinuousClock.now
        let first = try await Indexer(root: root, store: store, layout: counting, layoutConcurrency: 2).update { _ in }
        let firstTime = Self.seconds(ContinuousClock.now - t0)
        print("OFFICEPERF indexer1 | wall \(Self.f(firstTime)) s | added \(first.added) failed \(first.failed)"
              + " | layout laidOut \(first.layout.laidOut) failed \(first.layout.failed) noText \(first.layout.noText)"
              + " deferred \(first.layout.deferred) | layout calls \(counting.calls.count)"
              + " | maxrss \(Self.f(rssBefore, 0))→\(Self.f(Self.maxRSSMB(), 0)) MB footprint \(Self.f(Self.footprintMB(), 0)) MB"
              + " | cache \(Self.f(Self.folderSizeMB(base.appendingPathComponent("SlideCache-indexer")), 1)) MB")
        for (name, t) in timing.times.withLock({ $0 }) { print("OFFICEPERF indexer1 file | \(name.prefix(40)) | \(Self.f(t)) s") }
        for doc in try store.documents() {
            print("OFFICEPERF doc | \(doc.relativePath.prefix(40)) | \(doc.kind) | pages \(doc.pageCount) | \(doc.status)"
                  + " | renderer \(doc.renderer ?? "-")")
        }
        let callsBefore = counting.calls.count
        t0 = ContinuousClock.now
        let second = try await Indexer(root: root, store: store, layout: counting, layoutConcurrency: 2).update { _ in }
        print("OFFICEPERF indexer2 | wall \(Self.f(Self.seconds(ContinuousClock.now - t0), 3)) s | unchanged \(second.unchanged)"
              + " added \(second.added) updated \(second.updated) | layout laidOut \(second.layout.laidOut)"
              + " | layout calls \(counting.calls.count - callsBefore)")

        // 4. Search over this index (spec §9 < 200 ms; tiny index, just to see nothing Office-specific slows it).
        let service = SearchService(index: store, root: root)
        for text in ["und", "Daten*", "*ung", "gibtsnicht"] {
            let query = QueryParser.parse(text, partialWords: false)
            var times: [Double] = []
            var hitCount = 0, pageCount = 0
            for _ in 0..<5 {
                let s = ContinuousClock.now
                let hits = try service.search(query, sort: .matchCount)
                times.append(Self.seconds(ContinuousClock.now - s))
                hitCount = hits.count
                pageCount = hits.reduce(0) { $0 + $1.pageHits.count }
            }
            print("OFFICEPERF search | \(text) | docs \(hitCount) pages \(pageCount) | median \(Self.f(times.sorted()[2] * 1000, 1)) ms"
                  + " max \(Self.f((times.max() ?? 0) * 1000, 1)) ms")
        }
        // 5. Is Quick Look's HTML the same every time? Three generations per deck: `<img>` elements and files.
        for url in inputs where DocumentKind(fileExtension: url.pathExtension) == .powerpoint {
            var counts: [String] = []
            for _ in 0..<3 {
                let output = try await QuickLookHTML().generate(for: url)
                defer { output.remove() }
                let html = (try? String(contentsOf: output.html, encoding: .utf8)) ?? ""
                let images = html.components(separatedBy: "<img ").count - 1
                let files = (try? fm.contentsOfDirectory(atPath: output.html.deletingLastPathComponent().path).count) ?? 0
                counts.append("\(images) img/\(files) Dateien/\(html.utf8.count) B")
            }
            print("OFFICEPERF qlrepeat | \(Self.short(url)) | " + counts.joined(separator: " | "))
        }
        print("OFFICEPERF end maxrss \(Self.f(Self.maxRSSMB(), 0)) MB, footprint \(Self.f(Self.footprintMB(), 0)) MB")
    }

    // MARK: Word sizes (spec §12)

    /// German paragraphs with umlauts, ~600 characters each (no customer content).
    static let wordParagraphs = [
        "Die Kündigungsfrist für den Vertrag beträgt drei Monate zum Quartalsende. Änderungen müssen schriftlich erfolgen und von beiden Parteien unterzeichnet werden. Für Rückfragen zur Abrechnung steht die Buchhaltung montags bis freitags zur Verfügung; außerhalb dieser Zeiten werden Anfragen am nächsten Werktag beantwortet. Die Gebühren richten sich nach der jeweils gültigen Preisliste, die diesem Schreiben als Anlage beigefügt ist. Bitte prüfen Sie die Angaben sorgfältig und teilen Sie uns Abweichungen unverzüglich mit, damit wir die Unterlagen rechtzeitig berichtigen können.",
        "Im Rahmen der jährlichen Überprüfung wurden sämtliche Zählerstände erfasst und mit den Vorjahreswerten verglichen. Der Verbrauch ist gegenüber dem Vorjahr um rund zwölf Prozent gesunken, was vor allem auf die Erneuerung der Heizungsanlage und die verbesserte Dämmung der Außenwände zurückzuführen ist. Die Nachzahlung für das abgelaufene Jahr fällt deshalb geringer aus als ursprünglich geschätzt. Die monatlichen Abschläge werden ab dem übernächsten Monat angepasst; eine gesonderte Mitteilung über die genaue Höhe erhalten Sie in den kommenden Wochen.",
        "Für die Übergabe der Wohnung vereinbaren wir einen gemeinsamen Termin, bei dem alle Räume begangen und etwaige Mängel im Übergabeprotokoll festgehalten werden. Schlüssel, Fernbedienungen für das Garagentor und die Codekarte für den Fahrradkeller sind vollständig zurückzugeben. Schönheitsreparaturen sind gemäß den Vereinbarungen im Mietvertrag fachgerecht auszuführen. Die Rückzahlung der Kaution erfolgt nach Prüfung der Nebenkostenabrechnung, spätestens jedoch sechs Monate nach Beendigung des Mietverhältnisses, abzüglich etwaiger berechtigter Forderungen.",
        "Größere Anschaffungen über fünftausend Euro bedürfen der vorherigen Zustimmung der Geschäftsführung. Anträge sind mit einer kurzen Begründung, mindestens zwei Vergleichsangeboten und einer Übersicht der voraussichtlichen Folgekosten einzureichen. Über die Genehmigung wird in der Regel innerhalb von zehn Arbeitstagen entschieden. Bereits begonnene Maßnahmen ohne Freigabe können nachträglich nicht erstattet werden. Für Rückfragen zum Verfahren wenden Sie sich bitte an die Abteilung Einkauf, die auch die zugehörigen Formulare bereithält.",
    ]

    /// Paragraphs for about `pages` A4 pages (calibrated: ~7.2 paragraphs per page with the fixture's defaults).
    static func paragraphs(forPages pages: Int) -> [String] {
        let count = Int((Double(pages) * 7.2).rounded())
        return (0..<count).map { "\($0 + 1). " + wordParagraphs[$0 % wordParagraphs.count] }
    }

    @Test(.timeLimit(.minutes(30)))
    func measureWordSizes() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        print("OFFICEPERF wordsizes start maxrss \(Self.f(Self.maxRSSMB(), 0)) MB, footprint \(Self.f(Self.footprintMB(), 0)) MB")
        for target in [10, 100, 500] {
            let paragraphs = Self.paragraphs(forPages: target)
            // Two identical files: A is laid out (cold) and then thumbnailed warm; B is thumbnailed cold.
            let a = try OfficeFixtures.docx(paragraphs: paragraphs, name: "Word-\(target)-A.docx", in: dir)
            let b = try OfficeFixtures.docx(paragraphs: paragraphs, name: "Word-\(target)-B.docx", in: dir)
            let rssBefore = Self.maxRSSMB()
            var start = ContinuousClock.now
            let result = try await TextKitWordSource().layout(of: a, kind: .word)
            let layout = Self.seconds(ContinuousClock.now - start)
            let rssAfterLayout = Self.maxRSSMB()
            let pages = OfficePages(cache: SlideCache(root: dir.appendingPathComponent("SlideCache")))
            start = ContinuousClock.now
            let warm = pages.thumbnail(PageRef(url: a, pageIndex: 0), maxPixel: Self.tilePixel)
            let warmTime = Self.seconds(ContinuousClock.now - start)
            start = ContinuousClock.now
            let cold = pages.thumbnail(PageRef(url: b, pageIndex: 0), maxPixel: Self.tilePixel)
            let coldTime = Self.seconds(ContinuousClock.now - start)
            #expect(warm != nil && cold != nil)
            let count = result.pages.count
            print("OFFICEPERF wordsize | target \(target) | paragraphs \(paragraphs.count) | file \(Self.f(Self.fileSizeMB(a) * 1024, 0)) KB"
                  + " | pages \(count) | layout \(Self.f(layout, 3)) s | per page \(Self.f(layout / Double(max(1, count)) * 1000, 2)) ms"
                  + " | thumb p0 warm \(Self.f(warmTime * 1000, 1)) ms cold \(Self.f(coldTime * 1000, 1)) ms"
                  + " | maxrss \(Self.f(rssBefore, 0))→\(Self.f(rssAfterLayout, 0))→\(Self.f(Self.maxRSSMB(), 0)) MB"
                  + " footprint \(Self.f(Self.footprintMB(), 0)) MB")
        }
    }
}
