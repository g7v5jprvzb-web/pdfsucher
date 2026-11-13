import AppKit
import Foundation
import OutputKit
import SwiftUI
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Screenshots of the real window content (AppModel + real index + ContentShell + Highlighter)
/// without UI automation: a real window captured with `screencapture -l` (as in Phase 4).
/// Opt-in: `PDFSUCHER_APPSHOTS=$PWD/docs/screenshots scripts/test.sh --filter AppScreenshotTests`
@MainActor @Suite("App screenshots", .serialized)
struct AppScreenshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"] != nil))
    func screenshots() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Dokumente", isDirectory: true)
        try ScreenshotFixtures.make(in: folder)
        let indexURL = base.appendingPathComponent("index.sqlite")

        _ = NSApplication.shared
        let settings = GridSettings(defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!)
        let model = AppModel(settings: settings, defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!,
                             environment: NoEnvironment(), debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL) })
        await model.open(folder: folder)
        await model.waitUntilIdle()

        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1280, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "PDFSucher"
        window.contentView = NSHostingView(rootView: ContentShell(model: model, highlighter: Highlighter.make))
        window.orderFrontRegardless()

        func focusFirstHit(of name: String? = nil) {
            let hit = name.flatMap { n in model.hits.first { $0.url.lastPathComponent == n } } ?? model.hits.first
            if let hit { model.focusedPage = PageRef(url: hit.url, pageIndex: hit.pageHits[0].pageIndex) }
        }
        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(3))      // thumbnails render off the main actor
            let out = output.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "screencapture \(name)")
            #expect(FileManager.default.fileExists(atPath: out.path))
        }

        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.count == 5)
        focusFirstHit()
        settings.columnsMode = .fixed
        settings.columns = 5
        try await shoot("01-treffer-fest-5-seiten.png")

        settings.columnsMode = .automatic
        try await shoot("02-treffer-automatisch.png")
        settings.columnsMode = .fixed

        model.queryText = "Mietvertrag"
        await model.waitUntilIdle()
        focusFirstHit(of: "Uebergabeprotokoll.pdf")
        #expect(model.focusedPage?.url.lastPathComponent == "Uebergabeprotokoll.pdf")
        try await shoot("03-getrenntes-wort-markiert.png")
        window.close()
    }
}

@MainActor private final class NoEnvironment: AppEnvironment {
    func chooseSources() -> [URL] { [] }
    func chooseSaveLocation(defaultName: String) -> URL? { nil }
    func runPrint(_ operation: NSPrintOperation) {}
    func openInPreview(_ url: URL) {}
    func confirmDeleteIndex(question: String) -> Bool { false }
}
