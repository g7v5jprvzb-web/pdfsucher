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

    /// Like the Indexer: each recognition on its own utility thread, at most `parallel` at once.
    static func run(_ pages: [(URL, Int)], parallel: Int) async -> (s: Double, texts: [String]) {
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
                            let text = (try? ocr.recognize(pageIndex: pages[i].1, of: pages[i].0, kind: .pdf).text) ?? "<fehler>"
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
        let pages = try Self.scanPages(count: Int(Self.env["PDFSUCHER_OCR_PAGES"] ?? "") ?? 48)
        print("OCRBENCH pages=\(pages.count)")
        _ = await Self.run(Array(pages.prefix(4)), parallel: 2)             // warm Vision
        var reference: [String]?
        for parallel in [1, 2, 3, 4, 6] {
            let (s, texts) = await Self.run(pages, parallel: parallel)
            let same = reference.map { $0 == texts } ?? true
            if reference == nil { reference = texts }
            print(String(format: "OCRBENCH parallel=%d wall=%.2fs pages/s=%.2f chars=%d same_text=%@", parallel, s, Double(pages.count) / s,
                         texts.reduce(0) { $0 + $1.count }, same ? "yes" : "NO"))
            #expect(same, "parallelism must not change any recognized text")
        }
    }
}
