// ShortcutRecorder.swift — 1.1 Task 7 (spec 1.1 §10 „Tastenkürzel“, §13 levels)
import AppKit
import SwiftUI

extension KeyShortcut {
    private static let specialKeyCodes: [UInt16: String] = [
        36: "return", 76: "enter", 49: "space", 48: "tab", 51: "delete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    /// Digit row: with ⇧ the digit itself (⌘⇧3 stays „3“ on every layout).
    private static let digitKeyCodes: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]

    /// The shortcut a key press means; nil for a press without a usable key (e.g. only a modifier).
    public init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if let special = Self.specialKeyCodes[event.keyCode] {
            self.init(key: special, modifiers: modifiers)
        } else if modifiers.contains(.shift), let digit = Self.digitKeyCodes[event.keyCode] {
            self.init(key: digit, modifiers: modifiers)
        } else if var chars = event.charactersIgnoringModifiers, chars.count == 1 {
            // With ⇧ the key's own (unshifted) character: ⇧⌘+ stays „+“ with ⇧, not „*“.
            if modifiers.contains(.shift), let base = event.characters(byApplyingModifiers: []), base.count == 1 { chars = base }
            // Home, End, F13 … (private-use characters) are not supported.
            guard let scalar = chars.unicodeScalars.first, !(0xF700...0xF8FF).contains(scalar.value),
                  scalar.properties.generalCategory != .control else { return nil }
            self.init(key: chars.lowercased(), modifiers: modifiers)
        } else {
            return nil
        }
    }
}

/// State of one recorder field: click, press a key; Esc cancels; a rejected key shows why and keeps listening.
struct ShortcutRecorderModel: Equatable {
    enum Outcome: Equatable { case recorded, rejected(String), cancelled, ignored }

    let action: ShortcutAction
    private(set) var isRecording = false
    private(set) var message: String?

    init(action: ShortcutAction) { self.action = action }

    mutating func begin() {
        isRecording = true
        message = nil
    }

    mutating func cancel() {
        isRecording = false
        message = nil
    }

    @MainActor mutating func handle(_ shortcut: KeyShortcut?, isEscape: Bool, in keyboard: KeyboardSettings) -> Outcome {
        guard isRecording else { return .ignored }
        if isEscape { cancel(); return .cancelled }
        guard let shortcut else { return .ignored }
        if let rejection = keyboard.set(shortcut, for: action) {
            message = rejection.message
            return .rejected(rejection.message)
        }
        isRecording = false
        message = nil
        return .recorded
    }
}

/// Which row of the „Tastenkürzel“ tab records: at most one at a time.
struct RecordingSlot: Equatable {
    private(set) var active: ShortcutAction?

    mutating func start(_ action: ShortcutAction) { active = action }
    /// Ends `action`'s recording; a stale stop of a row that is no longer active changes nothing.
    mutating func stop(_ action: ShortcutAction) { if active == action { active = nil } }
    func isRecording(_ action: ShortcutAction) -> Bool { active == action }

    /// Only key presses in the recorder's own window are recorded (the monitor sees the whole app).
    static func accepts(eventWindow: NSWindow?, recorderWindow: NSWindow?) -> Bool {
        guard let eventWindow, let recorderWindow else { return false }
        return eventWindow === recorderWindow
    }
}

/// One row of the „Tastenkürzel“ tab: title, recorder button, „Zurücksetzen“, message.
struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    let keyboard: KeyboardSettings
    @Binding var slot: RecordingSlot
    @State private var recorder: ShortcutRecorderModel
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?

    init(action: ShortcutAction, keyboard: KeyboardSettings, slot: Binding<RecordingSlot>) {
        self.action = action
        self.keyboard = keyboard
        _slot = slot
        _recorder = State(initialValue: ShortcutRecorderModel(action: action))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recorder.isRecording ? "Taste drücken …" : keyboard.shortcut(for: action).display) {
                    recorder.isRecording ? stop() : start()
                }
                .frame(minWidth: 130)
                .accessibilityIdentifier("shortcut.\(action.rawValue)")
                Button("Zurücksetzen") { stop(); keyboard.reset(action) }
                    .disabled(keyboard.shortcut(for: action) == action.defaultShortcut)
            }
            if let message = recorder.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
        .onChange(of: slot) { _, slot in
            if recorder.isRecording, !slot.isRecording(action) { endRecording() }   // another row started
        }
    }

    private func start() {
        slot.start(action)
        recorder.begin()
        guard monitor == nil else { return }
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard RecordingSlot.accepts(eventWindow: event.window, recorderWindow: window) else { return event }
            let shortcut = KeyShortcut(event: event)
            let outcome = recorder.handle(shortcut, isEscape: event.keyCode == 53 && shortcut?.modifiers == [], in: keyboard)
            if !recorder.isRecording { stop() }
            return outcome == .ignored ? event : nil
        }
        // Leaving the settings window (or closing it) ends the recording.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { stop() }
        }
    }

    private func stop() {
        slot.stop(action)
        endRecording()
    }

    private func endRecording() {
        recorder.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// Settings tab „Tastenkürzel“.
struct ShortcutsTab: View {
    let keyboard: KeyboardSettings
    @State private var slot = RecordingSlot()

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { ShortcutRecorderRow(action: $0, keyboard: keyboard, slot: $slot) }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Feld anklicken und die neue Taste drücken; Esc bricht ab. ⌘F, ⌘O, ⌘P, ⌘S, ⌘[ und ⌘] sind fest belegt.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice = keyboard.lastResetNotice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                    Button("Alle auf Standard") { keyboard.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Menu entries that show the current bindings (built by the app's `.commands`).
public enum ViewerCommands {
    public struct Entry: Equatable {
        public let action: ShortcutAction
        public let title: String
        public let shortcut: KeyShortcut
    }

    /// „Darstellung“: zoom of the large preview.
    @MainActor public static func viewMenu(_ keyboard: KeyboardSettings) -> [Entry] {
        [.zoomIn, .zoomOut, .fitPage, .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4].map { entry($0, keyboard) }
    }

    /// The tick of the focused tile.
    @MainActor public static func selectionMenu(_ keyboard: KeyboardSettings) -> [Entry] {
        [entry(.toggleTick, keyboard)]
    }

    @MainActor private static func entry(_ action: ShortcutAction, _ keyboard: KeyboardSettings) -> Entry {
        let shortcut = keyboard.shortcut(for: action)
        return Entry(action: action, title: ViewerText.menuTitle(action, shortcut: shortcut), shortcut: shortcut)
    }
}

extension ViewerModel {
    /// Runs a shortcut action (menus and the keyboard router).
    public func perform(_ action: ShortcutAction) {
        switch action {
        case .zoomIn: previewZoom.zoomIn()
        case .zoomOut: previewZoom.zoomOut()
        case .fitPage: previewZoom.fitPage()
        case .toggleTick:
            if let page = focusedPage { selection.toggle(page) }
        case .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4:
            if let level = action.zoomLevel { previewZoom.setLevel(level) }
        }
    }
}
