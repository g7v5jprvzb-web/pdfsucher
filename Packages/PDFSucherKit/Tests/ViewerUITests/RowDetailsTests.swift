import Foundation
import Testing
import SearchKit
@testable import ViewerUI

/// 1.3.7: file size and modification date behind the file name, each switched on in the settings (default off).
@MainActor @Suite("Row details")
struct RowDetailsTests {
    private func hit(size: Int64?, modified: Date) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/tmp/Vertrag.pdf"), relativePath: "Vertrag.pdf", modifiedAt: modified,
                    pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/tmp"), pageCount: 3,
                    fileSize: size)
    }

    /// Formatters may put a non-breaking space before the unit.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private var date: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 12))!
    }

    @Test func offByDefaultAndPersisted() {
        let defaults = UserDefaults(suiteName: "RowDetails-\(UUID())")!
        let s = GridSettings(defaults: defaults)
        #expect(!s.showFileSize)
        #expect(!s.showModifiedDate)
        s.showFileSize = true
        s.showModifiedDate = true
        let again = GridSettings(defaults: defaults)
        #expect(again.showFileSize)
        #expect(again.showModifiedDate)
    }

    @Test func nothingWhenBothOff() {
        #expect(ViewerText.rowDetails(hit(size: 2_400_000, modified: date), showSize: false, showDate: false) == nil)
    }

    @Test func sizeAndDateInGerman() {
        let h = hit(size: 2_400_000, modified: date)
        #expect(plain(ViewerText.rowDetails(h, showSize: true, showDate: false)) == "2,4 MB")
        #expect(plain(ViewerText.rowDetails(h, showSize: false, showDate: true)) == "14.11.2026, 09:12")
        #expect(plain(ViewerText.rowDetails(h, showSize: true, showDate: true)) == "2,4 MB · 14.11.2026, 09:12")
    }

    @Test func unknownPartsAreLeftOut() {
        let h = hit(size: nil, modified: Date(timeIntervalSince1970: 0))
        #expect(ViewerText.rowDetails(h, showSize: true, showDate: true) == nil)
    }
}
