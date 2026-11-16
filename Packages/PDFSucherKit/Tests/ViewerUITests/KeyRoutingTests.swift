import AppKit
import Foundation
import PDFKit
import Testing
@testable import ViewerUI

/// Spec 1.1 §7 (type-to-search), §9 (Tab), §2/§10 keyboard parts: the pure key decision.
@Suite("Key routing")
struct KeyRoutingTests {
    private static let defaults: [ShortcutAction: KeyShortcut] =
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })

    private func context(typeToSearch: Bool = true, tabSearch: Bool = false, tabPreview: Bool = false, focus: FocusArea? = .grid, otherText: Bool = false,
                         dialog: Bool = false, fka: Bool = false, composing: Bool = false, searchExplicit: Bool = false, responderTakesArrows: Bool = false, folderTree: Bool = false, folderBar: Bool = false,
                         shortcuts: [ShortcutAction: KeyShortcut] = KeyRoutingTests.defaults) -> KeyContext {
        KeyContext(typeToSearch: typeToSearch, tabIncludesSearch: tabSearch, tabIncludesPreview: tabPreview, focus: focus,
                   otherTextFieldFocused: otherText, dialogOpen: dialog, fullKeyboardAccess: fka, composing: composing,
                   searchFocusIsExplicit: searchExplicit, responderTakesArrows: responderTakesArrows, folderTreeFocused: folderTree, folderBarVisible: folderBar,
                   shortcuts: shortcuts)
    }

    private func key(_ k: String, _ m: KeyShortcut.Modifiers = [], chars: String? = nil) -> KeyInput {
        let text = chars ?? (k == "space" ? " " : k.count == 1 ? k : "")
        return KeyInput(shortcut: KeyShortcut(key: k, modifiers: m), characters: text)
    }

    @Test func lettersAndSpaceFromGridAndPreviewGoToSearch() {
        for area in [FocusArea.grid, .preview] {
            #expect(KeyRouting.decide(key("v"), in: context(focus: area)) == .insert("v"))
            #expect(KeyRouting.decide(key("v", .shift, chars: "V"), in: context(focus: area)) == .insert("V"))
            #expect(KeyRouting.decide(key("space"), in: context(focus: area)) == .insert(" "))
            #expect(KeyRouting.decide(key("7"), in: context(focus: area)) == .insert("7"))
            #expect(KeyRouting.decide(key("l", .option, chars: "@"), in: context(focus: area)) == .insert("@"))
        }
        #expect(KeyRouting.decide(key("v"), in: context(focus: nil)) == .insert("v"))
        #expect(KeyRouting.decide(key("v"), in: context(focus: .search)) == .passThrough)   // the field types itself
    }

    @Test func noForwardingWhenDialogOrOtherTextField() {
        #expect(KeyRouting.decide(key("v"), in: context(dialog: true)) == .passThrough)
        #expect(KeyRouting.decide(key("v"), in: context(otherText: true)) == .passThrough)
        #expect(KeyRouting.decide(key("delete"), in: context(otherText: true)) == .passThrough)
        #expect(KeyRouting.decide(key("f", .command), in: context(dialog: true)) == .passThrough)
        #expect(KeyRouting.decide(key("return"), in: context(dialog: true)) == .passThrough)
    }

    @Test func backspaceVariants() {
        #expect(KeyRouting.decide(key("delete"), in: context()) == .deleteCharacter)
        #expect(KeyRouting.decide(key("delete", .command), in: context()) == .deleteWord)
        #expect(KeyRouting.decide(key("delete", .option), in: context()) == .deleteWord)
        #expect(KeyRouting.decide(key("delete", .command), in: context(focus: .search)) == .deleteWord)
        #expect(KeyRouting.decide(key("delete"), in: context(focus: .search)) == .passThrough)
        #expect(KeyRouting.decide(key("delete"), in: context(typeToSearch: false)) == .passThrough)
    }

    @Test func escClearsSearch() {
        #expect(KeyRouting.decide(key("escape"), in: context()) == .clearSearch)
        #expect(KeyRouting.decide(key("escape"), in: context(focus: .search)) == .clearSearch)
        #expect(KeyRouting.decide(key("escape"), in: context(typeToSearch: false)) == .passThrough)
    }

    @Test func returnTicksInBothModes() {
        #expect(KeyRouting.decide(key("return"), in: context()) == .perform(.toggleTick))
        #expect(KeyRouting.decide(key("return"), in: context(typeToSearch: false)) == .perform(.toggleTick))
        #expect(KeyRouting.decide(key("return"), in: context(focus: .search)) == .passThrough)
    }

    @Test func spaceTicksOnlyClassic() {
        #expect(KeyRouting.decide(key("space"), in: context(typeToSearch: false)) == .perform(.toggleTick))
        #expect(KeyRouting.decide(key("space"), in: context(typeToSearch: false, focus: .preview)) == .passThrough)
        #expect(KeyRouting.decide(key("space"), in: context()) == .insert(" "))
    }

    @Test func cmdFFocusesSearchInBothModes() {
        #expect(KeyRouting.decide(key("f", .command), in: context()) == .focusSearchSelectingAll)
        #expect(KeyRouting.decide(key("f", .command), in: context(typeToSearch: false)) == .focusSearchSelectingAll)
        #expect(KeyRouting.decide(key("f", .command), in: context(focus: .search)) == .focusSearchSelectingAll)
    }

    @Test func plusMinusZoomOnlyClassicAndNotInSearch() {
        #expect(KeyRouting.decide(key("+"), in: context(typeToSearch: false)) == .perform(.zoomIn))
        #expect(KeyRouting.decide(key("-"), in: context(typeToSearch: false, focus: .preview)) == .perform(.zoomOut))
        #expect(KeyRouting.decide(key("+"), in: context(typeToSearch: false, focus: .search)) == .passThrough)
        #expect(KeyRouting.decide(key("+"), in: context()) == .insert("+"))
    }

    @Test func cmdPlusZoomsAlways() {
        #expect(KeyRouting.decide(key("+", .command), in: context()) == .perform(.zoomIn))
        #expect(KeyRouting.decide(key("+", .command), in: context(focus: .search)) == .perform(.zoomIn))
        #expect(KeyRouting.decide(key("1", .command), in: context()) == .perform(.zoomLevel1))
        // US layout: ⌘+ is ⇧⌘= (produces „+“) and ⌘= is the usual zoom-in key.
        #expect(KeyRouting.decide(key("=", [.command, .shift], chars: "+"), in: context()) == .perform(.zoomIn))
        #expect(KeyRouting.decide(key("=", .command, chars: "="), in: context()) == .perform(.zoomIn))
    }

    @Test func reboundActionUsesNewNotOldKey() {
        var shortcuts = Self.defaults
        shortcuts[.toggleTick] = KeyShortcut(key: "t", modifiers: .control)
        #expect(KeyRouting.decide(key("t", .control), in: context(shortcuts: shortcuts)) == .perform(.toggleTick))
        #expect(KeyRouting.decide(key("return"), in: context(shortcuts: shortcuts)) == .passThrough)
        shortcuts[.zoomIn] = KeyShortcut(key: "f5", modifiers: [])
        #expect(KeyRouting.decide(key("f5"), in: context(shortcuts: shortcuts)) == .perform(.zoomIn))
        #expect(KeyRouting.decide(key("+", .command), in: context(shortcuts: shortcuts)) == .passThrough)
    }

    /// Default: Tab and ⇧Tab go between the folder bar and the grid only.
    @Test func tabOrderDefaultTreeAndGrid() {
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .grid, folderBar: true)) == .focusFolderTree)
        #expect(KeyRouting.decide(key("tab", .shift), in: context(focus: .grid, folderBar: true)) == .cycleLayout)
        let tree = context(focus: nil, responderTakesArrows: true, folderTree: true, folderBar: true)
        #expect(KeyRouting.decide(key("tab"), in: tree) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("tab", .shift), in: tree) == .cycleLayout)
        #expect(KeyRouting.decide(key("tab"), in: context(focus: nil, folderBar: true)) == .moveFocus(.grid), "nothing focused: the grid")
        // 1.3.5: SwiftUI still reports the grid while the folder list is first responder → the list counts.
        let stale = context(focus: .grid, responderTakesArrows: true, folderTree: true, folderBar: true)
        #expect(KeyRouting.decide(key("tab"), in: stale) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("tab", .shift), in: stale) == .cycleLayout)
        // Also with „Tippen sucht sofort“ off: the setting no longer decides the Tab order.
        #expect(KeyRouting.decide(key("tab"), in: context(typeToSearch: false, focus: .grid, folderBar: true)) == .focusFolderTree)
    }

    /// Everything switched on: Suchfeld → Ordner → Kacheln → Vorschau → Suchfeld.
    @Test func tabOrderAllFourStops() {
        let c = { (f: FocusArea?, tree: Bool) in context(tabSearch: true, tabPreview: true, focus: f, folderTree: tree, folderBar: true) }
        #expect(KeyRouting.decide(key("tab"), in: c(.search, false)) == .focusFolderTree)
        #expect(KeyRouting.decide(key("tab"), in: c(nil, true)) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("tab"), in: c(.grid, false)) == .moveFocus(.preview))
        #expect(KeyRouting.decide(key("tab"), in: c(.preview, false)) == .moveFocus(.search))
    }

    /// 1.3.6 (Chris): ⇧Tab hides the folder bar, then the preview as well, then shows both again.
    @Test func shiftTabCyclesTheLayout() {
        #expect(KeyRouting.nextLayout(folderBar: true, preview: true) == (false, true))
        #expect(KeyRouting.nextLayout(folderBar: false, preview: true) == (false, false))
        #expect(KeyRouting.nextLayout(folderBar: false, preview: false) == (true, true))
        #expect(KeyRouting.nextLayout(folderBar: true, preview: false) == (true, true))
        #expect(KeyRouting.decide(key("tab", .shift), in: context(focus: .grid, fka: true)) == .passThrough, "keyboard navigation: system Tab")
        // A hidden preview is no Tab stop, also not as the fallback with the folder bar hidden.
        #expect(KeyRouting.tabStops(includesSearch: false, includesPreview: true, folderBarVisible: false, previewVisible: false) == [.grid])
        var hidden = context(tabPreview: true, focus: .grid)
        hidden.previewVisible = false
        #expect(KeyRouting.decide(key("tab"), in: hidden) == .moveFocus(.grid))
    }


    @Test func tabFromSearchGoesToTheNextStop() {
        // In the cycle: on to the tree.
        #expect(KeyRouting.decide(key("tab"), in: context(tabSearch: true, focus: .search, folderBar: true)) == .focusFolderTree)
        // Not in the cycle (⌘F or a click put the focus there): on in the fixed order, ⇧Tab backwards.
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .search, folderBar: true)) == .focusFolderTree)
        #expect(KeyRouting.decide(key("tab", .shift), in: context(focus: .search, folderBar: true)) == .cycleLayout)
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .search)) == .moveFocus(.grid))
    }

    /// A click into the preview, which is not in the cycle: Tab goes on to the next stop after it.
    @Test func focusOutsideTheCycle() {
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .preview, folderBar: true)) == .focusFolderTree)
        #expect(KeyRouting.decide(key("tab", .shift), in: context(focus: .preview, folderBar: true)) == .cycleLayout)
        #expect(KeyRouting.decide(key("tab"), in: context(tabSearch: true, focus: .preview, folderBar: true)) == .moveFocus(.search))
    }

    /// Folder bar hidden and nothing switched on: Kacheln ↔ Vorschau, so Tab is never dead.
    @Test func folderBarHiddenFallsBackToThePreview() {
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .grid)) == .moveFocus(.preview))
        #expect(KeyRouting.decide(key("tab"), in: context(focus: .preview)) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("tab", .shift), in: context(focus: .grid)) == .cycleLayout)
        #expect(KeyRouting.decide(key("tab"), in: context(focus: nil)) == .moveFocus(.grid))
        // Search switched on: Suchfeld ↔ Kacheln, the preview stays out.
        #expect(KeyRouting.decide(key("tab"), in: context(tabSearch: true, focus: .grid)) == .moveFocus(.search))
        #expect(KeyRouting.decide(key("tab"), in: context(tabSearch: true, focus: .search)) == .moveFocus(.grid))
    }

    @Test func tabStopsAndText() {
        #expect(KeyRouting.tabStops(includesSearch: false, includesPreview: false, folderBarVisible: true) == [.folders, .grid])
        #expect(KeyRouting.tabStops(includesSearch: false, includesPreview: false, folderBarVisible: false) == [.grid, .preview])
        #expect(KeyRouting.tabStops(includesSearch: true, includesPreview: true, folderBarVisible: true) == [.search, .folders, .grid, .preview])
        #expect(KeyRouting.tabOrderText([.folders, .grid]) == "Tab: Ordner → Kacheln")
        #expect(KeyRouting.tabOrderText([.search, .folders, .grid, .preview]) == "Tab: Suchfeld → Ordner → Kacheln → Vorschau")
    }

    @Test func fullKeyboardAccessPassesTab() {
        #expect(KeyRouting.decide(key("tab"), in: context(fka: true)) == .passThrough)
    }

    /// The grid and the preview handle arrows themselves (grid: onKeyPress, preview: scrolling).
    @Test func arrowsPassThroughInGridAndPreview() {
        for area in [FocusArea.grid, .preview] {
            for arrow in ["left", "right", "up", "down"] {
                #expect(KeyRouting.decide(key(arrow), in: context(focus: area)) == .passThrough)
            }
        }
    }

    /// 1.2.1 bug (first start: folder added, word typed, ↓ did nothing): ↑/↓ from the search field or with
    /// no area focused move through the grid, in both keyboard modes.
    @Test func upDownFromSearchOrNoFocusNavigateTheGrid() {
        for typeToSearch in [true, false] {
            for focus in [FocusArea.search, nil] {
                for explicit in [true, false] {
                    let c = context(typeToSearch: typeToSearch, focus: focus, searchExplicit: explicit)
                    #expect(KeyRouting.decide(key("down"), in: c) == .navigate(.down))
                    #expect(KeyRouting.decide(key("up"), in: c) == .navigate(.up))
                }
            }
        }
    }

    /// ←/→ go to the grid unless the search field was focused on purpose (click, ⌘F, Tab): then they move the caret.
    @Test func leftRightFromSearchDependOnHowItGotTheFocus() {
        #expect(KeyRouting.decide(key("left"), in: context(focus: .search)) == .navigate(.left))
        #expect(KeyRouting.decide(key("right"), in: context(focus: nil)) == .navigate(.right))
        #expect(KeyRouting.decide(key("right"), in: context(focus: .search, searchExplicit: true)) == .passThrough)
        #expect(KeyRouting.decide(key("left"), in: context(focus: .search, searchExplicit: true)) == .passThrough)
    }

    /// Review I4: with no SwiftUI area focused, an AppKit control or the PDF view that has the keyboard keeps
    /// its arrows (Full Keyboard Access on a toolbar control, a click into the preview).
    @Test func arrowsStayWithAControlOrThePDFView() {
        for arrow in ["left", "right", "up", "down"] {
            #expect(KeyRouting.decide(key(arrow), in: context(focus: nil, responderTakesArrows: true)) == .passThrough)
        }
    }

    /// 1.2.2 §1: ⌥↓ in the search field opens the history; elsewhere it does nothing special.
    @Test func optionDownInSearchShowsHistory() {
        #expect(KeyRouting.decide(key("down", .option), in: context(focus: .search)) == .showHistory)
        #expect(KeyRouting.decide(key("down", .option), in: context(typeToSearch: false, focus: .search)) == .showHistory)
        #expect(KeyRouting.decide(key("down", .option), in: context(focus: .grid)) == .passThrough)
        #expect(KeyRouting.decide(key("down", .option), in: context(focus: .search, otherText: true)) == .passThrough)
        #expect(KeyRouting.decide(key("down"), in: context(focus: .search)) == .navigate(.down))
    }

    /// Review M7: a custom shortcut on ⌥↓ still wins.
    @Test func customShortcutOnOptionDownWins() {
        var shortcuts = KeyRoutingTests.defaults
        shortcuts[.zoomIn] = KeyShortcut(key: "down", modifiers: .option)
        #expect(KeyRouting.decide(key("down", .option), in: context(focus: .search, shortcuts: shortcuts)) == .perform(.zoomIn))
    }

    /// Review I3: the room for ⌄ and ? in the search field grows with the toolbar font.
    @Test func searchFieldInsetGrowsWithFont() {
        #expect(SearchTextField.trailingInset(fontSize: 13) >= 40)
        #expect(SearchTextField.trailingInset(fontSize: 20) >= 2 * 20 * 1.2 + 9)
    }

    /// Ordnerleiste: Tab from the tree goes on to the grid; arrows stay in the tree; letters still type into
    /// the search field.
    @Test func folderTreeKeys() {
        let tree = context(focus: nil, responderTakesArrows: true, folderTree: true, folderBar: true)
        #expect(KeyRouting.decide(key("tab"), in: tree) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("down"), in: tree) == .passThrough)
        #expect(KeyRouting.decide(key("v"), in: tree) == .insert("v"))
        #expect(KeyRouting.decide(key("tab"), in: context(focus: nil, fka: true, folderTree: true)) == .passThrough)
    }

    /// With the preview switched on, the tree is in the cycle: Ordner → Kacheln → Vorschau → Ordner.
    @Test func tabCycleIncludesTheTree() {
        #expect(KeyRouting.decide(key("tab"), in: context(tabPreview: true, focus: .preview, folderBar: true)) == .focusFolderTree)
        #expect(KeyRouting.decide(key("tab", .shift), in: context(tabPreview: true, focus: .grid, folderBar: true)) == .cycleLayout)
        let tree = context(tabPreview: true, focus: nil, responderTakesArrows: true, folderTree: true, folderBar: true)
        #expect(KeyRouting.decide(key("tab"), in: tree) == .moveFocus(.grid))
        #expect(KeyRouting.decide(key("tab", .shift), in: tree) == .cycleLayout)
    }

    /// Arrows with modifiers keep their text meaning in the field (⇧← selects, ⌘→ goes to the end).
    @Test func arrowsWithModifiersStayInTheField() {
        for m: KeyShortcut.Modifiers in [.shift, .command, .option] {
            // 1.2.2: ⌥↓ opens the search history instead (optionDownInSearchShowsHistory).
            if m != .option { #expect(KeyRouting.decide(key("down", m), in: context(focus: .search)) == .passThrough) }
            #expect(KeyRouting.decide(key("up", m), in: context(focus: .search)) == .passThrough)
            #expect(KeyRouting.decide(key("left", m), in: context(focus: .search)) == .passThrough)
        }
    }

    // MARK: Review of Task 8

    /// Composing text (IME, dead keys in the field): every key belongs to the input method.
    @Test func composingPassesEverything() {
        for k in ["escape", "delete", "return", "tab", "v"] {
            #expect(KeyRouting.decide(key(k), in: context(focus: .search, composing: true)) == .passThrough, "\(k)")
        }
        #expect(KeyRouting.decide(key("delete", .command), in: context(focus: .search, composing: true)) == .passThrough)
    }

    /// macOS keyboard navigation with a toolbar control focused: Space and Return press the control.
    @Test func fullKeyboardAccessLeavesSpaceAndReturnToControls() {
        #expect(KeyRouting.decide(key("space"), in: context(focus: nil, fka: true)) == .passThrough)
        #expect(KeyRouting.decide(key("return"), in: context(focus: nil, fka: true)) == .passThrough)
        #expect(KeyRouting.decide(key("return"), in: context(focus: .grid, fka: true)) == .perform(.toggleTick))
        #expect(KeyRouting.decide(key("v"), in: context(focus: nil, fka: true)) == .insert("v"))
    }

    @Test func deletingLastWordCases() {
        #expect(SearchTextEditing.deletingLastWord("Miete Kündigung") == "Miete ")
        #expect(SearchTextEditing.deletingLastWord("Miete  ") == "")
        #expect(SearchTextEditing.deletingLastWord("Miete") == "")
        #expect(SearchTextEditing.deletingLastWord("") == "")
        #expect(SearchTextEditing.deletingLastCharacter("Vertrag") == "Vertra")
        #expect(SearchTextEditing.deletingLastCharacter("") == "")
        #expect(SearchTextEditing.deletingLastCharacter("Café") == "Caf")
    }
}

#if DEBUG
/// Applying a decision to the model (the monitor's part that does not need a window).
@MainActor @Suite("Key routing applied")
struct KeyRoutingApplyTests {
    @Test func applyingDecisionsEditsModel() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Apply-\(UUID())")!))
        var focus: FocusArea? = .grid
        var searchRequests = 0
        let apply = { (d: KeyDecision) in
            KeyRouterApplier.apply(d, to: model, setFocus: { focus = $0 }, focusSearch: { searchRequests += 1 })
        }
        model.queryText = "Miete"
        apply(.insert(" K"))
        #expect(model.queryText == "Miete K")
        apply(.deleteCharacter)
        #expect(model.queryText == "Miete ")
        model.queryText = "Miete Kündigung"
        apply(.deleteWord)
        #expect(model.queryText == "Miete ")
        apply(.clearSearch)
        #expect(model.queryText == "")
        let page = model.focusedPage!
        apply(.perform(.toggleTick))
        #expect(model.selection.contains(page))
        apply(.perform(.zoomLevel2))
        #expect(model.previewZoom.mode == .pageWidth(level: 2))
        apply(.moveFocus(.preview))
        #expect(focus == .preview)
        apply(.focusSearchSelectingAll)
        #expect(searchRequests == 1)
        #expect(focus == .preview)          // the SwiftUI focus is left alone (it follows the first responder)
        apply(.moveFocus(.search))
        #expect(searchRequests == 2)
        #expect(focus == .preview)
    }
    /// 1.2.1: an arrow from the search field gives the grid the focus and selects the first hit page.
    @Test func navigateFocusesGridAndSelectsFirstPage() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Apply-\(UUID())")!))
        model.focusedPage = nil
        var focus: FocusArea? = .search
        KeyRouterApplier.apply(.navigate(.down), to: model, setFocus: { focus = $0 }, focusSearch: {})
        #expect(focus == .grid)
        #expect(model.focusedPage == FocusNavigator.next(from: nil, direction: .down, hits: model.hits))
        #expect(model.focusedPage != nil)
        let first = model.focusedPage
        KeyRouterApplier.apply(.navigate(.right), to: model, setFocus: { focus = $0 }, focusSearch: {})
        #expect(model.focusedPage == FocusNavigator.next(from: first, direction: .right, hits: model.hits))
    }

    /// 1.3.3 (Chris: „Erst auf den ersten Treffer“): the search shows its first hit by itself, the keyboard is
    /// still in the field. The first ↓ enters the grid on exactly that tile (preview unchanged, an arrival for the
    /// history, now the user's choice), so „type, ↓, Return“ ticks the first hit as before; the next ↓ moves on.
    @Test func firstDownEntersTheGridOnTheAutomaticFirstHit() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Apply-\(UUID())")!))
        #expect(model.hits.count >= 2)
        let first = FocusNavigator.firstHit(in: model.hits)
        model.focusedPage = first
        model.focusIsAutomatic = true
        var focus: FocusArea? = .search
        KeyRouterApplier.apply(.navigate(.down), to: model, setFocus: { focus = $0 }, focusSearch: {})
        #expect(focus == .grid)
        #expect(model.focusedPage == first)
        #expect(!model.focusIsAutomatic, "now the user's choice")
        #expect(model.arrivals == 1)
        KeyRouterApplier.apply(.navigate(.down), to: model, setFocus: { focus = $0 }, focusSearch: {})
        #expect(model.focusedPage?.url == model.hits.first(where: { $0.url != first?.url && !$0.pageHits.isEmpty })?.url)
    }

    /// A page the user chose (or none chosen automatically): ↓ from the field moves on as before 1.3.3.
    @Test func downFromAChosenPageGoesToTheNextDocument() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Apply-\(UUID())")!))
        let first = FocusNavigator.firstHit(in: model.hits)
        model.focusedPage = first
        model.focusIsAutomatic = false
        KeyRouterApplier.apply(.navigate(.down), to: model, setFocus: { _ in }, focusSearch: {})
        #expect(model.focusedPage != first)
        #expect(model.focusedPage == FocusNavigator.next(from: first, direction: .down, hits: model.hits))
    }

    /// Only ↓ enters on the shown tile; the other arrows navigate from it as before.
    @Test func otherArrowsNavigateFromTheAutomaticFirstHit() {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "Apply-\(UUID())")!))
        let first = FocusNavigator.firstHit(in: model.hits)
        model.focusedPage = first
        model.focusIsAutomatic = true
        KeyRouterApplier.apply(.navigate(.right), to: model, setFocus: { _ in }, focusSearch: {})
        #expect(model.focusedPage == FocusNavigator.next(from: first, direction: .right, hits: model.hits))
    }
}

/// The monitor must swallow a routed key (review of Task 8: it handed every event back to AppKit).
@MainActor @Suite("Key router monitor")
struct KeyRouterMonitorTests {
    private func event(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    /// Review I4: which first responders keep their arrows.
    @Test func respondersThatTakeArrows() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let pdf = PDFView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let inside = NSView(frame: .zero)
        pdf.addSubview(inside)
        window.contentView?.addSubview(pdf)
        #expect(KeyRouterInstaller.responderTakesArrows(NSSegmentedControl(), searchFocused: false))
        #expect(KeyRouterInstaller.responderTakesArrows(pdf, searchFocused: false))
        #expect(KeyRouterInstaller.responderTakesArrows(inside, searchFocused: false))
        #expect(!KeyRouterInstaller.responderTakesArrows(window, searchFocused: false))
        #expect(!KeyRouterInstaller.responderTakesArrows(window.contentView, searchFocused: false))
        #expect(!KeyRouterInstaller.responderTakesArrows(nil, searchFocused: false))
        #expect(!KeyRouterInstaller.responderTakesArrows(NSTextView(), searchFocused: true), "the search field's editor")
    }

    /// Review I3: a click into the search field counts as explicit even when it already had the startup focus.
    @Test func clickIntoFieldIsExplicit() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 20, y: 300, width: 300, height: 24))
        window.contentView?.addSubview(field)
        let handle = SearchFieldHandle()
        handle.field = field
        handle.noteMouseDown(at: NSPoint(x: 500, y: 100), in: window)
        #expect(!handle.focusIsExplicit, "a click elsewhere changes nothing")
        handle.noteMouseDown(at: NSPoint(x: 100, y: 310), in: window)
        #expect(handle.focusIsExplicit)
    }

    /// Tab into the tree finds the folder bar's list; a hidden one does not count.
    @Test func findsTheFolderTree() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(KeyRouterInstaller.folderTree(in: window) == nil)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let outline = NSOutlineView()
        scroll.documentView = outline
        window.contentView?.addSubview(scroll)
        #expect(KeyRouterInstaller.folderTree(in: window) === outline)
        scroll.isHidden = true
        #expect(KeyRouterInstaller.folderTree(in: window) == nil)
    }

    @Test func routedKeyIsSwallowedOthersPass() {
        let coordinator = KeyRouterInstaller.Coordinator()
        let routed = event("v", keyCode: 9)
        coordinator.route = { _ in nil }
        #expect(coordinator.handle(routed) == nil)
        coordinator.route = { $0 }
        #expect(coordinator.handle(routed) === routed)
        coordinator.route = nil
        #expect(coordinator.handle(routed) === routed)
    }
}
#endif
