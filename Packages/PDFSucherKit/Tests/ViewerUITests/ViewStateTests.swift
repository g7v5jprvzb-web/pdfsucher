import CoreGraphics
import Foundation
import Testing
@testable import ViewerUI

/// 1.2.1 §2: window, splitter and view state are remembered; bad values fall back to the defaults.
@MainActor @Suite("View state")
struct ViewStateTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "ViewState-\(UUID())")! }

    @Test func viewStateRoundTrips() {
        let d = defaults()
        let s = GridSettings(defaults: d)
        s.mainWindowFrame = CGRect(x: 100, y: 80, width: 1300, height: 900)
        s.settingsWindowFrame = CGRect(x: 400, y: 300, width: 700, height: 900)
        s.settingsTab = .ocr
        s.setPreviewFraction(0.3, for: .top)
        s.setPreviewFraction(0.6, for: .leading)
        s.setPreviewFraction(0.25, for: .trailing)
        s.rows = 4; s.columns = 7; s.columnsMode = .automatic; s.headerFontSize = 20; s.sort = .fileName
        s.showAllPages = true; s.partialWords = true; s.previewPosition = .trailing
        let r = GridSettings(defaults: d)
        #expect(r.mainWindowFrame == CGRect(x: 100, y: 80, width: 1300, height: 900))
        #expect(r.settingsWindowFrame == CGRect(x: 400, y: 300, width: 700, height: 900))
        #expect(r.settingsTab == .ocr)
        #expect(r.previewFraction(for: .top) == 0.3)
        #expect(r.previewFraction(for: .leading) == 0.6)
        #expect(r.previewFraction(for: .trailing) == 0.25)
        #expect(r.rows == 4 && r.columns == 7 && r.columnsMode == .automatic && r.headerFontSize == 20 && r.sort == .fileName)
        #expect(r.showAllPages && r.partialWords && r.previewPosition == .trailing)
    }

    @Test func invalidValuesFallBack() {
        let d = defaults()
        d.set("kaputt", forKey: "window.main.frame")
        d.set("1 zwei 3 4", forKey: "window.settings.frame")
        d.set("nichtda", forKey: "settings.tab")
        d.set(7.5, forKey: "layout.split.top")
        d.set("x", forKey: "layout.split.leading")
        d.set("zoom:99", forKey: "preview.zoom")
        let s = GridSettings(defaults: d)
        #expect(s.mainWindowFrame == nil)
        #expect(s.settingsWindowFrame == nil)
        #expect(s.settingsTab == .general)
        #expect(s.previewFraction(for: .top) == SplitMath.maxFraction, "out of range is clamped")
        #expect(s.previewFraction(for: .leading) == SplitMath.defaultFraction(.leading))
        #expect(PreviewZoom(defaults: d).mode == .fitPage)
        d.set("0 0 10 10", forKey: "window.main.frame")
        #expect(GridSettings(defaults: d).mainWindowFrame == nil, "a frame below the minimum size is ignored")
    }

    @Test(arguments: [PreviewZoom.Mode.fitPage, .percent(150), .pageWidth(level: 3)])
    func zoomModeRoundTrips(_ mode: PreviewZoom.Mode) {
        let d = defaults()
        PreviewZoom(defaults: d).mode = mode
        #expect(PreviewZoom(defaults: d).mode == mode)
    }

    @Test func zoomOutOfRangeFallsBack() {
        let d = defaults()
        d.set("percent:5000", forKey: "preview.zoom")
        #expect(PreviewZoom(defaults: d).mode == .fitPage)
        d.set("level:9", forKey: "preview.zoom")
        #expect(PreviewZoom(defaults: d).mode == .fitPage)
    }

    @Test func onscreenFrameStays() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let frame = CGRect(x: 200, y: 100, width: 1280, height: 860)
        #expect(WindowPlacement.fitted(frame, visibleFrames: [screen]) == frame)
        // Partly off the right edge but the title bar is well visible: kept.
        let partly = CGRect(x: 2000, y: 100, width: 1280, height: 860)
        #expect(WindowPlacement.fitted(partly, visibleFrames: [screen]) == partly)
    }

    @Test func offscreenFrameComesBack() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Was on a second screen to the right that is gone.
        let gone = CGRect(x: 2000, y: 300, width: 1280, height: 860)
        let fitted = WindowPlacement.fitted(gone, visibleFrames: [main])
        #expect(main.contains(fitted))
        #expect(fitted.size == CGSize(width: 1280, height: 860))
        // Bigger than the screen: shrunk to it.
        let huge = CGRect(x: -3000, y: -2000, width: 3000, height: 2000)
        #expect(WindowPlacement.fitted(huge, visibleFrames: [main]) == main)
        // Only a sliver of the title bar visible: brought in.
        let sliver = CGRect(x: 1420, y: 0, width: 1000, height: 800)
        #expect(main.contains(WindowPlacement.fitted(sliver, visibleFrames: [main])))
    }

    /// Review M5: a remembered frame never ends up smaller than the window's minimum.
    @Test func fittedKeepsMinimumSize() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let small = CGRect(x: 100, y: 100, width: 500, height: 400)
        let fitted = WindowPlacement.fitted(small, visibleFrames: [screen], minSize: CGSize(width: 960, height: 560))
        #expect(fitted.size == CGSize(width: 960, height: 560))
        #expect(fitted.maxY == small.maxY, "grows downwards from the title bar")
    }

    /// Review I4: a remembered frame taller than the current screen (moved from a larger one) is shrunk.
    @Test func tooTallFrameIsShrunkToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 800)
        let tall = CGRect(x: 100, y: -300, width: 680, height: 1100)       // title bar on screen
        let fitted = WindowPlacement.fitted(tall, visibleFrames: [screen])
        #expect(fitted.height <= 800 && screen.contains(fitted))
    }

    @Test func splitFractionClamps() {
        // 1,000 pt total, preview at least 160, grid at least 160.
        #expect(SplitMath.previewLength(fraction: 0.4, total: 1000, minPreview: 160, minGrid: 160) == 400)
        #expect(SplitMath.previewLength(fraction: 0.01, total: 1000, minPreview: 160, minGrid: 160) == 160)
        #expect(SplitMath.previewLength(fraction: 0.99, total: 1000, minPreview: 160, minGrid: 160) == 840)
        #expect(SplitMath.previewLength(fraction: 0.5, total: 200, minPreview: 160, minGrid: 160) == 160, "too small: the preview keeps its minimum")
        #expect(SplitMath.fraction(previewLength: 300, total: 1000) == 0.3)
        #expect(SplitMath.clampFraction(.nan, for: .top) == SplitMath.defaultFraction(.top))
    }
}
