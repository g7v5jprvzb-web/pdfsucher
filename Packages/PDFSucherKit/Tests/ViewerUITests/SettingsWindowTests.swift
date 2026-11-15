#if DEBUG
import AppKit
import IndexKit
import SwiftUI
import Testing
@testable import ViewerUI

/// 1.2.4 (Chris): every settings tab fits the default window without scrolling; the size is remembered.
@MainActor @Suite("Settings window")
struct SettingsWindowTests {
    /// The content height a tab's form needs at the default width, measured in a real window.
    ///
    /// Built as the app builds it (App/PDFSucherApp.swift): every optional part present (OCR, history, delete
    /// index, tile cache). 1.2.4 measured without `tileCache:` (848 pt) while the app passes `.standard`, and
    /// „Allgemein“ needed 985 pt there. `folders`: the number of folder sources (several add a picker).
    static func neededHeight(_ tab: SettingsTab, toolbarFont: Double? = nil, folders: Int = 1) -> CGFloat {
        let d = UserDefaults(suiteName: "SettingsWindow-\(UUID())")!
        let settings = GridSettings(defaults: d)
        settings.settingsTab = tab
        settings.toolbarFontSize = toolbarFont
        let tiles = TileDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsWindowTiles-\(UUID())", isDirectory: true))
        let view = SettingsView(settings: settings, keyboard: KeyboardSettings(defaults: d), ocr: OCRPreferences(defaults: d),
                                ocrCounts: { _ in nil }, onRerunOCR: { _ in },
                                folderSources: (0..<folders).map { URL(fileURLWithPath: "/Quelle \($0)") },
                                onDeleteIndex: { _ in }, history: SearchHistory(defaults: d),
                                office: OfficePreferences(defaults: d),
                                layoutCounts: { _ in LayoutCounts(wordRead: 12, wordFailed: 1, powerpointRead: 30, waiting: 4) },
                                onClearSlideCache: {}, tileCache: tiles)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsLayout.defaultContentSize),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        return scrolls(host).compactMap { $0.documentView?.frame.height }.max() ?? 0
    }

    /// Every tab with no, one and several folder sources (the app's configurations; several add a picker).
    @Test(arguments: SettingsTab.allCases, [0, 1, 5])
    func everyTabFitsTheDefaultSize(_ tab: SettingsTab, folders: Int) {
        let needed = Self.neededHeight(tab, folders: folders)
        #expect(needed > 50, "measured something for \(tab)")
        #expect(needed <= SettingsLayout.defaultContentSize.height - SettingsLayout.tabChrome,
                "\(tab) with \(folders) folders needs \(needed) pt of \(SettingsLayout.defaultContentSize.height - SettingsLayout.tabChrome)")
    }

    @Test func largeToolbarFontStillFits() {
        #expect(Self.neededHeight(.appearance, toolbarFont: 20) <= SettingsLayout.defaultContentSize.height - SettingsLayout.tabChrome)
    }

    @Test func sizeFollowsTheScreen() {
        #expect(SettingsLayout.defaultContentSize.width >= 640)
        let small = SettingsLayout.contentSize(forVisibleScreen: CGSize(width: 1280, height: 700))
        #expect(small.height == (700 * 0.85).rounded(.down))
        let large = SettingsLayout.contentSize(forVisibleScreen: CGSize(width: 2560, height: 1400))
        #expect(large == SettingsLayout.defaultContentSize)
    }

    /// The UI test found SwiftUI's settings window without `.resizable` (1.2.4 measured the main window): the
    /// keeper makes it resizable.
    @Test func theSettingsWindowBecomesResizable() async throws {
        let keeper = WindowFrameKeeper(load: { nil }, save: { _ in }, savesProgrammaticResizes: false, makesResizable: true)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 680, height: 920), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.clear.background(keeper))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        // The keeper's view exists only after a layout pass; it then queues its step on the main queue. Wait for
        // that step itself, not for a time: a block queued on the (serial, FIFO) main queue after the layout runs
        // after the keeper's. A deadline failed under load: in the parallel ViewerUI run the synchronous layout
        // measurements of `everyTabFitsTheDefaultSize` held the main thread 9–12 s in a row (sampled, 2026-11-14).
        host.layoutSubtreeIfNeeded()
        func hasKeeper(_ v: NSView) -> Bool { v is WindowFrameKeeper.HostView || v.subviews.contains(where: hasKeeper) }
        try #require(hasKeeper(host), "the keeper's view after the layout")
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(window.styleMask.contains(.resizable))
        window.close()
    }

    @Test func frameIsRemembered() {
        let d = UserDefaults(suiteName: "SettingsFrame-\(UUID())")!
        GridSettings(defaults: d).settingsWindowFrame = CGRect(x: 300, y: 200, width: 900, height: 950)
        #expect(GridSettings(defaults: d).settingsWindowFrame == CGRect(x: 300, y: 200, width: 900, height: 950))
    }
}
#endif
