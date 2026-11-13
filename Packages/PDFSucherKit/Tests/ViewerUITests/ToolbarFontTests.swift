import AppKit
import SwiftUI
import Testing
@testable import ViewerUI

/// 1.2.2 §2: font size of the toolbar, its persistence and the layout at 10–20 pt.
@MainActor @Suite("Toolbar font")
struct ToolbarFontTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "ToolbarFont-\(UUID())")! }

    @Test func toolbarFontPersistsAndClamps() {
        let d = defaults()
        let s = GridSettings(defaults: d)
        #expect(s.toolbarFontSize == nil && s.effectiveToolbarFontSize == 13)
        s.toolbarFontSize = 17.5
        #expect(GridSettings(defaults: d).toolbarFontSize == 17.5)
        s.toolbarFontSize = 30
        #expect(s.toolbarFontSize == 20)
        s.toolbarFontSize = 4
        #expect(s.toolbarFontSize == 10)
        s.resetToolbarFont()
        #expect(GridSettings(defaults: d).toolbarFontSize == nil)
        d.set(99.0, forKey: "toolbar.fontSize")
        #expect(GridSettings(defaults: d).toolbarFontSize == nil, "out of range stored value: system size")
    }

    @Test func controlSizeFollowsFont() {
        #expect(ToolbarScale.controlSize(10) == .small)
        #expect(ToolbarScale.controlSize(13) == .regular)
        #expect(ToolbarScale.controlSize(15) == .regular)
        #expect(ToolbarScale.controlSize(20) == .large)
    }

    @Test func flowWrapsAndNeverExceedsWidth() {
        let sizes = [CGSize(width: 300, height: 20), CGSize(width: 300, height: 30), CGSize(width: 300, height: 20)]
        #expect(ToolbarFlow.rows(sizes, width: 1000, spacing: 12) == [[0, 1, 2]])
        #expect(ToolbarFlow.rows(sizes, width: 700, spacing: 12) == [[0, 1], [2]])
        #expect(ToolbarFlow.rows(sizes, width: 200, spacing: 12) == [[0], [1], [2]], "an item wider than the line gets a line of its own")
        let flow = ToolbarFlow(spacing: 12, lineSpacing: 6)
        #expect(flow.size(for: sizes, width: 700) == CGSize(width: 612, height: 30 + 6 + 20))
    }

    /// Measured, not snapshot: the toolbar needs no more than the window's minimum content width.
    @Test(arguments: [10.0, 13.0, 20.0])
    func toolbarFitsAtMinimumWidth(_ size: Double) {
        let settings = GridSettings(defaults: defaults())
        settings.toolbarFontSize = size
        let model = SampleViewerModel(settings: settings)
        let available = ContentShell.minWidth - 2 * ContentShell.toolbarPadding
        let host = NSHostingController(rootView: ToolbarArea(model: model, search: SearchFieldHandle()))
        // Proposing almost nothing returns the least width the toolbar can live with (fixed-size items, the
        // search field at 180 pt): it must fit the window's minimum.
        let needed = host.sizeThatFits(in: CGSize(width: 50, height: 10_000))
        #expect(needed.width <= available + 0.5, "at \(size) pt the toolbar needs \(needed.width) of \(available) pt")
        let normal = NSHostingController(rootView: ToolbarArea(model: SampleViewerModel(settings: GridSettings(defaults: defaults())),
                                                               search: SearchFieldHandle())).sizeThatFits(in: CGSize(width: 50, height: 10_000))
        if size > 13 { #expect(needed.width > normal.width, "a larger font makes the controls wider") }
    }
}
