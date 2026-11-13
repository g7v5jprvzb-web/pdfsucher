import Foundation
import Testing
@testable import ViewerUI

/// Chris (Task 5.5): the delay after typing is 50 ms by default; 150 ms can be chosen in the settings.
@Suite("Typing delay setting")
@MainActor
struct DebounceSettingTests {
    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PDFSucher.DebounceSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func defaultsTo50() {
        withTempDefaults { d in
            #expect(GridSettings(defaults: d).debounceMs == 50)
            #expect(GridSettings.debounceChoices == [50, 150])
        }
    }

    @Test func persists150() {
        withTempDefaults { d in
            GridSettings(defaults: d).debounceMs = 150
            #expect(d.integer(forKey: "search.debounceMs") == 150)
            #expect(GridSettings(defaults: d).debounceMs == 150)
        }
    }

    @Test func otherValuesFallBackTo50() {
        withTempDefaults { d in
            d.set(999, forKey: "search.debounceMs")
            #expect(GridSettings(defaults: d).debounceMs == 50)
            let s = GridSettings(defaults: d)
            s.debounceMs = 7
            #expect(s.debounceMs == 50)
            #expect(d.integer(forKey: "search.debounceMs") == 50)
        }
    }
}
