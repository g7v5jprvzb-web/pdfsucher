import Foundation
import SwiftUI
import Testing
@testable import ViewerUI

/// Spec 1.1 §10 and §13: freely assignable shortcuts with validation.
@MainActor @Suite("Shortcuts")
struct ShortcutTests {
    private func keyboard(_ defaults: UserDefaults = UserDefaults(suiteName: "Keys-\(UUID())")!) -> KeyboardSettings {
        KeyboardSettings(defaults: defaults)
    }
    private let cmd: KeyShortcut.Modifiers = .command

    @Test func defaults() {
        let k = keyboard()
        #expect(k.shortcut(for: .zoomIn) == KeyShortcut(key: "+", modifiers: .command))
        #expect(k.shortcut(for: .zoomOut) == KeyShortcut(key: "-", modifiers: .command))
        #expect(k.shortcut(for: .fitPage) == KeyShortcut(key: "0", modifiers: .command))
        #expect(k.shortcut(for: .toggleTick) == KeyShortcut(key: "return", modifiers: []))
        #expect(k.shortcut(for: .zoomLevel1) == KeyShortcut(key: "1", modifiers: .command))
        #expect(k.shortcut(for: .zoomLevel4) == KeyShortcut(key: "4", modifiers: .command))
        #expect(k.typeToSearch)
        #expect(ShortcutAction.allCases.map(\.title) == ["Vergrößern", "Verkleinern", "Ganze Seite", "Häkchen setzen/entfernen",
                                                        "Seitenbreite", "Zoom-Stufe 2", "Zoom-Stufe 3", "Zoom-Stufe 4"])
    }

    @Test func persistAndReload() {
        let defaults = UserDefaults(suiteName: "Keys-\(UUID())")!
        let k = keyboard(defaults)
        #expect(k.set(KeyShortcut(key: "t", modifiers: .control), for: .toggleTick) == nil)
        #expect(defaults.data(forKey: "shortcuts.toggleTick") != nil)
        #expect(keyboard(defaults).shortcut(for: .toggleTick) == KeyShortcut(key: "t", modifiers: .control))
    }

    @Test func rejectsSinglePrintableWhenTypeToSearch() {
        let k = keyboard()
        let r = k.set(KeyShortcut(key: "x", modifiers: []), for: .toggleTick)
        #expect(r?.message == "Einzelne Tasten sind bei „Tippen sucht sofort“ nicht möglich. Bitte mit ⌘, ⌃ oder ⌥ kombinieren.")
        #expect(k.set(KeyShortcut(key: "x", modifiers: .shift), for: .toggleTick) != nil)
        #expect(k.set(KeyShortcut(key: "space", modifiers: []), for: .toggleTick) != nil)
        #expect(k.shortcut(for: .toggleTick) == KeyShortcut(key: "return", modifiers: []))
    }

    @Test func allowsSingleKeyWhenClassic() {
        let k = keyboard()
        k.typeToSearch = false
        #expect(k.set(KeyShortcut(key: "x", modifiers: []), for: .toggleTick) == nil)
        #expect(k.shortcut(for: .toggleTick) == KeyShortcut(key: "x", modifiers: []))
    }

    @Test func allowsReturnEnterAndFKeys() {
        let k = keyboard()
        #expect(k.set(KeyShortcut(key: "enter", modifiers: []), for: .toggleTick) == nil)
        #expect(k.set(KeyShortcut(key: "f5", modifiers: []), for: .fitPage) == nil)
        #expect(k.set(KeyShortcut(key: "f12", modifiers: .shift), for: .zoomLevel2) == nil)
    }

    @Test func rejectsReservedNavigationKeys() {
        let k = keyboard()
        k.typeToSearch = false
        for key in ["tab", "delete", "escape", "left", "right", "up", "down"] {
            #expect(k.set(KeyShortcut(key: key, modifiers: []), for: .toggleTick) != nil, "\(key)")
        }
    }

    @Test func rejectsDuplicateOfOtherAction() {
        let k = keyboard()
        let r = k.set(KeyShortcut(key: "+", modifiers: .command), for: .zoomOut)
        #expect(r?.message == "Bereits belegt durch „Vergrößern“")
        #expect(k.set(KeyShortcut(key: "1", modifiers: .command), for: .fitPage)?.message == "Bereits belegt durch „Seitenbreite“")
        #expect(k.set(KeyShortcut(key: "+", modifiers: .command), for: .zoomIn) == nil)   // its own key again
    }

    @Test(arguments: [("o", "Öffnen"), ("f", "Suchen"), ("p", "Drucken"), ("s", "Als PDF sichern"), ("q", "Beenden"),
                      ("w", "Fenster schließen"), (",", "Einstellungen"), ("[", "Vorherige Trefferseite"), ("]", "Nächste Trefferseite")])
    func rejectsEachFixedShortcut(key: String, title: String) {
        let k = keyboard()
        #expect(k.set(KeyShortcut(key: key, modifiers: .command), for: .zoomIn)?.message == "Bereits belegt durch „\(title)“")
    }

    @Test func rejectsSystemShortcuts() {
        let k = keyboard()
        let message = "Dieses Kürzel gehört zu macOS und kann nicht verwendet werden."
        #expect(k.set(KeyShortcut(key: "space", modifiers: .command), for: .zoomIn)?.message == message)
        #expect(k.set(KeyShortcut(key: "tab", modifiers: .command), for: .zoomIn)?.message == message)
        for digit in ["3", "4", "5"] {
            #expect(k.set(KeyShortcut(key: digit, modifiers: [.command, .shift]), for: .zoomIn)?.message == message)
        }
        #expect(k.set(KeyShortcut(key: "6", modifiers: [.command, .shift]), for: .zoomIn) == nil)
    }

    @Test func resetAndResetAll() {
        let k = keyboard()
        _ = k.set(KeyShortcut(key: "t", modifiers: .control), for: .toggleTick)
        _ = k.set(KeyShortcut(key: "9", modifiers: .command), for: .zoomLevel1)
        k.reset(.toggleTick)
        #expect(k.shortcut(for: .toggleTick) == ShortcutAction.toggleTick.defaultShortcut)
        #expect(k.shortcut(for: .zoomLevel1) == KeyShortcut(key: "9", modifiers: .command))
        k.resetAll()
        #expect(k.shortcut(for: .zoomLevel1) == ShortcutAction.zoomLevel1.defaultShortcut)
    }

    @Test func enablingTypeToSearchResetsSingleKey() {
        let k = keyboard()
        k.typeToSearch = false
        _ = k.set(KeyShortcut(key: "x", modifiers: []), for: .toggleTick)
        k.typeToSearch = true
        #expect(k.shortcut(for: .toggleTick) == KeyShortcut(key: "return", modifiers: []))
        #expect(k.lastResetNotice == "„Häkchen setzen/entfernen“ wurde auf ↩︎ zurückgesetzt, weil „Tippen sucht sofort“ eingeschaltet ist.")
    }

    @Test func invalidStoredShortcutFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "Keys-\(UUID())")!
        defaults.set(Data("kaputt".utf8), forKey: "shortcuts.zoomIn")
        defaults.set(try! JSONEncoder().encode(KeyShortcut(key: "x", modifiers: [])), forKey: "shortcuts.toggleTick")
        defaults.set(try! JSONEncoder().encode(KeyShortcut(key: "o", modifiers: .command)), forKey: "shortcuts.fitPage")
        let k = keyboard(defaults)
        #expect(k.shortcut(for: .zoomIn) == ShortcutAction.zoomIn.defaultShortcut)
        #expect(k.shortcut(for: .toggleTick) == ShortcutAction.toggleTick.defaultShortcut)   // type-to-search is on
        #expect(k.shortcut(for: .fitPage) == ShortcutAction.fitPage.defaultShortcut)         // a fixed shortcut
    }

    @Test func tabSkipsSearchDefaultFollowsTypeToSearchUntilSet() {
        let defaults = UserDefaults(suiteName: "Keys-\(UUID())")!
        let k = keyboard(defaults)
        #expect(k.tabSkipsSearch)
        k.typeToSearch = false
        #expect(!k.tabSkipsSearch)
        k.tabSkipsSearch = true
        k.typeToSearch = true
        k.typeToSearch = false
        #expect(k.tabSkipsSearch)
        #expect(defaults.bool(forKey: "keyboard.tabSkipsSearch"))
        #expect(defaults.object(forKey: "search.typeToSearch") != nil)
    }

    @Test func displayStrings() {
        #expect(KeyShortcut(key: "+", modifiers: .command).display == "⌘+")
        #expect(KeyShortcut(key: "-", modifiers: .command).display == "⌘−")
        #expect(KeyShortcut(key: "return", modifiers: []).display == "↩︎")
        #expect(KeyShortcut(key: "enter", modifiers: []).display == "⌅")
        #expect(KeyShortcut(key: "f5", modifiers: []).display == "F5")
        #expect(KeyShortcut(key: "t", modifiers: [.control, .option]).display == "⌃⌥T")
        #expect(KeyShortcut(key: "3", modifiers: [.command, .shift]).display == "⇧⌘3")
        #expect(KeyShortcut(key: "space", modifiers: .command).display == "⌘Leertaste")
    }

    @Test func menuShortcutOnlyWithModifier() {
        #expect(KeyShortcut(key: "+", modifiers: .command).keyboardShortcut != nil)
        #expect(KeyShortcut(key: "return", modifiers: []).keyboardShortcut == nil)
    }

    // MARK: Review of Task 6

    @Test func resetCascadesUntilUnique() {
        let k = keyboard()
        #expect(k.set(KeyShortcut(key: "9", modifiers: .command), for: .fitPage) == nil)
        #expect(k.set(KeyShortcut(key: "0", modifiers: .command), for: .zoomIn) == nil)
        #expect(k.set(KeyShortcut(key: "+", modifiers: .command), for: .zoomOut) == nil)
        k.reset(.fitPage)
        let values = ShortcutAction.allCases.map { k.shortcut(for: $0) }
        #expect(Set(values).count == values.count)
        #expect(k.shortcut(for: .fitPage) == ShortcutAction.fitPage.defaultShortcut)
    }

    nonisolated static let standardMenu: [(String, Int, String)] = [
        ("c", 1, "Kopieren"), ("v", 1, "Einsetzen"), ("x", 1, "Ausschneiden"), ("a", 1, "Alles auswählen"),
        ("z", 1, "Widerrufen"), ("z", 9, "Wiederholen"), ("h", 1, "PDFSucher ausblenden"), ("h", 5, "Andere ausblenden"),
        ("m", 1, "Im Dock ablegen"), ("f", 3, "Vollbild"),
    ]

    @Test(arguments: standardMenu)
    func rejectsStandardMenuShortcuts(key: String, modifiers: Int, title: String) {
        #expect(keyboard().set(KeyShortcut(key: key, modifiers: KeyShortcut.Modifiers(rawValue: modifiers)), for: .zoomIn)?.message == "Bereits belegt durch „\(title)“")
    }

    @Test func forceQuitIsSystem() {
        #expect(keyboard().set(KeyShortcut(key: "escape", modifiers: [.command, .option]), for: .zoomIn)?.message
                == "Dieses Kürzel gehört zu macOS und kann nicht verwendet werden.")
    }

    @Test func decodingNormalizesAndRejectsMalformedKeys() throws {
        let upper = try JSONDecoder().decode(KeyShortcut.self, from: Data(#"{"key":"A","modifiers":1}"#.utf8))
        #expect(upper == KeyShortcut(key: "a", modifiers: .command))
        let k = keyboard()
        k.typeToSearch = false
        #expect(k.set(KeyShortcut(key: "", modifiers: []), for: .toggleTick) != nil)
        #expect(k.set(KeyShortcut(key: "foo", modifiers: .command), for: .toggleTick) != nil)
    }

    /// Final review: ⌘= (and ⇧⌘=) mean ⌘+ for the router, so they conflict with it; ⌘? is Hilfe → Suchhilfe.
    @Test func zoomInAliasesAndHelpAreTaken() {
        let k = keyboard()
        #expect(k.set(KeyShortcut(key: "=", modifiers: .command), for: .zoomLevel1)?.message == "Bereits belegt durch „Vergrößern“")
        #expect(k.set(KeyShortcut(key: "=", modifiers: [.command, .shift]), for: .zoomLevel1)?.message == "Bereits belegt durch „Vergrößern“")
        #expect(k.set(KeyShortcut(key: "?", modifiers: .command), for: .zoomLevel1)?.message == "Bereits belegt durch „Suchhilfe“")
        #expect(k.set(KeyShortcut(key: "ß", modifiers: [.command, .shift]), for: .zoomLevel1)?.message == "Bereits belegt durch „Suchhilfe“")
    }
}
