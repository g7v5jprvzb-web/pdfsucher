import Foundation
import Testing
import ViewerUI
@testable import AppCore

/// Chris (Task 5.5): AppModel waits `GridSettings.debounceMs` after the last keystroke, unless a test
/// passes a fixed delay.
@MainActor @Suite("Typing delay")
struct DebounceTests {
    @Test func modelFollowsSetting() {
        let settings = makeSettings()
        let model = AppModel(settings: settings, defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), openIndex: { _ in FakeIndex() })
        #expect(model.typingDelay == .milliseconds(50))
        settings.debounceMs = 150
        #expect(model.typingDelay == .milliseconds(150))
    }

    @Test func fixedDelayWins() {
        let settings = makeSettings()
        settings.debounceMs = 150
        let model = makeModel(index: FakeIndex(), settings: settings)
        #expect(model.typingDelay == .zero)
    }
}
