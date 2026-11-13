import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ViewerUI

/// Spec 1.1 §10/§13 UI: recorder, menu titles and entries.
@MainActor @Suite("Shortcut recorder and menus")
struct ShortcutRecorderTests {
    private func keyboard() -> KeyboardSettings { KeyboardSettings(defaults: UserDefaults(suiteName: "Rec-\(UUID())")!) }

    private func event(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    @Test func recorderRecordsAndSaves() {
        let k = keyboard()
        var recorder = ShortcutRecorderModel(action: .toggleTick)
        recorder.begin()
        #expect(recorder.isRecording)
        let outcome = recorder.handle(KeyShortcut(key: "t", modifiers: .control), isEscape: false, in: k)
        #expect(outcome == .recorded)
        #expect(!recorder.isRecording)
        #expect(recorder.message == nil)
        #expect(k.shortcut(for: .toggleTick) == KeyShortcut(key: "t", modifiers: .control))
    }

    @Test func recorderEscCancelsKeepingOld() {
        let k = keyboard()
        var recorder = ShortcutRecorderModel(action: .zoomIn)
        recorder.begin()
        #expect(recorder.handle(nil, isEscape: true, in: k) == .cancelled)
        #expect(!recorder.isRecording)
        #expect(k.shortcut(for: .zoomIn) == ShortcutAction.zoomIn.defaultShortcut)
    }

    @Test func recorderShowsRejectionAndKeepsOld() {
        let k = keyboard()
        var recorder = ShortcutRecorderModel(action: .zoomIn)
        recorder.begin()
        let outcome = recorder.handle(KeyShortcut(key: "o", modifiers: .command), isEscape: false, in: k)
        #expect(outcome == .rejected("Bereits belegt durch „Öffnen“"))
        #expect(recorder.message == "Bereits belegt durch „Öffnen“")
        #expect(recorder.isRecording)           // still listening for another key
        #expect(k.shortcut(for: .zoomIn) == ShortcutAction.zoomIn.defaultShortcut)
        #expect(recorder.handle(nil, isEscape: false, in: k) == .ignored)   // a modifier alone
    }

    @Test func keyShortcutFromEvent() {
        #expect(KeyShortcut(event: event("+", keyCode: 30, .command)) == KeyShortcut(key: "+", modifiers: .command))
        #expect(KeyShortcut(event: event("\r", keyCode: 36)) == KeyShortcut(key: "return", modifiers: []))
        #expect(KeyShortcut(event: event("\u{3}", keyCode: 76)) == KeyShortcut(key: "enter", modifiers: []))
        #expect(KeyShortcut(event: event("\u{F708}", keyCode: 96)) == KeyShortcut(key: "f5", modifiers: []))
        #expect(KeyShortcut(event: event("3", keyCode: 20, [.command, .shift])) == KeyShortcut(key: "3", modifiers: [.command, .shift]))
        #expect(KeyShortcut(event: event("T", keyCode: 17, [.control, .shift])) == KeyShortcut(key: "t", modifiers: [.control, .shift]))
        #expect(KeyShortcut(event: event(" ", keyCode: 49)) == KeyShortcut(key: "space", modifiers: []))
        #expect(KeyShortcut(event: event("\u{1b}", keyCode: 53)) == KeyShortcut(key: "escape", modifiers: []))
    }

    @Test func menuTitleShowsCurrentBinding() {
        #expect(ViewerText.menuTitle(.toggleTick, shortcut: KeyShortcut(key: "return", modifiers: [])) == "Häkchen setzen/entfernen (↩︎)")
        #expect(ViewerText.menuTitle(.toggleTick, shortcut: KeyShortcut(key: "t", modifiers: .control)) == "Häkchen setzen/entfernen")
    }

    @Test func menuHasZoomLevelEntries() {
        let k = keyboard()
        _ = k.set(KeyShortcut(key: "9", modifiers: .command), for: .zoomLevel2)
        let entries = ViewerCommands.viewMenu(k)
        #expect(entries.map(\.action) == [.zoomIn, .zoomOut, .fitPage, .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4])
        #expect(entries.map(\.title) == ["Vergrößern", "Verkleinern", "Ganze Seite", "Seitenbreite", "Zoom-Stufe 2", "Zoom-Stufe 3", "Zoom-Stufe 4"])
        #expect(entries[4].shortcut == KeyShortcut(key: "9", modifiers: .command))
        #expect(ViewerCommands.selectionMenu(k).map(\.title) == ["Häkchen setzen/entfernen (↩︎)"])
    }

    // MARK: Review of Task 7

    @Test func onlyOneRowRecordsAtATime() {
        var slot = RecordingSlot()
        slot.start(.zoomIn)
        slot.start(.fitPage)
        #expect(slot.active == .fitPage)
        #expect(!slot.isRecording(.zoomIn))
        slot.stop(.zoomIn)                // a stale stop of another row changes nothing
        #expect(slot.active == .fitPage)
        slot.stop(.fitPage)
        #expect(slot.active == nil)
    }

    @Test func recorderTakesOnlyKeysOfItsWindow() {
        let settings = NSWindow(), main = NSWindow()
        #expect(RecordingSlot.accepts(eventWindow: settings, recorderWindow: settings))
        #expect(!RecordingSlot.accepts(eventWindow: main, recorderWindow: settings))
        #expect(!RecordingSlot.accepts(eventWindow: nil, recorderWindow: settings))
        #expect(!RecordingSlot.accepts(eventWindow: settings, recorderWindow: nil))
    }

    @Test func unmappedFunctionKeysAreNotRecorded() {
        #expect(KeyShortcut(event: event("\u{F729}", keyCode: 115)) == nil)         // Home
        #expect(KeyShortcut(event: event("\u{F710}", keyCode: 105)) == nil)         // F13
    }

    @Test func shiftedPunctuationIsStoredUnshifted() {
        let e = event("*", keyCode: 30, [.command, .shift])
        let base = e.characters(byApplyingModifiers: [])
        let shortcut = KeyShortcut(event: e)
        if let base, base.count == 1, base != "*" {
            #expect(shortcut == KeyShortcut(key: base, modifiers: [.command, .shift]))
        }
    }

    @Test func resetNoticeClears() {
        let k = keyboard()
        k.typeToSearch = false
        _ = k.set(KeyShortcut(key: "x", modifiers: []), for: .toggleTick)
        k.typeToSearch = true
        #expect(k.lastResetNotice != nil)
        k.typeToSearch = false
        #expect(k.lastResetNotice == nil)
        k.typeToSearch = true
        k.lastResetNotice = "x"
        k.resetAll()
        #expect(k.lastResetNotice == nil)
    }
}
