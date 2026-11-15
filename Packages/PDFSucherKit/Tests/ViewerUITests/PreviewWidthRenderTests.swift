#if DEBUG
import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import ViewerUI

/// 1.3.2 Teil B: screenshots of the preview beside the grid at several zooms, for a visual check (opt-in:
/// `PDFSUCHER_PREVIEW_SHOTS=<dir>`). Also checks that the preview gets narrower and the grid wider.
@MainActor @Suite("Preview width rendering", .serialized)
struct PreviewWidthRenderTests {
    func settle(_ host: NSView, _ seconds: Double = 0.6) async throws {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        host.layoutSubtreeIfNeeded()
    }

    /// The preview beside the grid in a real window: narrower when zoomed out, the same width with the switch off,
    /// and without zoom beyond the width a large percentage stops at the page width.
    @Test func paneFollowsTheZoomInARealWindow() async throws {
        let settings = GridSettings(defaults: UserDefaults(suiteName: "PreviewPane-\(UUID())")!)
        settings.previewPosition = .leading
        settings.setPreviewFraction(0.45, for: .leading)
        let model = SampleViewerModel(settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentShell(model: model, tileDisk: TileDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewPane-\(UUID())"))))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func pdfView() -> PDFView? {
            func find(_ v: NSView) -> PDFView? { (v as? PDFView) ?? v.subviews.lazy.compactMap(find).first }
            return find(host)
        }
        func width(after mode: PreviewZoom.Mode) async throws -> CGFloat {
            model.previewZoom.mode = mode
            try await settle(host, 1.0)
            return try #require(pdfView()).frame.width
        }
        try await settle(host, 1.5)
        let full = try await width(after: .pageWidth(level: 1))
        let half = try await width(after: .percent(50))
        #expect(half < full - 150, "50 %: \(half) pt, page width: \(full) pt")
        settings.previewFollowsZoom = false
        let fixed = try await width(after: .percent(50))
        #expect(abs(fixed - full) < 2, "switched off: the set width (\(fixed) of \(full))")
        settings.previewFollowsZoom = true
        _ = try await width(after: .percent(200))
        let view = try #require(pdfView())
        #expect(view.scaleFactor < 1.2, "without zoom beyond the width 200 % stops at the page width: \(view.scaleFactor)")
        #expect(model.previewZoom.maxPercent != nil && !model.previewZoom.canZoomIn)
    }

    /// Review of 1.3.2: with the width not following the zoom, a wider window widens the preview at once, every
    /// time (no bundling, no animation: before the fix the second resize waited 120 ms and then animated).
    @Test func fixedWidthFollowsTheWindowAtOnce() async throws {
        let settings = GridSettings(defaults: UserDefaults(suiteName: "PreviewFixed-\(UUID())")!)
        settings.previewPosition = .leading
        settings.setPreviewFraction(0.45, for: .leading)
        settings.previewFollowsZoom = false
        let model = SampleViewerModel(settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentShell(model: model, tileDisk: TileDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewFixed-\(UUID())"))))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func pdfView() -> PDFView? {
            func find(_ v: NSView) -> PDFView? { (v as? PDFView) ?? v.subviews.lazy.compactMap(find).first }
            return find(host)
        }
        try await settle(host, 1.5)
        var last = try #require(pdfView()).frame.width
        for width in [1400.0, 1600.0] {
            window.setContentSize(NSSize(width: width, height: 900))
            try await settle(host, 0.05)     // well below the 120 ms bundling
            let now = try #require(pdfView()).frame.width
            #expect(now > last + 50, "window \(width) pt: preview \(now) pt, before \(last) pt")
            last = now
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_PREVIEW_SHOTS"] != nil))
    func renderZooms() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSUCHER_PREVIEW_SHOTS"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = GridSettings(defaults: UserDefaults(suiteName: "PreviewShots-\(UUID())")!)
        settings.previewPosition = .leading
        settings.setPreviewFraction(0.45, for: .leading)
        let model = SampleViewerModel(settings: settings)
        let size = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: size, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentShell(model: model, tileDisk: TileDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewShots-\(UUID())"))))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        try await settle(host, 1.5)

        func shot(_ name: String) throws {
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
        }
        let steps: [(String, PreviewZoom.Mode, Bool)] = [
            ("vorschau-1-seitenbreite.png", .pageWidth(level: 1), false),
            ("vorschau-2-75.png", .percent(75), false),
            ("vorschau-3-50.png", .percent(50), false),
            ("vorschau-4-ueber-breite-200.png", .percent(200), true),
        ]
        for (name, mode, beyond) in steps {
            settings.previewZoomBeyondWidth = beyond
            model.previewZoom.mode = mode
            try await settle(host, beyond ? 1.0 : 0.6)
            // PDFView keeps the middle of the page when zooming; for the picture show the top left, where the text is.
            func pdfViews(_ v: NSView) -> [PDFView] { ((v as? PDFView).map { [$0] } ?? []) + v.subviews.flatMap(pdfViews) }
            if beyond, let view = pdfViews(host).first, let page = view.currentPage {
                view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: view.displayBox).maxY)))
                try await settle(host, 1.0)
            }
            try shot(name)
        }
        window.close()
    }
}
#endif
