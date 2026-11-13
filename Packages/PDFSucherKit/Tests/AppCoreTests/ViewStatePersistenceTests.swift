import Foundation
import OutputKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// 1.2.1 §2: the preview zoom survives a restart; search text and ticks do not, the app starts browsing.
@MainActor @Suite("View state across restarts")
struct ViewStatePersistenceTests {
    @Test func zoomKeptSearchAndTicksNot() async {
        let defaults = UserDefaults(suiteName: "ViewStateApp-\(UUID().uuidString)")!
        let first = AppModel(settings: GridSettings(defaults: defaults), defaults: defaults, environment: FakeEnvironment(),
                             debounce: .zero, openIndex: { _ in FakeIndex() })
        first.previewZoom.setLevel(3)
        first.queryText = "Vertrag"
        first.selection.toggle(PageRef(url: URL(fileURLWithPath: "/tmp/a.pdf"), pageIndex: 0))
        await first.waitUntilIdle()
        let second = AppModel(settings: GridSettings(defaults: defaults), defaults: defaults, environment: FakeEnvironment(),
                              debounce: .zero, openIndex: { _ in FakeIndex() })
        #expect(second.previewZoom.mode == .pageWidth(level: 3))
        #expect(second.queryText.isEmpty, "starts browsing: empty search field")
        #expect(second.selection.count == 0)
    }
}
