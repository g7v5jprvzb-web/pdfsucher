import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport

/// 1.4.3: `search_source` in the measurement log — counts and times of one source's search, never the query text.
@Suite("Search measurement")
struct SearchMetricsTests {
    @Test func searchSourceHasCountsAndTimes() throws {
        let logs = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let index = try TestIndex()
        for n in 0..<10 { try index.add("Akte \(n).pdf", pages: ["Vertraulich Vertrag \(n)", "anderes"]) }
        let root = URL(fileURLWithPath: "/tmp/Kunde", isDirectory: true)
        var partial = false
        let hits = try SearchService(index: index, root: root, metrics: metrics)
            .search(QueryParser.parse("vertrag", partialWords: false), sort: .matchCount, searchNames: true, batchSize: 4) { _ in partial = true }
        #expect(hits.count == 10)
        #expect(partial)
        metrics.flush()
        let raw = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!raw.contains("ertrag") && !raw.contains("Kunde") && !raw.contains("Akte"))
        let events = raw.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let event = try #require(events.first { $0["event"] as? String == "search_source" })
        #expect(event["source"] as? String == IndexMetrics.hash(root))
        #expect(event["candidates"] as? Int == 10)
        #expect(event["hits"] as? Int == 10)
        #expect(event["cancelled"] as? Bool == false)
        #expect((event["hits_by_kind"] as? [String: Int]) == ["pdf": 10])
        #expect((event["candidates_by_kind"] as? [String: Int]) == ["pdf": 10])
        #expect(event["documents"] as? Int == 10)
        #expect(event["office_pending"] as? Int == 0)
        for key in ["db_ms", "check_ms", "names_ms", "total_ms", "first_partial_ms"] { #expect(event[key] as? NSNumber != nil, "\(key)") }
    }
}
