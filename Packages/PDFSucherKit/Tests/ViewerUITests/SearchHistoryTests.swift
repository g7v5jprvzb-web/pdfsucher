import Foundation
import Testing
@testable import ViewerUI

/// 1.2.2 §1: the search history keeps terms that arrived, newest first, without duplicates or typing prefixes.
@MainActor @Suite("Search history")
struct SearchHistoryTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "History-\(UUID())")! }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func commitTrimsAndSkipsEmpty() {
        let h = SearchHistory(defaults: defaults())
        h.commit("  Vertrag  ", now: t0)
        h.commit("   ", now: t0)
        h.commit("", now: t0)
        #expect(h.entries == ["Vertrag"])
    }

    @Test func duplicatesMoveToTop() {
        let h = SearchHistory(defaults: defaults())
        h.commit("Miete", now: t0)
        h.commit("Angebot", now: t0.addingTimeInterval(60))
        h.commit("miete", now: t0.addingTimeInterval(120))
        #expect(h.entries == ["miete", "Angebot"])
    }

    @Test func prefixReplacedWhenRecent() {
        let h = SearchHistory(defaults: defaults())
        h.commit("Vertr", now: t0, viaPause: true)
        h.commit("Vertrag", now: t0.addingTimeInterval(4))
        #expect(h.entries == ["Vertrag"])
        h.commit("Kün", now: t0.addingTimeInterval(100), viaPause: true)
        h.commit("Kündigung", now: t0.addingTimeInterval(100 + SearchHistory.prefixWindow + 1))
        #expect(h.entries == ["Kündigung", "Kün", "Vertrag"], "an old prefix stays")
        h.commit("Vertrag Miete", now: t0.addingTimeInterval(1_000))
        #expect(h.entries.first == "Vertrag Miete")
        #expect(h.entries.contains("Vertrag"), "only the newest entry counts as a typing prefix")
    }

    /// Review I1: a term chosen on purpose (Return, from the list) is never replaced by a longer one.
    @Test func chosenTermIsNotAPrefix() {
        let h = SearchHistory(defaults: defaults())
        h.commit("Bau", now: t0)                                  // Return or chosen from the list
        h.commit("Bauantrag", now: t0.addingTimeInterval(3))
        #expect(h.entries == ["Bauantrag", "Bau"])
        h.commit("Miet", now: t0.addingTimeInterval(100), viaPause: true)
        h.commit("Miete", now: t0.addingTimeInterval(102), viaPause: true)
        h.commit("Mieterhöhung", now: t0.addingTimeInterval(104))
        #expect(h.entries.first == "Mieterhöhung" && !h.entries.contains("Miet") && !h.entries.contains("Miete"))
    }

    /// Review I2/M2: committing the newest entry again changes nothing (no write, prefix window not extended).
    @Test func repeatOfNewestChangesNothing() {
        let h = SearchHistory(defaults: defaults())
        h.commit("Vertr", now: t0, viaPause: true)
        h.commit("Vertr", now: t0.addingTimeInterval(8), viaPause: true)
        h.commit("Vertrag", now: t0.addingTimeInterval(15))
        #expect(h.entries == ["Vertrag", "Vertr"], "the window counts from the first save")
    }

    @Test func limitAndTrim() {
        let d = defaults()
        let h = SearchHistory(defaults: d)
        #expect(h.limit == 30)
        for i in 0..<40 { h.commit("Begriff \(i)", now: t0.addingTimeInterval(Double(i) * 60)) }
        #expect(h.entries.count == 30 && h.entries.first == "Begriff 39")
        h.limit = 10
        #expect(h.entries.count == 10)
        h.limit = 500
        #expect(h.limit == SearchHistory.limitRange.upperBound)
        h.limit = 1
        #expect(h.limit == SearchHistory.limitRange.lowerBound)
    }

    @Test func disableClears() {
        let h = SearchHistory(defaults: defaults())
        h.commit("Vertrag", now: t0)
        h.isEnabled = false
        #expect(h.entries.isEmpty)
        h.commit("Miete", now: t0.addingTimeInterval(60))
        #expect(h.entries.isEmpty)
        h.isEnabled = true
        h.commit("Miete", now: t0.addingTimeInterval(120))
        #expect(h.entries == ["Miete"])
        h.clear()
        #expect(h.entries.isEmpty)
    }

    @Test func persistsAcrossRestart() {
        let d = defaults()
        let h = SearchHistory(defaults: d)
        h.commit("Vertrag", now: t0)
        h.commit("Miete", now: t0.addingTimeInterval(60))
        h.limit = 20
        let r = SearchHistory(defaults: d)
        #expect(r.entries == ["Miete", "Vertrag"] && r.limit == 20 && r.isEnabled)
    }

    @Test func invalidStoredValuesFallBack() {
        let d = defaults()
        d.set("kein Array", forKey: "search.history")
        d.set(7, forKey: "search.historyLimit")
        let h = SearchHistory(defaults: d)
        #expect(h.entries.isEmpty && h.limit == 10)
        d.set(["  ", "A", "a", "B"] + (0..<200).map { "x\($0)" }, forKey: "search.history")
        let r = SearchHistory(defaults: d)
        #expect(Array(r.entries.prefix(2)) == ["A", "B"] && r.entries.count == 10, "cleaned and trimmed to the limit")
    }
}
