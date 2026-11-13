import Testing
import Foundation
import SearchKit
@testable import ViewerUI

@Suite("GridSettings + GridLayout")
@MainActor
struct GridTests {
    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PDFSucher.GridTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func defaults() {
        withTempDefaults { d in
            let s = GridSettings(defaults: d)
            #expect(s.rows == 3)
            #expect(s.columns == 5)
            #expect(s.sort == .matchCount)
            #expect(s.partialWords == false)
        }
    }

    @Test func clampsValues() {
        withTempDefaults { d in
            let s = GridSettings(defaults: d)
            s.rows = 0
            s.columns = 11
            #expect(s.rows == 1)
            #expect(s.columns == 10)
            s.rows = -5
            s.columns = 100
            #expect(s.rows == 1)
            #expect(s.columns == 10)
        }
    }

    @Test func clampsStoredValuesOnLoad() {
        withTempDefaults { d in
            d.set(42, forKey: "grid.rows")
            d.set(0, forKey: "grid.columns")
            d.set("bogus", forKey: "grid.sort")
            let s = GridSettings(defaults: d)
            #expect(s.rows == 10)
            #expect(s.columns == 1)
            #expect(s.sort == .matchCount)
        }
    }

    @Test func readsLooselyTypedStoredValues() {
        withTempDefaults { d in
            d.set("4", forKey: "grid.rows")
            d.set(NSNumber(value: 6.0), forKey: "grid.columns")
            d.set("YES", forKey: "search.partialWords")
            let s = GridSettings(defaults: d)
            #expect(s.rows == 4)
            #expect(s.columns == 6)
            #expect(s.partialWords == true)
        }
    }

    @Test func persistsAcrossInstances() {
        withTempDefaults { d in
            let a = GridSettings(defaults: d)
            a.rows = 7
            a.columns = 2
            a.sort = .fileName
            a.partialWords = true
            let b = GridSettings(defaults: d)
            #expect(b.rows == 7)
            #expect(b.columns == 2)
            #expect(b.sort == .fileName)
            #expect(b.partialWords == true)
            #expect(d.integer(forKey: "grid.rows") == 7)
            #expect(d.string(forKey: "grid.sort") == "fileName")
            #expect(d.bool(forKey: "search.partialWords") == true)
        }
    }

    @Test func tileFitsCell() {
        let size = GridLayout.tileSize(available: CGSize(width: 1000, height: 600), rows: 3, columns: 5)
        #expect(size.width > 0 && size.height > 0)
        #expect(size.width <= (1000 - 4 * 8) / 5)
        #expect(size.height <= 600.0 / 3 - 24 - 8)
        #expect(abs(size.height / size.width - 1.414) < 0.01)
    }

    @Test func tileIsWidthBoundInTallSpace() {
        let size = GridLayout.tileSize(available: CGSize(width: 500, height: 5000), rows: 1, columns: 5)
        #expect(abs(size.width - (500 - 4 * 8) / 5) < 0.001)
        #expect(abs(size.height / size.width - 1.414) < 0.01)
    }

    @Test func tileNeverNegativeOrNaN() {
        for (avail, r, c) in [(CGSize.zero, 3, 5), (CGSize(width: 10, height: 10), 10, 10), (CGSize(width: 100, height: 100), 0, 0)] {
            let s = GridLayout.tileSize(available: avail, rows: r, columns: c)
            #expect(s.width >= 0 && s.height >= 0)
            #expect(!s.width.isNaN && !s.height.isNaN)
        }
    }
}
