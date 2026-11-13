// PDFSucherApp.swift — Task 5.1
import AppCore
import Foundation
import SearchKit
import SwiftUI
import ViewerUI

@main
struct PDFSucherApp: App {
    @State private var model: AppModel
    private let uiTestFolders: [URL]
    /// UI tests (1.2.1): added like a drop once the start is done, so the add prompt shows.
    private let uiTestAddFolder: URL?

    init() {
        // UI tests: `-uiTestFolder <dir>` or `-uiTestFolders "<dir1>|<dir2>"` loads those folders, with own
        // settings and one index file per folder in a temp dir.
        let args = UserDefaults.standard
        let paths = args.string(forKey: "uiTestFolders")?.split(separator: "|").map(String.init)
            ?? args.string(forKey: "uiTestFolder").map { [$0] } ?? []
        uiTestFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        uiTestAddFolder = args.string(forKey: "uiTestAddFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if !uiTestFolders.isEmpty {
            let defaults = UserDefaults(suiteName: "local.pdfsucher.uitest") ?? .standard
            // `-uiTestKeepDefaults YES`: a relaunch in the same test keeps what the first launch stored (1.2.1 §2).
            if !args.bool(forKey: "uiTestKeepDefaults") { defaults.removePersistentDomain(forName: "local.pdfsucher.uitest") }
            let indexDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFSucherUITest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
            _model = State(initialValue: AppModel(settings: GridSettings(defaults: defaults), defaults: defaults,
                                                  environment: SystemEnvironment(),
                                                  openIndex: { root in
                                                      let name = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
                                                      return try FolderIndex.shared(root: root, indexURL: indexDir.appendingPathComponent(name + ".sqlite"))
                                                  }))
        } else {
            _model = State(initialValue: AppModel(settings: GridSettings(), environment: SystemEnvironment()))
        }
    }

    var body: some Scene {
        Window("PDFSucher", id: "main") {
            ContentShell(model: model, highlighter: Highlighter.make)
                .task {
                    if !uiTestFolders.isEmpty {
                        await model.add(uiTestFolders)
                        if let uiTestAddFolder { model.addSources([uiTestAddFolder]) }
                    } else {
                        await model.restoreSources()
                    }
                }
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            ViewerMenus(model: model)
        }
        Window("Suchhilfe", id: "searchHelp") {
            SearchHelpView(keyboard: model.keyboard)
        }
        .defaultSize(width: 520, height: 640)
        Settings {
            SettingsView(settings: model.settings, keyboard: model.keyboard, ocr: model.ocrPreferences,
                         ocrCounts: { await model.ocrCounts(for: $0) }, onRerunOCR: { model.rerunRecognition(for: $0) },
                         folderSources: model.folderSources,
                         onDeleteIndex: { model.requestDeleteIndex(for: $0) }, history: model.searchHistory,
                         tileCache: .standard)
        }
    }
}

/// „Darstellung“ (zoom of the large preview) and the tick of the focused tile, with the current bindings
/// (spec 1.1 §10, §13). A plain key cannot be a menu key equivalent: it is named in the title instead.
struct ViewerMenus: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                ForEach(ViewerCommands.viewMenu(model.keyboard), id: \.action) { entry in
                    Button(entry.title) { model.perform(entry.action) }
                        .keyboardShortcut(entry.shortcut.keyboardShortcut)
                        .disabled(model.focusedPage == nil)
                }
            }
        }
        CommandGroup(replacing: .help) {
            HelpMenuButton()
        }
        CommandGroup(after: .pasteboard) {
            Section {
                ForEach(ViewerCommands.selectionMenu(model.keyboard), id: \.action) { entry in
                    Button(entry.title) { model.perform(entry.action) }
                        .keyboardShortcut(entry.shortcut.keyboardShortcut)
                        .disabled(model.focusedPage == nil)
                }
            }
        }
    }
}

/// Hilfe → Suchhilfe opens the same help as „?“ in the search field.
struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Suchhilfe") { openWindow(id: "searchHelp") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
