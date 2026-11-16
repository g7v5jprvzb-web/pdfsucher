import Foundation
import IndexKit
import OfficeKit
import SearchKit
import Testing
import TestSupport
@testable import AppCore

/// Opt-in before/after measurement of a release (1.4.0) on the real Documents folder, into temporary indexes only.
/// Reads only (scenario C copies 300 PDFs into a temp folder and moves those copies). Prints numbers, never names.
///
///     PDFSUCHER_RELEASE_BENCH=1 PDFSUCHER_BENCH_OUT=<dir> swift test -c release -Xswiftc -enable-testing --filter ReleaseBenchmark
@Suite("Release-Messung", .serialized)
struct ReleaseBenchmark {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["PDFSUCHER_RELEASE_BENCH"] == "1"
    static let documents = URL(fileURLWithPath: env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await body()
        return (value, seconds(.now - start))
    }

    static func work(_ name: String) throws -> URL {
        let out = URL(fileURLWithPath: env["PDFSUCHER_BENCH_OUT"] ?? NSTemporaryDirectory() + "pdfsucher-bench", isDirectory: true)
        let dir = out.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func index(_ root: URL, in dir: URL) throws -> FolderIndex {
        let index = try FolderIndex(root: root, indexURL: dir.appendingPathComponent(IndexStore.location(forFolder: root).lastPathComponent),
                                    slideCache: SlideCache(root: dir.appendingPathComponent("Slides", isDirectory: true)))
        index.configure(.default, includeOffice: true)
        return index
    }

    /// Word documents found by a common word (searchable Word content).
    static func wordHits(_ index: FolderIndex) throws -> Int {
        try index.search(QueryParser.parse("und", partialWords: false), sort: .fileName, onPartial: nil).filter { $0.kind == .word }.count
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func a_fullRun() async throws {
        let dir = try Self.work("full")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try Self.index(Self.documents, in: dir)
        let (report, phase1) = try await Self.timed { try await index.update { _ in } }
        let wordAfterPhase1 = try Self.wordHits(index)
        let (_, wordParts) = try await Self.timed { try await index.buildWordParts { _ in } }
        let (layout, layoutS) = try await Self.timed { try await index.layOut { _ in } }
        let wordAfterLayout = try Self.wordHits(index)
        print(String(format: "BENCH full files=%d phase1=%.1fs word_searchable_after_phase1=%d wordparts=%.1fs layout=%.1fs laid_out=%d word_searchable_after_layout=%d total=%.1fs",
                     report.added, phase1, wordAfterPhase1, wordParts, layoutS, layout.laidOut, wordAfterLayout, phase1 + wordParts + layoutS))
    }

    /// B: the subfolder with the most PDFs, then its parent (the Documents folder), indexes in the same folder.
    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func b_childThenParent() async throws {
        let dir = try Self.work("child")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try FolderScanner(includeOffice: true).scan(root: Self.documents)
        let counts = Dictionary(grouping: files.filter { $0.relativePath.contains("/") }) { String($0.relativePath.split(separator: "/")[0]) }
        let (childName, childFiles) = try #require(counts.max { $0.value.count < $1.value.count })
        let child = Self.documents.appendingPathComponent(childName, isDirectory: true)
        let childIndex = try Self.index(child, in: dir)
        let (childReport, childS) = try await Self.timed { try await childIndex.update { _ in } }
        let parentIndex = try Self.index(Self.documents, in: dir)
        let (parentReport, parentS) = try await Self.timed { try await parentIndex.update { _ in } }
        print(String(format: "BENCH child files=%d child_phase1=%.1fs parent_phase1=%.1fs parent_added=%d parent_unchanged=%d (child_files=%d)",
                     childReport.added, childS, parentS, parentReport.added, parentReport.unchanged, childFiles.count))
    }

    /// C: 300 PDFs copied to a temp folder, indexed; then 100 of them moved into a new subfolder and renamed.
    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func c_moveAndRename() async throws {
        let dir = try Self.work("move")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("neu"), withIntermediateDirectories: true)
        var pdfs = try FolderScanner().scan(root: Self.documents).filter { $0.kind == .pdf && $0.fileSize < 5_000_000 }
        var rng = SeededGenerator(seed: 11)
        pdfs.shuffle(using: &rng)
        for (i, file) in pdfs.prefix(300).enumerated() {
            try FileManager.default.copyItem(at: file.url, to: root.appendingPathComponent(String(format: "d%03d.pdf", i)))
        }
        let index = try Self.index(root, in: dir)
        let (_, first) = try await Self.timed { try await index.update { _ in } }
        for i in 0..<100 {
            try FileManager.default.moveItem(at: root.appendingPathComponent(String(format: "d%03d.pdf", i)),
                                            to: root.appendingPathComponent(String(format: "neu/umbenannt-%03d.pdf", i)))
        }
        let (report, again) = try await Self.timed { try await index.update { _ in } }
        print(String(format: "BENCH move files=300 first=%.2fs after_moving_100=%.2fs added=%d removed=%d unchanged=%d report=%@",
                     first, again, report.added, report.removed, report.unchanged, String(describing: report)))
    }
}
