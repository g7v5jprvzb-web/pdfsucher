import Testing
import AppKit
import Foundation
import PDFKit
import SwiftUI
import OutputKit
import SearchKit
import TestSupport
@testable import ViewerUI

@Suite("Views")
@MainActor
struct ViewTests {
#if DEBUG   // SampleViewerModel exists only in debug builds
    @Test func detailHighlightsOneSelectionPerRange() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("d.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Vertrag und noch ein Vertrag"])
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let selections = PDFPageView.selections(on: page, highlightRanges: SampleViewerModel.highlighter(ParsedQuery(terms: [])))
        #expect(selections.map { $0.string } == ["Vertrag", "Vertrag"])
        #expect(PDFPageView.selections(on: page, highlightRanges: nil).isEmpty)
    }

#endif
    @Test func detailLoadReportsMissingUnreadableAndReady() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let missing = await DetailDocument.load(dir.appendingPathComponent("gone.pdf"))
        #expect(missing == .missing)
        let fake = dir.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: fake)
        #expect(await DetailDocument.load(fake) == .unavailable)
        let real = dir.appendingPathComponent("real.pdf")
        try PDFFixtures.makePDF(at: real, pages: ["Vertrag"])
        guard case .ready(let document) = await DetailDocument.load(real) else {
            Issue.record("expected a loaded document"); return
        }
        #expect(document.pdf.pageCount == 1)
        #expect(document.url == real)
    }

    @Test func detailLoadReusesUnchangedDocument() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("d.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Vertrag"])
        guard case .ready(let first) = await DetailDocument.load(url) else { Issue.record("not loaded"); return }
        guard case .ready(let again) = await DetailDocument.load(url, reusing: first) else { Issue.record("not loaded"); return }
        #expect(again.pdf === first.pdf)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
        guard case .ready(let changed) = await DetailDocument.load(url, reusing: first) else { Issue.record("not loaded"); return }
        #expect(changed.pdf !== first.pdf)
    }

#if DEBUG
    /// Review of Task 5.4: with the columns slider the first toolbar line grew to ~1,090 pt and was
    /// clipped at the 960 pt minimum window width. Both lines must fit (12 pt padding on each side).
    @Test func toolbarLinesFitMinimumWindowWidth() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.ViewTests.\(UUID())")!))
        for mode in ColumnsMode.allCases {
            model.settings.columnsMode = mode
            model.settings.automaticColumns = 10
            let search = NSHostingView(rootView: SearchBar(model: model)).fittingSize.width
            let grid = NSHostingView(rootView: ViewControls(model: model)).fittingSize.width
            #expect(search <= ContentShell.minWidth - 24, "Suchleiste \(search) pt (\(mode))")
            #expect(grid <= ContentShell.minWidth - 24, "Darstellungszeile \(grid) pt (\(mode))")
        }
    }

    @Test func sampleModelHasThreeDocumentsWithSevenHitsEach() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.ViewTests.\(UUID())")!))
        #expect(model.hits.count == 3)
        #expect(model.hits.allSatisfy { $0.pageHits.count == 7 })
        #expect(model.summary == "Gefunden in 3 Dokumenten, 21 Seiten")
    }

    /// Writes docs/screenshots/viewer-sample.png when PDFSUCHER_SCREENSHOT=<repo root> is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_SCREENSHOT"] != nil))
    func renderScreenshot() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSUCHER_SCREENSHOT"]!)
        _ = NSApplication.shared
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.Screenshot.\(UUID())")!))
        let host = NSHostingView(rootView: ContentShell(model: model, highlighter: SampleViewerModel.highlighter))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(3))
        // A real window capture: PDFView's highlight layer does not show up in cacheDisplay.
        let out = root.appendingPathComponent("docs/screenshots/viewer-sample.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
        try shot.run()
        shot.waitUntilExit()
        #expect(shot.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: out.path))
        window.close()
    }
#endif
}
