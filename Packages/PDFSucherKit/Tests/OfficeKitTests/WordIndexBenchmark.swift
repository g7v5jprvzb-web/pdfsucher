// WordIndexBenchmark.swift — 1.3.2: first-index time of Word documents (TextKit layout), opt-in:
//   PDFSUCHER_WORD_INDEX_BENCH=1 scripts/test.sh --filter WordIndexBenchmark
// Generated documents only (no customer files); Office's real font folders are never read (`officeFontRoots` .none).
// Each repetition indexes a fresh copy of the folder (new paths: no hit in the TextKit document cache) into a new
// store with the Indexer's defaults (2 layouts at once, as the app). Prints the wall times; asserts nothing on them.
import Foundation
import IndexKit
import OOXMLKit
import Testing
import TestSupport
@testable import OfficeKit

@Suite("Word index benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_WORD_INDEX_BENCH"] == "1"))
struct WordIndexBenchmark {
    static let documents = 24
    static let repetitions = 5

    /// 24 Word documents of 1 to ~25 pages (≈ 230 pages in all).
    static func corpus(in dir: URL) throws {
        for i in 0..<documents {
            let paragraphs = (0..<(10 + (i % 8) * 60)).map {
                "Dokument \(i) Absatz \($0): Die Kündigungsfrist beträgt drei Monate zum Quartalsende, schriftlich."
            }
            try OfficeFixtures.docx(paragraphs: paragraphs, pageBreakAfter: i.isMultiple(of: 3) ? [0] : [],
                                    name: "Wort\(i).docx", in: dir)
        }
    }

    @Test func firstIndexOfWordDocuments() async throws {
        #expect(FontResolver.officeFontRoots == .none)
        let base = try PDFFixtures.tempDirectory()
        let source = base.appendingPathComponent("vorlage", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.corpus(in: source)
        var times: [Duration] = []
        var pages = 0
        for rep in 0..<Self.repetitions {
            let root = base.appendingPathComponent("lauf\(rep)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: root)
            let store = try IndexStore(fileURL: base.appendingPathComponent("index\(rep).sqlite"), root: root)
            let indexer = Indexer(root: root, store: store, layout: OfficeLayoutSource(word: TextKitWordSource()))
            var report: IndexReport?
            let time = try await ContinuousClock().measure { report = try await indexer.update { _ in } }
            #expect(report?.added == Self.documents && report?.layout.failed.isEmpty == true, "\(String(describing: report))")
            pages = try store.documents().reduce(0) { $0 + $1.pageCount }
            times.append(time)
        }
        let ms = times.map { Int($0 / .milliseconds(1)) }
        let sorted = ms.sorted()
        print("WORDBENCH \(Self.documents) docs, \(pages) pages: runs \(ms) ms, median \(sorted[sorted.count / 2]) ms")
    }
}
