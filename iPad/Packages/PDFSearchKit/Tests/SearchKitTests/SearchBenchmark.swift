import Testing
import Foundation
import IndexKit
import SearchKit

/// Spec §9 target (< 200 ms to the hit list, 20,000 pages). Only meaningful in a release
/// build: `PDFSUCHER_BENCH=1 swift test -c release --filter SearchBenchmark`.
@Suite("SearchBenchmark", .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_BENCH"] != nil))
struct SearchBenchmark {
    struct Corpus: IndexReading {
        let pages: [RawPageMatch]
        init() {
            let words = ["Vertrag", "Lieferung", "Größe", "Straße", "über", "Prüfung", "Änderung", "Kündigung",
                         "Auftraggeber", "verpflichtet", "Abnahme", "Gewährleistung", "Haftung", "Zahlung", "abc", "und", "die", "der"]
            var rng = SystemRandomNumberGenerator()
            pages = (0..<20_000).map { i in
                var text = ""
                while text.utf8.count < 3_000 { text += words.randomElement(using: &rng)! + " " }
                return RawPageMatch(docId: Int64(i / 20), pageIndex: i % 20, bm25: -1, text: text)
            }
        }
        func documents() throws -> [StoredDocument] {
            (0..<1_000).map { StoredDocument(id: Int64($0), relativePath: "d\($0).pdf", fileSize: 1,
                                             modifiedAt: .distantPast, pageCount: 20, status: .ok) }
        }
        func match(_ q: String, in t: FTSTable) throws -> [RawPageMatch] { pages }  // worst case: every page is a candidate
        func allPages() throws -> [RawPageMatch] { pages }
    }

    @Test func everyPageIsACandidate() throws {
        let service = SearchService(index: Corpus(), root: URL(fileURLWithPath: "/r"))
        for input in ["a*", "ver*", "*ab*", "Vertrag", "*ung", "\"die Lieferung\""] {
            let clock = ContinuousClock()
            var count = 0
            let t = try clock.measure { count = try service.search(QueryParser.parse(input, partialWords: false), sort: .matchCount).count }
            print("BENCH \(input): \(t) (\(count) docs)")
            #expect(t < .milliseconds(200), "\(input) took \(t)")
        }
    }
}
