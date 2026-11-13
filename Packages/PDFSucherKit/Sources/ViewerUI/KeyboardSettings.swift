// KeyboardSettings.swift — 1.1 Task 6 (spec 1.1 §7, §9, §10)
import Foundation
import Observation

/// „Tippen sucht sofort“, „Tab überspringt das Suchfeld“ and the chosen shortcuts, persisted.
@MainActor @Observable public final class KeyboardSettings {
    enum Key {
        static let typeToSearch = "search.typeToSearch"
        static let tabSkipsSearch = "keyboard.tabSkipsSearch"
        static func shortcut(_ action: ShortcutAction) -> String { "shortcuts.\(action.rawValue)" }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedTypeToSearch: Bool
    private var storedTabSkipsSearch: Bool?
    private var shortcuts: [ShortcutAction: KeyShortcut]
    /// Set when switching on „Tippen sucht sofort“ put single-key shortcuts back to their defaults.
    public var lastResetNotice: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedTypeToSearch = defaults.object(forKey: Key.typeToSearch) == nil ? true : defaults.bool(forKey: Key.typeToSearch)
        storedTabSkipsSearch = defaults.object(forKey: Key.tabSkipsSearch) == nil ? nil : defaults.bool(forKey: Key.tabSkipsSearch)
        shortcuts = [:]
        // Each stored shortcut must still pass the rules against the ones loaded before it; else the default.
        for action in ShortcutAction.allCases {
            let stored = defaults.data(forKey: Key.shortcut(action)).flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
            if let stored, ShortcutValidator.validate(stored, for: action, current: shortcuts, typeToSearch: storedTypeToSearch) == nil {
                shortcuts[action] = stored
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    /// Spec §7: every printable key goes to the search field (default on).
    public var typeToSearch: Bool {
        get { storedTypeToSearch }
        set {
            storedTypeToSearch = newValue
            defaults.set(newValue, forKey: Key.typeToSearch)
            lastResetNotice = nil
            if newValue { resetSingleKeyShortcuts() }
        }
    }

    /// Spec §9: Tab moves only between preview and grid. Default follows „Tippen sucht sofort“ until set.
    public var tabSkipsSearch: Bool {
        get { storedTabSkipsSearch ?? storedTypeToSearch }
        set { storedTabSkipsSearch = newValue; defaults.set(newValue, forKey: Key.tabSkipsSearch) }
    }

    public func shortcut(for action: ShortcutAction) -> KeyShortcut { shortcuts[action] ?? action.defaultShortcut }

    public var all: [ShortcutAction: KeyShortcut] { shortcuts }

    /// Takes the shortcut if it passes the rules; otherwise returns why and keeps the old one.
    @discardableResult
    public func set(_ shortcut: KeyShortcut, for action: ShortcutAction) -> ShortcutRejection? {
        if let rejection = ShortcutValidator.validate(shortcut, for: action, current: shortcuts, typeToSearch: typeToSearch) {
            return rejection
        }
        store(shortcut, for: action)
        return nil
    }

    public func reset(_ action: ShortcutAction) {
        // The default may be taken by another action meanwhile: that one goes back to its default too, and
        // so on (defaults are distinct, so this ends).
        let value = action.defaultShortcut
        store(value, for: action)
        for other in ShortcutAction.allCases where other != action && shortcuts[other] == value { reset(other) }
    }

    public func resetAll() {
        lastResetNotice = nil
        for action in ShortcutAction.allCases { store(action.defaultShortcut, for: action) }
    }

    private func store(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        if shortcut == action.defaultShortcut {
            defaults.removeObject(forKey: Key.shortcut(action))
        } else if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Key.shortcut(action))
        }
    }

    private func resetSingleKeyShortcuts() {
        var notices: [String] = []
        for action in ShortcutAction.allCases {
            let s = shortcut(for: action)
            if !s.hasCommandControlOrOption, s.isPrintable {
                reset(action)
                notices.append("„\(action.title)“ wurde auf \(action.defaultShortcut.display) zurückgesetzt, weil „Tippen sucht sofort“ eingeschaltet ist.")
            }
        }
        if !notices.isEmpty { lastResetNotice = notices.joined(separator: " ") }
    }
}
