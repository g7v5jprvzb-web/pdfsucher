import CoreGraphics
import Foundation
import Testing
@testable import ViewerUI

/// Spec 1.1 §1: row headers 16 pt bold, adjustable 12–28 pt in 2 pt steps.
@MainActor @Suite("Row header font")
struct HeaderFontTests {
    private func settings(_ defaults: UserDefaults = UserDefaults(suiteName: "HeaderFont-\(UUID())")!) -> GridSettings {
        GridSettings(defaults: defaults)
    }

    @Test func defaultIs16() {
        #expect(settings().headerFontSize == 16)
    }

    @Test func clampsTo12And28() {
        let s = settings()
        s.headerFontSize = 4
        #expect(s.headerFontSize == 12)
        s.headerFontSize = 99
        #expect(s.headerFontSize == 28)
        s.headerFontSize = 15
        #expect(s.headerFontSize == 14)
        let defaults = UserDefaults(suiteName: "HeaderFont-\(UUID())")!
        defaults.set(27, forKey: "grid.headerFontSize")
        #expect(settings(defaults).headerFontSize == 26)
    }

    @Test func stepsByTwoAndStopsAtBounds() {
        let s = settings()
        s.increaseHeaderFont()
        #expect(s.headerFontSize == 18)
        for _ in 0..<20 { s.increaseHeaderFont() }
        #expect(s.headerFontSize == 28)
        #expect(!s.canIncreaseHeaderFont)
        for _ in 0..<20 { s.decreaseHeaderFont() }
        #expect(s.headerFontSize == 12)
        #expect(!s.canDecreaseHeaderFont)
    }

    @Test func persistsUnderKey() {
        let defaults = UserDefaults(suiteName: "HeaderFont-\(UUID())")!
        let s = settings(defaults)
        s.headerFontSize = 22
        #expect(defaults.integer(forKey: "grid.headerFontSize") == 22)
        #expect(settings(defaults).headerFontSize == 22)
    }

    @Test func overheadGrowsWithFont() {
        #expect(DocumentRow.headerHeight(fontSize: 16) >= 24)
        #expect(DocumentRow.overhead(fontSize: 28) > DocumentRow.overhead(fontSize: 16))
        #expect(DocumentRow.overhead(fontSize: 16) > DocumentRow.overhead(fontSize: 12))
    }

    @Test func automaticMetricsUseHeaderHeight() {
        let available = CGSize(width: 600, height: 600)   // narrow: the 10-per-row cap does not apply
        let small = GridLayout.metrics(available: available, rows: 3, columns: 5, mode: .automatic,
                                       rowHeader: DocumentRow.overhead(fontSize: 12))
        let large = GridLayout.metrics(available: available, rows: 3, columns: 5, mode: .automatic,
                                       rowHeader: DocumentRow.overhead(fontSize: 28))
        #expect(large.tileSize.height < small.tileSize.height)
    }
}
