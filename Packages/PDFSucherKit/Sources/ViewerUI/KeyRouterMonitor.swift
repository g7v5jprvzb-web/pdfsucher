// KeyRouterMonitor.swift — 1.1 Task 8: applies `KeyRouting` decisions in the main window
import AppKit
import PDFKit
import SwiftUI

/// Applies a decision to the model and the focus.
@MainActor enum KeyRouterApplier {
    static func apply(_ decision: KeyDecision, to model: any ViewerModel,
                      setFocus: (FocusArea?) -> Void, focusSearch: () -> Void, openHistory: () -> Void = {}) {
        switch decision {
        case .passThrough: break
        case .perform(let action): model.perform(action)
        case .insert(let text): model.queryText += text
        case .deleteCharacter: model.queryText = SearchTextEditing.deletingLastCharacter(model.queryText)
        case .deleteWord: model.queryText = SearchTextEditing.deletingLastWord(model.queryText)
        case .clearSearch: model.queryText = ""
        case .focusSearchSelectingAll:
            // Only the AppKit field: clearing the SwiftUI focus as well would make SwiftUI take the first
            // responder back from the field (UI test). SwiftUI clears it itself when its view resigns.
            focusSearch()
        case .moveFocus(let area):
            if area == .search { focusSearch() } else { setFocus(area) }
        case .showHistory:
            openHistory()
        case .focusFolderTree:
            break                                           // the monitor does it (it has the window)
        case .cycleLayout:
            let next = KeyRouting.nextLayout(folderBar: model.folderBar.isVisible, preview: !model.settings.previewHidden)
            model.folderBar.isVisible = next.folderBar
            model.settings.previewHidden = !next.preview
            setFocus(.grid)                                 // the grid always stays: the focus goes there
        case .navigate(let direction):
            setFocus(.grid)
            // 1.3.3 (Chris): the search shows its first hit by itself; the first ↓ from the field enters the grid
            // on exactly that tile, so „type, ↓, Return“ ticks the first hit. Set again: now the user's choice.
            if direction == .down, model.focusIsAutomatic, let shown = model.focusedPage {
                model.focusedPage = shown
                model.noteSearchArrived()
                break
            }
            if let next = FocusNavigator.next(from: model.focusedPage, direction: direction, hits: model.hits,
                                              showAllPages: model.settings.showAllPages) {
                model.focusedPage = next
            }
        }
    }
}

/// The search field's AppKit view, so the monitor can tell whether it has the keyboard focus and give it.
@MainActor final class SearchFieldHandle {
    weak var field: NSTextField?
    /// The field got its focus from a click, ⌘F or Tab — not from the window at launch (1.2.1: ←/→ then
    /// move the caret instead of the grid).
    var focusIsExplicit = false
    /// Set just before an explicit focus change; the field reads it when it becomes first responder.
    var explicitFocusPending = false
    /// Opens the search history list (set by the history button; ⌥↓ calls it, 1.2.2 §1).
    var openHistory: (() -> Void)?

    /// The field's editor is the first responder of its window.
    var hasFocus: Bool {
        guard let field, let editor = field.window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    /// A click into the field counts as explicit even when its editor already had the startup focus (then
    /// the field does not become first responder again; review I3).
    func noteMouseDown(at locationInWindow: NSPoint, in window: NSWindow?) {
        guard let field, let window, field.window === window else { return }
        if field.convert(field.bounds, to: nil).contains(locationInWindow) { focusIsExplicit = true }
    }

    func focusSelectingAll() {
        guard let field, let window = field.window else { return }
        explicitFocusPending = true
        window.makeFirstResponder(field)
        explicitFocusPending = false
        field.currentEditor()?.selectAll(nil)
    }
}

/// Installs a key-down monitor for the window it is placed in (spec 1.1 §7, §9, §10).
struct KeyRouterInstaller: NSViewRepresentable {
    let model: any ViewerModel
    let search: SearchFieldHandle
    let focus: () -> FocusArea?
    let setFocus: (FocusArea?) -> Void

    final class HostView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    @MainActor final class Coordinator {
        var monitor: Any?
        var mouseMonitor: Any?
        weak var window: NSWindow?
        var route: ((NSEvent) -> NSEvent?)?
        var onMouseDown: ((NSEvent) -> Void)?

        func install(for window: NSWindow?) {
            self.window = window
            if monitor == nil, window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    self?.onMouseDown?(event)
                    return event
                }
            }
        }

        /// nil = the key was handled and must not reach AppKit (no second action, no beep).
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let route else { return event }
            return route(event)
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        let coordinator = context.coordinator
        view.onWindow = { coordinator.install(for: $0) }
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        let coordinator = context.coordinator
        let model = self.model, search = self.search, focus = self.focus, setFocus = self.setFocus
        coordinator.onMouseDown = { [weak coordinator] event in
            guard let window = coordinator?.window, event.window === window else { return }
            search.noteMouseDown(at: event.locationInWindow, in: window)
        }
        coordinator.route = { [weak coordinator] event in
            guard let window = coordinator?.window, event.window === window,
                  let shortcut = KeyShortcut(event: event) else { return event }
            let searchFocused = search.hasFocus
            let otherText = !searchFocused && window.firstResponder is NSText
            let editor = window.firstResponder as? NSTextView
            let dialogOpen = NSApp.modalWindow != nil || window.attachedSheet != nil || !window.isKeyWindow
            let context = KeyContext(typeToSearch: model.keyboard.typeToSearch, tabIncludesSearch: model.keyboard.tabIncludesSearch,
                                     tabIncludesPreview: model.keyboard.tabIncludesPreview,
                                     focus: searchFocused ? .search : focus(), otherTextFieldFocused: otherText,
                                     dialogOpen: dialogOpen, fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled,
                                     composing: editor?.hasMarkedText() == true,
                                     searchFocusIsExplicit: searchFocused && search.focusIsExplicit,
                                     responderTakesArrows: Self.responderTakesArrows(window.firstResponder, searchFocused: searchFocused),
                                     folderTreeFocused: window.firstResponder is NSTableView,     // the folder bar's list
                                     folderBarVisible: shortcut.key == "tab" && Self.folderTree(in: window) != nil,   // only for Tab: walks the views
                                     previewVisible: !model.settings.previewHidden,
                                     shortcuts: model.keyboard.all)
            let decision = KeyRouting.decide(KeyInput(shortcut: shortcut, characters: event.characters ?? ""), in: context)
            guard decision != .passThrough else { return event }
            if decision == .deleteWord, searchFocused, let editor {
                editor.deleteWordBackward(nil)          // in the field: at the caret, undoable
                return nil
            }
            if case .moveFocus(let area) = decision, area != .search, searchFocused {
                window.makeFirstResponder(nil)          // the field editor gives up the focus first
            }
            if decision == .cycleLayout {
                window.makeFirstResponder(nil)          // the folder list or the field gives up the keyboard first
            }
            if case .navigate = decision, searchFocused {
                window.makeFirstResponder(nil)
            }
            if decision == .focusFolderTree, let tree = Self.folderTree(in: window) {
                // Only the AppKit side: SwiftUI drops its own focus when its view resigns. Clearing it here
                // as well made SwiftUI resign the tree a moment later (1.3.5, Tab from the grid did nothing).
                window.makeFirstResponder(tree)
                return nil
            }
            KeyRouterApplier.apply(decision, to: model, setFocus: setFocus, focusSearch: { search.focusSelectingAll() },
                                   openHistory: { search.openHistory?() })
            return nil
        }
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.remove()
    }

    /// The folder bar's list (the only table view in the main window).
    static func folderTree(in window: NSWindow) -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor { return table }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// An AppKit control (not the search field) or the PDF view, or a view inside it, has the keyboard.
    static func responderTakesArrows(_ responder: NSResponder?, searchFocused: Bool) -> Bool {
        guard !searchFocused, let view = responder as? NSView else { return false }
        if view is NSControl { return true }
        var current: NSView? = view
        while let v = current {
            if v is PDFView { return true }
            current = v.superview
        }
        return false
    }
}

/// The search field as an AppKit text field whose editor does not accept dropped files: a file dropped
/// onto it goes to the window's drop target (adds a source) instead of typing its path (Task 3 review).
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let handle: SearchFieldHandle
    var toolTip: String?
    /// Return in the field (1.2.2 §1: the search arrived).
    var onSubmit: (() -> Void)?
    /// 1.2.2 §2: the toolbar's font size; nil = the system size.
    var fontSize: CGFloat?

    /// ⌄ and „?“ (symbols ≈ 1.2 × the font size), their spacing and the padding.
    nonisolated static func trailingInset(fontSize: CGFloat) -> CGFloat { max(42, (2 * fontSize * 1.2 + 9).rounded(.up)) }

    final class Field: NSTextField {
        weak var handle: SearchFieldHandle?

        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        /// A click (the window makes the field first responder before `mouseDown`), ⌘F or Tab is explicit;
        /// the window's own first responder at launch is not (1.2.1).
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became {
                let click = NSApp.currentEvent.map { $0.type == .leftMouseDown && $0.window === window } ?? false
                handle?.focusIsExplicit = click || (handle?.explicitFocusPending ?? false)
            }
            return became
        }
    }

    final class Cell: NSTextFieldCell {
        /// Room on the right for the „?“ button inside the field (spec 1.1 §11).
        /// Room on the right for ⌄ and „?“; grows with the toolbar font (review I3).
        var trailingInset: CGFloat = SearchTextField.trailingInset(fontSize: NSFont.systemFontSize)
        private static let editor: NSTextView = {
            let view = NoFileDropTextView()
            view.isFieldEditor = true
            return view
        }()
        override func fieldEditor(for controlView: NSView) -> NSTextView? { Self.editor }

        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            var r = super.drawingRect(forBounds: rect)
            r.size.width = max(r.size.width - trailingInset, 0)
            return r
        }

        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        }

        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        }

        private func inset(_ rect: NSRect) -> NSRect {
            var r = rect
            r.size.width = max(r.size.width - trailingInset, 0)
            return r
        }
    }

    /// Accepts text drags only; file URLs fall through to the window's drop handling.
    final class NoFileDropTextView: NSTextView {
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes.filter { $0 != .fileURL && $0.rawValue != "NSFilenamesPboardType" && $0 != .URL }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        init(text: Binding<String>) { self.text = text }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?() }
            return false                      // AppKit keeps its own Return handling
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = placeholder
        field.toolTip = toolTip
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.unregisterDraggedTypes()
        field.setAccessibilityIdentifier("searchField")
        handle.field = field
        field.handle = handle
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        let font = NSFont.systemFont(ofSize: fontSize ?? NSFont.systemFontSize)
        if field.font != font { field.font = font; field.invalidateIntrinsicContentSize() }
        if let cell = field.cell as? Cell, cell.trailingInset != Self.trailingInset(fontSize: font.pointSize) {
            cell.trailingInset = Self.trailingInset(fontSize: font.pointSize)
            field.needsDisplay = true
        }
        if field.stringValue != text {
            field.stringValue = text
            // Edited from outside (typing in the grid, ⌫, Esc): keep the caret at the end.
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
        handle.field = field
    }
}
