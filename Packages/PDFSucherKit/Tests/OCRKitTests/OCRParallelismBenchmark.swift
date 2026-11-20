import Foundation
import IndexKit
import OCRKit
import Synchronization
import Testing
import TestSupport

/// Opt-in (1.4.0 P7): OCR throughput by number of parallel recognitions on real scan pages, with the recognized texts
/// compared (parallelism must not change any result). Reads only; prints numbers.
///
///     PDFSUCHER_OCR_BENCH=1 [PDFSUCHER_BENCH_ROOT=~/Documents] [PDFSUCHER_OCR_PAGES=48] swift test -c release --filter OCRParallelismBenchmark
///
/// 1.5.0: `PDFSUCHER_OCR_IMAGES=1` takes images instead of scan pages, `PDFSUCHER_OCR_LEVELS=3,4,6,8,12,16` the numbers
/// tried; while it runs, a `MainHangWatch` on this process counts blocked main-queue answers over 250 ms.
@Suite("OCR-Parallelität")
struct OCRParallelismBenchmark {
    static let env = ProcessInfo.processInfo.environment

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// Scan pages (too little text, like phase 1 marks them) from PDFs below the root, at most one per file first.
    static func scanPages(count: Int) throws -> [(URL, Int)] {
        let root = URL(fileURLWithPath: env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)
        var files = try FolderScanner().scan(root: root).filter { $0.kind == .pdf }.sorted { $0.relativePath < $1.relativePath }
        var rng = SeededGenerator(seed: 7)
        files.shuffle(using: &rng)
        var pages: [(URL, Int)] = []
        for file in files where pages.count < count {
            guard let text = try? PDFKitTextSource().pages(of: file.url) else { continue }
            if let page = text.first(where: { $0.text.count < OCRPolicy.minimumTextLength }) { pages.append((file.url, page.pageIndex)) }
        }
        return pages
    }

    /// Images below the root (any size), shuffled with a fixed seed.
    static func images(count: Int) throws -> [(URL, Int)] {
        let root = URL(fileURLWithPath: env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)
        var files = try FolderScanner(includeImages: true).scan(root: root).filter { $0.kind == .image }.sorted { $0.relativePath < $1.relativePath }
        var rng = SeededGenerator(seed: 7)
        files.shuffle(using: &rng)
        return files.prefix(count).map { ($0.url, 0) }
    }

    /// Like the Indexer: each recognition on its own utility thread, at most `parallel` at once.
    static func run(_ pages: [(URL, Int)], parallel: Int, kind: DocumentKind = .pdf) async -> (s: Double, texts: [String]) {
        let ocr = VisionOCRSource()
        let start = ContinuousClock.now
        let texts = Mutex([String](repeating: "", count: pages.count))
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < pages.count else { return }
                let i = next
                next += 1
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let thread = Thread {
                            let text = (try? ocr.recognize(pageIndex: pages[i].1, of: pages[i].0, kind: kind).text) ?? "<fehler>"
                            texts.withLock { $0[i] = text }
                            c.resume()
                        }
                        thread.qualityOfService = .utility
                        thread.start()
                    }
                }
            }
            for _ in 0..<parallel { add() }
            while await group.next() != nil { add() }
        }
        return (seconds(.now - start), texts.withLock { $0 })
    }

    @Test(.enabled(if: env["PDFSUCHER_OCR_BENCH"] == "1"), .timeLimit(.minutes(60)))
    func throughputByParallelism() async throws {
        let count = Int(Self.env["PDFSUCHER_OCR_PAGES"] ?? "") ?? 48
        let useImages = Self.env["PDFSUCHER_OCR_IMAGES"] == "1"
        let pages = try useImages ? Self.images(count: count) : Self.scanPages(count: count)
        let kind: DocumentKind = useImages ? .image : .pdf
        let levels = (Self.env["PDFSUCHER_OCR_LEVELS"] ?? "1,2,3,4,6").split(separator: ",").compactMap { Int($0) }
        print("OCRBENCH \(useImages ? "images" : "pages")=\(pages.count)")
        _ = await Self.run(Array(pages.prefix(4)), parallel: 2, kind: kind)             // warm Vision
        var reference: [String]?
        for parallel in levels {
            let logs = FileManager.default.temporaryDirectory.appendingPathComponent("ocrbench-\(UUID().uuidString)", isDirectory: true)
            let metrics = IndexMetrics(directory: logs)
            metrics.setEnabled(true)
            let watch = MainHangWatch(metrics: metrics, maxSamples: 0)
            watch.start()
            let (s, texts) = await Self.run(pages, parallel: parallel, kind: kind)
            watch.stop()
            metrics.flush()
            let hangs = ((try? String(contentsOf: logs.appendingPathComponent(metrics.logFiles().first?.lastPathComponent ?? "-"), encoding: .utf8)) ?? "")
                .components(separatedBy: "\"main_hang\"").count - 1
            try? FileManager.default.removeItem(at: logs)
            let same = reference.map { $0 == texts } ?? true
            if reference == nil { reference = texts }
            print(String(format: "OCRBENCH parallel=%d wall=%.2fs per_s=%.2f chars=%d same_text=%@ main_hangs=%d", parallel, s,
                         Double(pages.count) / s, texts.reduce(0) { $0 + $1.count }, same ? "yes" : "NO", hangs))
            #expect(same, "parallelism must not change any recognized text")
        }
    }
}
