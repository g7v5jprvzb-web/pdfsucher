// KeyRouting.swift — 1.1 Task 8 (spec 1.1 §7 type-to-search, §9 Tab, keyboard parts of §2/§10/§13)
import Foundation

/// The three keyboard areas of the main window.
public enum FocusArea: Hashable, Sendable { case search, preview, grid }

/// A key press: the shortcut it means (unshifted key + modifiers) and the text it types.
struct KeyInput: Equatable {
    let shortcut: KeyShortcut
    /// What the key types with its modifiers applied (e.g. „V“ for ⇧V, „@“ for ⌥L on a German layout).
    let characters: String
}

/// Where the key press happens.
struct KeyContext {
    let typeToSearch: Bool
    let tabSkipsSearch: Bool
    /// Keyboard focus in the main window; nil = none of the three areas.
    let focus: FocusArea?
    /// A text field other than the search field has the focus.
    let otherTextFieldFocused: Bool
    /// A sheet, alert, panel, popover or another window is in front.
    let dialogOpen: Bool
    /// macOS keyboard navigation („Tastaturnavigation“) is on: Tab keeps its system meaning.
    let fullKeyboardAccess: Bool
    /// The focused text view is composing (input method, dead key): every key belongs to it.
    var composing = false
    /// The search field got the focus on purpose (click, ⌘F, Tab), not from the window at launch: ←/→ then
    /// move the caret (1.2.1).
    var searchFocusIsExplicit = false
    /// No SwiftUI area is focused but an AppKit control or the PDF view has the keyboard and uses arrows
    /// itself (Full Keyboard Access on a toolbar control, a click into the preview; review I4).
    var responderTakesArrows = false
    let shortcuts: [ShortcutAction: KeyShortcut]
}

enum KeyDecision: Equatable {
    case passThrough
    case perform(ShortcutAction)
    case insert(String)
    case deleteCharacter, deleteWord, clearSearch, focusSearchSelectingAll
    case moveFocus(FocusArea)
    /// An arrow key from the search field or with no area focused: the grid gets the focus and moves
    /// (first hit page when nothing is focused yet).
    case navigate(FocusNavigator.Direction)
    /// ⌥↓ in the search field: the list of recent search terms (1.2.2 §1).
    case showHistory
}

/// What a key press does (pure; the monitor applies it). Rules: spec 1.1 §7, §9, §10.
enum KeyRouting {
    static let find = KeyShortcut(key: "f", modifiers: .command)
    static let arrows: [String: FocusNavigator.Direction] = ["left": .left, "right": .right, "up": .up, "down": .down]

    static func decide(_ input: KeyInput, in context: KeyContext) -> KeyDecision {
        guard !context.dialogOpen, !context.composing else { return .passThrough }
        let s = input.shortcut
        // Keyboard navigation with a toolbar control focused: Space and Return press that control.
        if context.fullKeyboardAccess, context.focus == nil, s.modifiers.isEmpty, s.key == "space" || s.key == "return" {
            return .passThrough
        }
        if s == find { return .focusSearchSelectingAll }
        guard !context.otherTextFieldFocused else { return .passThrough }
        let inSearch = context.focus == .search

        // Freely chosen shortcuts (⌘ combinations always; plain keys not while typing in the search field).
        if let action = ShortcutAction.allCases.first(where: { matches(context.shortcuts[$0] ?? $0.defaultShortcut, input) }) {
            let shortcut = context.shortcuts[action] ?? action.defaultShortcut
            if inSearch, !shortcut.hasCommandControlOrOption { return .passThrough }
            return .perform(action)
        }

        // After the chosen shortcuts, so one put on ⌥↓ still works (review M7).
        if s.key == "down", s.modifiers == .option, inSearch { return .showHistory }
        if s.key == "tab", s.modifiers.isSubset(of: .shift), !context.fullKeyboardAccess {
            return .moveFocus(nextFocus(from: context.focus, backwards: s.modifiers.contains(.shift), skipSearch: context.tabSkipsSearch))
        }
        if let direction = Self.arrows[s.key] {
            // 1.2.1: arrows reach the grid from the search field too (first start: nothing had moved the
            // focus into the grid, so ↓ after typing did nothing). Grid and preview handle them themselves.
            guard s.modifiers.isEmpty,
                  context.focus == .search || (context.focus == nil && !context.responderTakesArrows) else { return .passThrough }
            let horizontal = direction == .left || direction == .right
            if horizontal, context.focus == .search, context.searchFocusIsExplicit { return .passThrough }
            return .navigate(direction)
        }

        let typingModifiers = s.modifiers.isDisjoint(with: [.command, .control])
        if context.typeToSearch {
            if s.key == "escape", s.modifiers.isEmpty { return .clearSearch }
            if s.key == "delete" {
                if s.modifiers == .command || (s.modifiers == .option && !inSearch) { return .deleteWord }
                if s.modifiers.isEmpty, !inSearch { return .deleteCharacter }
                return .passThrough
            }
            guard !inSearch else { return .passThrough }
            if typingModifiers, s.isPrintable, !input.characters.isEmpty, !input.characters.unicodeScalars.contains(where: isControl) {
                return .insert(input.characters)
            }
            return .passThrough
        }

        // Classic: keys act on the focused element.
        guard !inSearch else { return .passThrough }
        if s.key == "space", s.modifiers.isEmpty, context.focus == .grid { return .perform(.toggleTick) }
        if typingModifiers, !s.modifiers.contains(.option) {
            if input.characters == "+" { return .perform(.zoomIn) }
            if input.characters == "-" { return .perform(.zoomOut) }
        }
        return .passThrough
    }

    /// The input means `shortcut`: the same key and modifiers; or the key's typed character with ⇧
    /// (⌘+ on a US layout is ⇧⌘=); or ⌘= for ⌘+ (the usual Mac zoom-in key where „+“ needs ⇧).
    static func matches(_ shortcut: KeyShortcut, _ input: KeyInput) -> Bool {
        let s = input.shortcut
        if shortcut == s { return true }
        let withoutShift = s.modifiers.subtracting(.shift)
        if s.modifiers.contains(.shift), shortcut.modifiers == withoutShift, shortcut.key == input.characters.lowercased() { return true }
        if shortcut.key == "+", s.key == "=", shortcut.modifiers == withoutShift, shortcut.hasCommandControlOrOption { return true }
        return false
    }

    static func nextFocus(from focus: FocusArea?, backwards: Bool, skipSearch: Bool) -> FocusArea {
        if skipSearch {
            switch focus {
            case .grid: return .preview
            case .preview: return .grid
            case .search: return backwards ? .preview : .grid
            case nil: return .grid
            }
        }
        let order: [FocusArea] = [.search, .preview, .grid]
        guard let focus, let i = order.firstIndex(of: focus) else { return backwards ? .grid : .search }
        return order[(i + (backwards ? order.count - 1 : 1)) % order.count]
    }

    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .control || (0xF700...0xF8FF).contains(u.value)
    }
}

/// Editing the search text from outside the field (⌫, ⌘⌫/⌥⌫ while the grid has the focus).
enum SearchTextEditing {
    static func deletingLastCharacter(_ text: String) -> String { String(text.dropLast()) }

    /// Trailing spaces plus the word before them.
    static func deletingLastWord(_ text: String) -> String {
        var t = Substring(text)
        while let last = t.last, last.isWhitespace { t = t.dropLast() }
        while let last = t.last, !last.isWhitespace { t = t.dropLast() }
        return String(t)
    }
}
