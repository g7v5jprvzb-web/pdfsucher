import AppKit
import Foundation
import PDFKit
import Testing
import TestSupport
@testable import ViewerUI

/// 1.3.2 Teil B: the preview's width follows the zoom (spec §8–§13). The scale comes from the reference width B
/// (the width the user set), never from the width shown right now, so nothing feeds back.
@MainActor @Suite("Preview width follows the zoom")
struct PreviewWidthTests {
    let a4 = CGSize(width: 595, height: 842)
    let reference = CGSize(width: 620, height: 900)      // B minus margin, the preview's height

    // MARK: scale from B

    @Test func scaleComesFromTheReferenceNotTheShownWidth() {
        let fractions = [100, 75, 50, 30]
        #expect(PreviewWidthMath.scale(.percent(50), fractions: fractions, page: a4, reference: reference) == 0.5)
        let level1 = PreviewWidthMath.scale(.pageWidth(level: 1), fractions: fractions, page: a4, reference: reference)
        #expect(abs(level1 * a4.width - 620) < 0.01, "⌘1 fills B")
        let level3 = PreviewWidthMath.scale(.pageWidth(level: 3), fractions: fractions, page: a4, reference: reference)
        #expect(abs(level3 * a4.width - 310) < 0.01, "⌘3: 50 % of B")
        let fit = PreviewWidthMath.scale(.fitPage, fractions: fractions, page: a4, reference: reference)
        #expect(abs(fit - min(620 / 595, 900 / 842)) < 0.0001, "the whole page in B × height")
    }

    // MARK: pane width

    @Test func paneWidthIsThePageWidthPlusMarginBetweenMinimumAndB() {
        let b: CGFloat = 640, margin: CGFloat = 20, minimum: CGFloat = 240
        #expect(PreviewWidthMath.paneWidth(page: a4, scale: 0.5, margin: margin, minimum: minimum, reference: b) == 318, "297.5 + 20, whole points")
        #expect(PreviewWidthMath.paneWidth(page: a4, scale: 0.25, margin: margin, minimum: minimum, reference: b) == 240, "minimum")
        #expect(PreviewWidthMath.paneWidth(page: a4, scale: 2, margin: margin, minimum: minimum, reference: b) == 640, "at most B")
        #expect(PreviewWidthMath.paneWidth(page: nil, scale: 0.5, margin: margin, minimum: minimum, reference: b) == 640, "no page: B")
    }

    @Test func largestScaleWithoutZoomBeyondTheWidth() {
        #expect(abs(PreviewWidthMath.maxScale(page: a4, referenceWidth: 620) - 620 / 595) < 0.0001)
        #expect(PreviewWidthMath.maxPercent(page: a4, referenceWidth: 620) == 104)
    }

    // MARK: zoom limit

    @Test func zoomInStopsAtThePageWidthWhenLimited() {
        let z = PreviewZoom()
        z.maxPercent = 104
        z.mode = .percent(75); z.currentPercent = 75
        z.zoomIn()
        #expect(z.mode == .percent(100))
        z.currentPercent = 100
        z.zoomIn()
        #expect(z.mode == .percent(104), "the rest up to the page width; level 1 may be set below 100 %")
        z.currentPercent = 104
        z.zoomIn()
        #expect(z.mode == .percent(104), "no further")
        #expect(!z.canZoomIn)
        z.maxPercent = nil
        #expect(z.canZoomIn, "zoom beyond the width allowed")
    }

    /// A stored or earlier percent above the limit (the switch turned off, a narrower pane) is shown as the limit,
    /// and zooming out starts below what is actually shown.
    @Test func percentAboveTheLimitIsShownAsTheLimit() {
        let z = PreviewZoom()
        z.mode = .percent(400); z.currentPercent = 150
        z.maxPercent = 150
        #expect(z.shownPercent == 150)
        #expect(!z.canZoomIn)
        z.zoomOut()
        #expect(z.mode == .percent(125))
    }

    // MARK: settings

    @Test func bothSwitchesAreKeptWithTheirDefaults() {
        let d = UserDefaults(suiteName: "PreviewWidth-\(UUID())")!
        let s = GridSettings(defaults: d)
        #expect(s.previewFollowsZoom && !s.previewZoomBeyondWidth)
        s.previewFollowsZoom = false
        s.previewZoomBeyondWidth = true
        let r = GridSettings(defaults: d)
        #expect(!r.previewFollowsZoom && r.previewZoomBeyondWidth)
    }

    // MARK: bundling

    @Test func manyStepsGiveOneWidthChange() async throws {
        var applied: [CGFloat] = []
        let bundler = WidthBundler(delay: .milliseconds(60)) { applied.append($0) }
        for w in stride(from: 600, through: 300, by: -30) { bundler.request(CGFloat(w)) }
        let deadline = ContinuousClock.now + .seconds(5)       // the main queue is shared with other tests
        while applied.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(150))           // nothing else follows
        #expect(applied == [300])
    }
}
