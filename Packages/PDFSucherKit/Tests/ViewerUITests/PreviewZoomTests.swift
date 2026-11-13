import AppKit
import Foundation
import PDFKit
import Testing
import TestSupport
@testable import ViewerUI

/// Spec 1.1 §2 (zoom in the large preview) and §13 (levels ⌘1–⌘4 as fractions of the page width).
@MainActor @Suite("Preview zoom")
struct PreviewZoomTests {
    @Test func stepsAndBounds() {
        #expect(PreviewZoom.steps == [25, 50, 75, 100, 125, 150, 200, 300, 400, 600, 800])
        let z = PreviewZoom()
        z.mode = .percent(100)
        z.currentPercent = 100
        z.zoomIn()
        #expect(z.mode == .percent(125))
        z.mode = .percent(800); z.currentPercent = 800
        z.zoomIn()
        #expect(z.mode == .percent(800))
        z.mode = .percent(25); z.currentPercent = 25
        z.zoomOut()
        #expect(z.mode == .percent(25))
        z.fitPage()
        #expect(z.mode == .fitPage)
    }

    @Test func fitPageToNextStepAbove() {
        let z = PreviewZoom()
        z.currentPercent = 63          // reported by the view for „Ganze Seite“
        z.zoomIn()
        #expect(z.mode == .percent(75))
        z.mode = .fitPage
        z.zoomOut()
        #expect(z.mode == .percent(50))
        z.mode = .fitPage
        z.currentPercent = 1000        // huge window, tiny page
        z.zoomIn()
        #expect(z.mode == .fitPage)    // nothing above 800
        z.currentPercent = 10
        z.zoomOut()
        #expect(z.mode == .fitPage)
    }

    @Test func shownPercentFollowsTheView() {
        let z = PreviewZoom()
        z.currentPercent = 63
        #expect(z.shownPercent == 63)
        z.mode = .percent(200)
        #expect(z.shownPercent == 200)
    }

    @Test func pageWidthFactorForTwoSizesPortraitAndLandscape() {
        let portrait = CGSize(width: 595, height: 842), landscape = CGSize(width: 842, height: 595)
        #expect(abs(ZoomMath.pageWidthScale(fraction: 100, viewWidth: 595, page: portrait) - 1.0) < 0.0001)
        #expect(abs(ZoomMath.pageWidthScale(fraction: 100, viewWidth: 1190, page: portrait) - 2.0) < 0.0001)
        #expect(abs(ZoomMath.pageWidthScale(fraction: 50, viewWidth: 1190, page: portrait) - 1.0) < 0.0001)
        #expect(abs(ZoomMath.pageWidthScale(fraction: 100, viewWidth: 842, page: landscape) - 1.0) < 0.0001)
        #expect(abs(ZoomMath.pageWidthScale(fraction: 75, viewWidth: 421, page: landscape) - 0.375) < 0.0001)
        #expect(ZoomMath.rotatedSize(CGSize(width: 595, height: 842), rotation: 90) == CGSize(width: 842, height: 595))
        #expect(ZoomMath.rotatedSize(CGSize(width: 595, height: 842), rotation: 180) == CGSize(width: 595, height: 842))
        #expect(ZoomMath.pageWidthScale(fraction: 100, viewWidth: 0, page: portrait) > 0)    // never 0 or NaN
    }

    @Test func zoomLevelFractionsClampStepAndReset() {
        let defaults = UserDefaults(suiteName: "Zoom-\(UUID())")!
        let s = GridSettings(defaults: defaults)
        #expect(s.zoomLevelFractions == [100, 75, 50, 35])
        s.setZoomLevelFraction(2, to: 62)
        #expect(s.zoomLevelFractions == [100, 60, 50, 35])
        s.setZoomLevelFraction(4, to: 3)
        s.setZoomLevelFraction(1, to: 140)
        #expect(s.zoomLevelFractions == [100, 60, 50, 10])
        #expect(GridSettings(defaults: defaults).zoomLevelFractions == [100, 60, 50, 10])
        s.resetZoomLevels()
        #expect(s.zoomLevelFractions == [100, 75, 50, 35])
        defaults.set([1, 2], forKey: "preview.zoomLevels")
        #expect(GridSettings(defaults: defaults).zoomLevelFractions == [100, 75, 50, 35])
    }

    @Test func levelModeAndZoomFromALevel() {
        let z = PreviewZoom()
        z.setLevel(3)
        #expect(z.mode == .pageWidth(level: 3))
        z.currentPercent = 90
        z.zoomIn()
        #expect(z.mode == .percent(100))
    }

    /// The scale a mode gives on a real PDFView; changed fractions apply; a level follows the width.
    @Test func pdfViewScalesForMode() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("z.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Eins", "Zwei"])
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.document = document
        PDFPageView.apply(.percent(200), fractions: [100, 75, 50, 35], to: view, page: page)
        #expect(!view.autoScales)
        #expect(abs(view.scaleFactor - 2.0) < 0.001)
        PDFPageView.apply(.pageWidth(level: 1), fractions: [100, 75, 50, 35], to: view, page: page)
        let full = view.scaleFactor
        PDFPageView.apply(.pageWidth(level: 2), fractions: [100, 75, 50, 35], to: view, page: page)
        #expect(abs(view.scaleFactor - full * 0.75) < 0.01)
        PDFPageView.apply(.pageWidth(level: 2), fractions: [100, 40, 50, 35], to: view, page: page)
        #expect(abs(view.scaleFactor - full * 0.40) < 0.01)
        view.frame.size.width = 400
        PDFPageView.apply(.pageWidth(level: 1), fractions: [100, 75, 50, 35], to: view, page: page)
        #expect(view.scaleFactor < full * 0.6)
        PDFPageView.apply(.fitPage, fractions: [100, 75, 50, 35], to: view, page: page)
        #expect(view.autoScales)
    }

    /// §2: the zoom stays when the page changes; „Ganze Seite“ stays „Ganze Seite“.
    @Test func zoomSurvivesPageChange() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("z2.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Eins", "Zwei"])
        let document = try #require(PDFDocument(url: url))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.document = document
        PDFPageView.apply(.percent(200), fractions: GridSettings.defaultZoomLevels, to: view, page: document.page(at: 0)!)
        view.go(to: document.page(at: 1)!)
        PDFPageView.apply(.percent(200), fractions: GridSettings.defaultZoomLevels, to: view, page: document.page(at: 1)!)
        #expect(abs(view.scaleFactor - 2.0) < 0.001)
#if DEBUG
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Zoom-\(UUID())")!))
        model.previewZoom.mode = .percent(150)
        model.focusedPage = FocusNavigator.step(from: model.focusedPage, by: 1, hits: model.hits)
        #expect(model.previewZoom.mode == .percent(150))
        model.previewZoom.fitPage()
        model.focusedPage = FocusNavigator.step(from: model.focusedPage, by: 1, hits: model.hits)
        #expect(model.previewZoom.mode == .fitPage)
#endif
    }
}
