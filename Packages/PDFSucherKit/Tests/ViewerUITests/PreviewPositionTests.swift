import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ViewerUI

/// Spec 1.1 §3: preview on top, left or right.
@MainActor @Suite("Preview position")
struct PreviewPositionTests {
    @Test func defaultTopAndPersists() {
        let defaults = UserDefaults(suiteName: "Pos-\(UUID())")!
        let s = GridSettings(defaults: defaults)
        #expect(s.previewPosition == .top)
        s.previewPosition = .trailing
        #expect(defaults.string(forKey: "layout.previewPosition") == "trailing")
        #expect(GridSettings(defaults: defaults).previewPosition == .trailing)
        #expect(PreviewPosition.allCases == [.top, .leading, .trailing])
    }

    @Test func invalidStoredValueIsTop() {
        let defaults = UserDefaults(suiteName: "Pos-\(UUID())")!
        defaults.set("diagonal", forKey: "layout.previewPosition")
        #expect(GridSettings(defaults: defaults).previewPosition == .top)
    }

#if DEBUG
    /// Side by side the grid computes its tiles from its own (narrower) width.
    @Test func sideBySideGridUsesItsOwnWidth() async throws {
        func columns(_ position: PreviewPosition) async -> Int {
            let settings = GridSettings(defaults: UserDefaults(suiteName: "Pos-\(UUID())")!)
            settings.columnsMode = .automatic
            settings.rows = 2
            settings.previewPosition = position
            let model = SampleViewerModel(settings: settings)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ContentShell(model: model).frame(width: 1280, height: 860))
            window.layoutIfNeeded()
            for _ in 0..<50 where settings.automaticColumns == 0 {
                try? await Task.sleep(for: .milliseconds(20))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            return settings.automaticColumns
        }
        let top = await columns(.top)
        let leading = await columns(.leading)
        let trailing = await columns(.trailing)
        #expect(top > 0)
        #expect(leading > 0 && leading < top, "leading \(leading), top \(top)")
        #expect(trailing > 0 && trailing < top, "trailing \(trailing), top \(top)")
    }
#endif
}
