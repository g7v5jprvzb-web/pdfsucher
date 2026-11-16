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
    /// Tab also stops at the search field (Einstellungen → Tastatur; default off).
    let tabIncludesSearch: Bool
    /// Tab also stops at the preview (Einstellungen → Tastatur; default off).
    let tabIncludesPreview: Bool
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
    /// The folder bar's list has the keyboard (Ordnerleiste).
    var folderTreeFocused = false
    /// The folder bar is shown: its list is a Tab stop (computed for Tab only).
    var folderBarVisible = false
    /// The large preview is shown (⇧Tab can hide it, 1.3.6): only then is it a Tab stop.
    var previewVisible = true
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
    /// Tab into the folder bar's list (an AppKit view: the monitor makes it first responder).
    case focusFolderTree
    /// ⇧Tab (1.3.6, Chris): hide the folder bar, then also the preview, then show both again.
    case cycleLayout
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
        if s.key == "tab", s.modifiers == .shift, !context.fullKeyboardAccess { return .cycleLayout }
        if s.key == "tab", s.modifiers.isEmpty, !context.fullKeyboardAccess {
            let stops = tabStops(includesSearch: context.tabIncludesSearch, includesPreview: context.tabIncludesPreview,
                                 folderBarVisible: context.folderBarVisible, previewVisible: context.previewVisible)
            // The AppKit list wins: SwiftUI can still report the grid while the folder bar has the keyboard
            // (1.3.5, Tab from the bar then stayed in the bar).
            let current: TabStop? = if context.folderTreeFocused { .folders } else {
                switch context.focus {
                case .search: .search
                case .grid: .grid
                case .preview: .preview
                case nil: nil
                }
            }
            guard let current else { return .moveFocus(.grid) }
            switch nextStop(from: current, in: stops, backwards: false) {
            case .folders: return .focusFolderTree
            case .search: return .moveFocus(.search)
            case .grid: return .moveFocus(.grid)
            case .preview: return .moveFocus(.preview)
            }
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

    /// A place Tab can stop at, in the fixed order Suchfeld → Ordner → Kacheln → Vorschau.
    enum TabStop: CaseIterable, Equatable { case search, folders, grid, preview }

    /// The Tab cycle: the grid always; the folder bar while shown; search field and preview when switched on.
    /// Fewer than two stops (folder bar hidden, nothing switched on): the preview joins, so Tab never does nothing.
    static func tabStops(includesSearch: Bool, includesPreview: Bool, folderBarVisible: Bool, previewVisible: Bool = true) -> [TabStop] {
        var stops = TabStop.allCases.filter { stop in
            switch stop {
            case .search: includesSearch
            case .folders: folderBarVisible
            case .grid: true
            case .preview: includesPreview && previewVisible
            }
        }
        if stops.count < 2, previewVisible { stops.append(.preview) }
        return stops
    }

    /// ⇧Tab's layout cycle: both shown → folder bar hidden → preview hidden as well → both shown.
    static func nextLayout(folderBar: Bool, preview: Bool) -> (folderBar: Bool, preview: Bool) {
        if !preview { return (true, true) }
        return folderBar ? (false, true) : (false, false)
    }

    /// The next stop after `current`; a place outside the cycle (e.g. a click into the preview) goes on to the
    /// next stop of the cycle in the fixed order (backwards with ⇧Tab).
    static func nextStop(from current: TabStop, in stops: [TabStop], backwards: Bool) -> TabStop {
        let order = TabStop.allCases
        let step = backwards ? order.count - 1 : 1
        var i = order.firstIndex(of: current)!
        repeat {
            i = (i + step) % order.count
        } while !stops.contains(order[i])
        return order[i]
    }

    /// „Tab: Suchfeld → Ordner → Kacheln → Vorschau“ (settings, help).
    static func tabOrderText(_ stops: [TabStop]) -> String {
        "Tab: " + stops.map { stop in
            switch stop {
            case .search: "Suchfeld"
            case .folders: "Ordner"
            case .grid: "Kacheln"
            case .preview: "Vorschau"
            }
        }.joined(separator: " → ")
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
