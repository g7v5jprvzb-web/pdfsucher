#if DEBUG
import AppKit
import IndexKit
import SwiftUI
import Testing
@testable import ViewerUI

/// 1.3 Teil B Task 12: the settings tab „Word/PowerPoint“.
@MainActor @Suite("Office settings")
struct OfficeSettingsTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "OfficeSettings-\(UUID().uuidString)")! }

    @Test func layoutCountsText() {
        #expect(ViewerText.layoutCounts(LayoutCounts(wordRead: 12, wordFailed: 1, powerpointRead: 30, waiting: 4))
                == "12 Word-Dateien gelesen, 1 nicht lesbar · 30 PowerPoint-Dateien gelesen · 4 warten")
        #expect(ViewerText.layoutCounts(LayoutCounts(wordRead: 1, powerpointFailed: 2, waiting: 1))
                == "1 Word-Datei gelesen · 2 PowerPoint-Dateien nicht lesbar · 1 wartet")
        #expect(ViewerText.layoutCounts(LayoutCounts(wordFailed: 1)) == "1 Word-Datei nicht lesbar")
        #expect(ViewerText.layoutCounts(LayoutCounts(powerpointRead: 1_234)) == "1.234 PowerPoint-Dateien gelesen")
        #expect(ViewerText.layoutCounts(LayoutCounts(waiting: 3)) == "3 warten")
        #expect(ViewerText.layoutCounts(LayoutCounts()) == "Keine Word- oder PowerPoint-Dateien")
    }

    /// Final review: the „Folien-Cache“ footer is right for both renderers; the file types footer names every format.
    @Test func slideCacheFooterFollowsTheRenderer() {
        #expect(ViewerText.slideCacheFooter(.quickLook) == "Nur für Quick Look: Folienbilder werden beim nächsten Durchlauf neu erzeugt.")
        #expect(ViewerText.slideCacheFooter(.slideKit)
                == "Der eigene Viewer braucht keine Folienbilder: Leeren gibt nur Speicherplatz frei (Bilder aus Quick Look).")
        // With the punctuation around each name, so ".doc" cannot be matched by ".docx".
        for ext in [".docx,", ".docm,", ".dotx,", ".doc,", ".pptx ", ".pptm "] {
            #expect(ViewerText.officeFormatsFooter.contains(ext), "\(ext)")
        }
    }

    @Test func officeTabShownOnlyWithPreferences() {
        let d = defaults()
        let without = SettingsView(settings: GridSettings(defaults: d), keyboard: KeyboardSettings(defaults: d),
                                   ocr: OCRPreferences(defaults: d))
        #expect(!without.shownTabs.contains(.office))
        let with = SettingsView(settings: GridSettings(defaults: d), keyboard: KeyboardSettings(defaults: d),
                                ocr: OCRPreferences(defaults: d), office: OfficePreferences(defaults: d))
        #expect(with.shownTabs == [.general, .preview, .appearance, .ocr, .office, .keyboard, .shortcuts])
        let all = SettingsView(settings: GridSettings(defaults: d), keyboard: KeyboardSettings(defaults: d),
                               ocr: OCRPreferences(defaults: d), onDeleteIndex: { _ in }, office: OfficePreferences(defaults: d))
        #expect(all.shownTabs == [.general, .preview, .appearance, .ocr, .office, .storage, .keyboard, .shortcuts],
                "„Speicher“ (folder-tree) with the index or the tile cache")
    }

    /// Renders the tab in a window and returns its AppKit controls.
    func controls(_ office: OfficePreferences, clear: (() async -> Void)? = nil) -> (window: NSWindow, views: [NSView]) {
        let tab = OfficeTab(office: office, folders: [URL(fileURLWithPath: "/a")], counts: { _ in LayoutCounts(wordRead: 1) },
                            onClearSlideCache: clear)
        let host = NSHostingView(rootView: tab)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsLayout.defaultContentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return (window, all(host))
    }

    @Test func toggleWritesPreference() throws {
        let d = defaults()
        let office = OfficePreferences(defaults: d)
        let (window, views) = controls(office)
        defer { window.close() }
        // The first control of the tab is the switch „Word- und PowerPoint-Dateien durchsuchen“ (grouped form → NSSwitch).
        let toggle = try #require(views.compactMap { $0 as? NSSwitch }.first)
        #expect(toggle.state == .on)
        toggle.performClick(nil)
        #expect(office.includeOffice == false)
        #expect(d.object(forKey: "office.include") as? Bool == false)
    }

    @Test func fontChoiceOnlyForTheOwnViewer() throws {
        let office = OfficePreferences(defaults: defaults())
        func popUp(_ views: [NSView], showing title: String) -> NSPopUpButton? {
            views.compactMap { $0 as? NSPopUpButton }.first { $0.title == title }
        }
        let own = controls(office)
        defer { own.window.close() }
        #expect(popUp(own.views, showing: "Eigener Viewer") != nil, "default: the own viewer")
        #expect(try #require(popUp(own.views, showing: "wie PowerPoint")).isEnabled)
        office.powerPointRenderer = .quickLook
        let ql = controls(office)
        defer { ql.window.close() }
        #expect(popUp(ql.views, showing: "Quick Look (macOS)") != nil)
        #expect(try #require(popUp(ql.views, showing: "wie PowerPoint")).isEnabled == false, "fonts only for the own viewer")
    }

    @Test func clearButtonCallsModel() async {
        let calls = Counter()
        let action = SlideCacheClearAction { await calls.increment(); try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!action.isRunning)
        let first = Task { await action.run() }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(action.isRunning, "the button is disabled while the cache is cleared")
        await action.run()                                  // a second click meanwhile: ignored
        await first.value
        #expect(!action.isRunning)
        #expect(await calls.value == 1)
        await action.run()
        #expect(await calls.value == 2)
    }

}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
#endif
