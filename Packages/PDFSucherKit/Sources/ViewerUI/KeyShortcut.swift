// KeyShortcut.swift — 1.1 Task 6 (spec 1.1 §10 freely assignable shortcuts, §13 zoom levels)
import Foundation
import SwiftUI

/// A key with modifiers. `key` is the unshifted character of the key (letters lowercased), or a special
/// name: `return`, `enter` (⌅), `space`, `tab`, `delete`, `escape`, `left`, `right`, `up`, `down`, `f1`…`f12`.
/// Shift is a modifier like the others.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    /// Decoding goes through `init`, so stored keys are normalized too.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), modifiers: try c.decode(Modifiers.self, forKey: .modifiers))
    }

    static let specialNames: Set<String> = Set(["return", "enter", "space", "tab", "delete", "escape", "left", "right", "up", "down"])
        .union((1...12).map { "f\($0)" })

    var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }
    var hasCommandControlOrOption: Bool { !modifiers.isDisjoint(with: [.command, .control, .option]) }
    /// A key that types text: a character or the space bar.
    var isPrintable: Bool { key == "space" || !Self.specialNames.contains(key) }

    /// „⌃⌥⇧⌘“ + key, as macOS menus show it.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyDisplay
    }

    var keyDisplay: String {
        switch key {
        case "return": "↩︎"
        case "enter": "⌅"
        case "space": "Leertaste"
        case "tab": "⇥"
        case "delete": "⌫"
        case "escape": "⎋"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "-": "−"
        default: key.uppercased()
        }
    }

    /// For a menu item: only with ⌘, ⌃ or ⌥ (a plain key as menu key equivalent would also fire while
    /// typing in a text field); nil otherwise, the title then shows the key.
    public var keyboardShortcut: KeyboardShortcut? {
        guard hasCommandControlOrOption, let equivalent = keyEquivalent else { return nil }
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: mods)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "return": return .return
        case "enter": return KeyEquivalent("\u{3}")
        case "space": return .space
        case "tab": return .tab
        case "delete": return .delete
        case "escape": return .escape
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(0xF703 + n) {
                return KeyEquivalent(Character(scalar))      // NSF1FunctionKey = 0xF704
            }
            return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }
}

/// The actions whose shortcut the user can choose (Settings → „Tastenkürzel“).
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case zoomIn, zoomOut, fitPage, toggleTick, zoomLevel1, zoomLevel2, zoomLevel3, zoomLevel4

    public var title: String {
        switch self {
        case .zoomIn: "Vergrößern"
        case .zoomOut: "Verkleinern"
        case .fitPage: "Ganze Seite"
        case .toggleTick: "Häkchen setzen/entfernen"
        case .zoomLevel1: "Seitenbreite"
        case .zoomLevel2: "Zoom-Stufe 2"
        case .zoomLevel3: "Zoom-Stufe 3"
        case .zoomLevel4: "Zoom-Stufe 4"
        }
    }

    public var defaultShortcut: KeyShortcut {
        switch self {
        case .zoomIn: KeyShortcut(key: "+", modifiers: .command)
        case .zoomOut: KeyShortcut(key: "-", modifiers: .command)
        case .fitPage: KeyShortcut(key: "0", modifiers: .command)
        case .toggleTick: KeyShortcut(key: "return", modifiers: [])
        case .zoomLevel1: KeyShortcut(key: "1", modifiers: .command)
        case .zoomLevel2: KeyShortcut(key: "2", modifiers: .command)
        case .zoomLevel3: KeyShortcut(key: "3", modifiers: .command)
        case .zoomLevel4: KeyShortcut(key: "4", modifiers: .command)
        }
    }

    /// Zoom level 1…4 of the `zoomLevel` actions.
    public var zoomLevel: Int? {
        switch self {
        case .zoomLevel1: 1
        case .zoomLevel2: 2
        case .zoomLevel3: 3
        case .zoomLevel4: 4
        default: nil
        }
    }
}

/// Why a shortcut was not taken; `message` is shown under the recorder.
public struct ShortcutRejection: Equatable, Sendable {
    public let message: String
}

/// The rules of spec 1.1 §10.
public enum ShortcutValidator {
    /// Fixed menu shortcuts that cannot be reassigned.
    static let fixed: [(KeyShortcut, String)] = [
        (KeyShortcut(key: "o", modifiers: .command), "Öffnen"),
        (KeyShortcut(key: "f", modifiers: .command), "Suchen"),
        (KeyShortcut(key: "p", modifiers: .command), "Drucken"),
        (KeyShortcut(key: "s", modifiers: .command), "Als PDF sichern"),
        (KeyShortcut(key: "q", modifiers: .command), "Beenden"),
        (KeyShortcut(key: "w", modifiers: .command), "Fenster schließen"),
        (KeyShortcut(key: ",", modifiers: .command), "Einstellungen"),
        (KeyShortcut(key: "[", modifiers: .command), "Vorherige Trefferseite"),
        (KeyShortcut(key: "]", modifiers: .command), "Nächste Trefferseite"),
        // Standard app and edit menus (a binding would silently break copy and paste in the search field).
        (KeyShortcut(key: "c", modifiers: .command), "Kopieren"),
        (KeyShortcut(key: "v", modifiers: .command), "Einsetzen"),
        (KeyShortcut(key: "x", modifiers: .command), "Ausschneiden"),
        (KeyShortcut(key: "a", modifiers: .command), "Alles auswählen"),
        (KeyShortcut(key: "z", modifiers: .command), "Widerrufen"),
        (KeyShortcut(key: "z", modifiers: [.command, .shift]), "Wiederholen"),
        (KeyShortcut(key: "h", modifiers: .command), "PDFSucher ausblenden"),
        (KeyShortcut(key: "h", modifiers: [.command, .option]), "Andere ausblenden"),
        (KeyShortcut(key: "m", modifiers: .command), "Im Dock ablegen"),
        (KeyShortcut(key: "f", modifiers: [.command, .control]), "Vollbild"),
        // ⌘? (Hilfe → Suchhilfe): „?“ is ⇧ß on the German, ⇧/ on the US layout.
        (KeyShortcut(key: "?", modifiers: .command), "Suchhilfe"),
        (KeyShortcut(key: "ß", modifiers: [.command, .shift]), "Suchhilfe"),
        (KeyShortcut(key: "/", modifiers: [.command, .shift]), "Suchhilfe"),
    ]

    /// The router treats ⌘= and ⇧⌘= as ⌘+ (US layouts): compare them as ⌘+.
    static func canonical(_ s: KeyShortcut) -> KeyShortcut {
        if s.key == "=", s.modifiers == .command || s.modifiers == [.command, .shift] { return KeyShortcut(key: "+", modifiers: .command) }
        return s
    }

    static let system: Set<KeyShortcut> = [
        KeyShortcut(key: "space", modifiers: .command), KeyShortcut(key: "tab", modifiers: .command),
        KeyShortcut(key: "3", modifiers: [.command, .shift]), KeyShortcut(key: "4", modifiers: [.command, .shift]),
        KeyShortcut(key: "5", modifiers: [.command, .shift]),
        KeyShortcut(key: "escape", modifiers: [.command, .option]),      // Force Quit
    ]

    /// Keys that operate the window without modifiers (focus, editing, arrows) or cancel recording.
    static let reserved: Set<String> = ["tab", "delete", "escape", "left", "right", "up", "down"]

    public static func validate(_ shortcut: KeyShortcut, for action: ShortcutAction,
                                current: [ShortcutAction: KeyShortcut], typeToSearch: Bool) -> ShortcutRejection? {
        if shortcut.key.count != 1, !KeyShortcut.specialNames.contains(shortcut.key) {
            return ShortcutRejection(message: "Diese Taste kann nicht verwendet werden.")
        }
        if system.contains(shortcut) {
            return ShortcutRejection(message: "Dieses Kürzel gehört zu macOS und kann nicht verwendet werden.")
        }
        if !shortcut.hasCommandControlOrOption {
            if reserved.contains(shortcut.key) {
                return ShortcutRejection(message: "Diese Taste ist für die Bedienung reserviert (Tab, ⌫, Esc, Pfeiltasten). Bitte mit ⌘, ⌃ oder ⌥ kombinieren.")
            }
            if typeToSearch, shortcut.isPrintable {
                return ShortcutRejection(message: "Einzelne Tasten sind bei „Tippen sucht sofort“ nicht möglich. Bitte mit ⌘, ⌃ oder ⌥ kombinieren.")
            }
        }
        if let taken = fixed.first(where: { $0.0 == shortcut }) {
            return ShortcutRejection(message: "Bereits belegt durch „\(taken.1)“")
        }
        let key = canonical(shortcut)
        if let other = ShortcutAction.allCases.first(where: { $0 != action && current[$0].map(canonical) == key }) {
            return ShortcutRejection(message: "Bereits belegt durch „\(other.title)“")
        }
        return nil
    }
}
