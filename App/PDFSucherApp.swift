// PDFSucherApp.swift — Task 5.1
import AppCore
import AppKit
import Foundation
import IndexKit
import OfficeKit
import SearchKit
import SwiftUI
import ViewerUI

@main
struct PDFSucherApp: App {
    @State private var model: AppModel
    private let uiTestFolders: [URL]
    /// UI tests (1.2.1): added like a drop once the start is done, so the add prompt shows.
    private let uiTestAddFolder: URL?
    /// The tiles on disk: the user's cache, or an empty one in the UI-test run's temp dir (1.3.1: the user's cache
    /// was used in UI tests, and its entries reached into Downloads and Documents).
    private let tileDisk: TileDiskCache

    init() {
        // UI tests: `-uiTestFolder <dir>` or `-uiTestFolders "<dir1>|<dir2>"` loads those folders, with own
        // settings and one index file per folder in a temp dir.
        let args = UserDefaults.standard
        let paths = args.string(forKey: "uiTestFolders")?.split(separator: "|").map(String.init)
            ?? args.string(forKey: "uiTestFolder").map { [$0] } ?? []
        uiTestFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        uiTestAddFolder = args.string(forKey: "uiTestAddFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if !uiTestFolders.isEmpty {
            // Never Office's own fonts in UI-test runs, set before any font is resolved. Reading Office's font cache
            // in its group container makes macOS ask „would like to access data from other apps“ again for each
            // debug build (a new ad-hoc signature), and the prompt takes the focus: ⌘, and clicks of the test got
            // lost. This is the only switch: every prewarm and Word/PowerPoint layout registers through
            // `FontResolver.officeFontRoots`, so the lazy prewarm may run and finds no Office folders.
            OfficeDisplay.useNoOfficeFonts()
            let defaults = UserDefaults(suiteName: "local.pdfsucher.uitest") ?? .standard
            // `-uiTestKeepDefaults YES`: a relaunch in the same test keeps what the first launch stored (1.2.1 §2).
            if !args.bool(forKey: "uiTestKeepDefaults") { defaults.removePersistentDomain(forName: "local.pdfsucher.uitest") }
            let indexDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFSucherUITest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
            // Slides and tiles of the UI-test run in the same temp dir, never in the user's caches.
            tileDisk = TileDiskCache(directory: indexDir.appendingPathComponent("Tiles", isDirectory: true))
            let slides = SlideCache(root: indexDir.appendingPathComponent("SlideCache", isDirectory: true))
            let model = AppModel(settings: GridSettings(defaults: defaults), defaults: defaults,
                                 environment: SystemEnvironment(), slideCache: slides,
                                 openIndex: { root in
                                     let name = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
                                     return try FolderIndex.shared(root: root, indexURL: indexDir.appendingPathComponent(name + ".sqlite"),
                                                                   slideCache: slides)
                                 })
            model.tileDisk = tileDisk
            model.folderWatcher = FSEventsFolderWatcher()
            _model = State(initialValue: model)
        } else {
            // Measurement log of the indexing (1.3.9), on by default since 1.4.3; written at most 1 s late, flushed at quit.
            IndexMetrics.shared.setEnabled(IndexMetrics.isEnabledSetting(), atLaunch: true)
            // 1.4.2: diagnosis log of the result rows, off by default.
            IndexMetrics.rows.setEnabled(UserDefaults.standard.bool(forKey: IndexMetrics.rowsDefaultsKey), atLaunch: true)
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                IndexMetrics.shared.flush()
                IndexMetrics.rows.flush()
            }
            // 1.4.3: protocols kept 7 days; blocked main thread logged while the log is on.
            IndexMetrics.all.forEach { $0.deleteLogs(olderThan: 7) }
            MainHangWatch.shared.start()
            let model = AppModel(settings: GridSettings(), environment: SystemEnvironment())
            tileDisk = .standard
            model.tileDisk = tileDisk           // tiles of changed or gone PDFs are cleaned (1.2.4 §3)
            // Settings „Verwaiste Indexe“ (1.3.10): only the user's index folder, never in UI tests.
            model.indexDirectory = IndexStore.location(forFolder: URL(fileURLWithPath: "/", isDirectory: true)).deletingLastPathComponent()
            model.folderWatcher = FSEventsFolderWatcher()   // the tree follows the Finder (decisions „Ordner beobachten“)
            _model = State(initialValue: model)
        }
    }

    var body: some Scene {
        Window("PDFSucher", id: "main") {
            ContentShell(model: model, highlighter: Highlighter.make, tileDisk: tileDisk)
                .task {
                    MainHangWatch.shared.launchPhase("first_window")
                    model.startMaintenance()        // slide cache and Quick Look leftovers (1.3), before any layout
                    if !uiTestFolders.isEmpty {
                        await model.add(uiTestFolders)
                        if let uiTestAddFolder { model.addSources([uiTestAddFolder]) }
                        #if DEBUG
                        // UI tests: a folder chosen by code (as a place click does), with the bar shown first.
                        if let chosen = UserDefaults.standard.string(forKey: "uiTestSelectFolder") {
                            model.folderBar.isVisible = true
                            let delay = UserDefaults.standard.double(forKey: "uiTestSelectFolderDelay")
                            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                            model.selectFolder(URL(fileURLWithPath: chosen, isDirectory: true), adding: false)
                        }
                        if let dir = UserDefaults.standard.string(forKey: "trialDir") {
                            await TrialRun.run(model: model, dir: URL(fileURLWithPath: dir, isDirectory: true))
                        }
                        #endif
                    } else {
                        // Office's fonts at once when their registration succeeded before (1.3.2; never in UI tests).
                        model.startOfficeFontsIfRegisteredBefore()
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
                         office: model.officePreferences, layoutCounts: { await model.layoutCounts(for: $0) },
                         onClearSlideCache: { await model.clearSlideCache() }, tileCache: tileDisk,
                         storage: StorageActions(indexBytes: { await model.indexBytes(for: $0) },
                                                 orphanIndexes: { await model.orphanIndexFiles() },
                                                 deleteOrphanIndexes: { await model.deleteOrphanIndexes() },
                                                 slideCacheBytes: { await model.slideCacheBytes() },
                                                 rerunOCR: { model.rerunRecognition(forSource: $0) }))
        }
        .windowResizability(.contentMinSize)     // the settings window can be enlarged (1.2.4)
    }
}

/// „Darstellung“ (zoom of the large preview) and the tick of the focused tile, with the current bindings
/// (spec 1.1 §10, §13). A plain key cannot be a menu key equivalent: it is named in the title instead.
struct ViewerMenus: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // Ordnerleiste: ⌃⌘S (Darstellung).
            Button(model.folderBar.isVisible ? "Ordnerleiste ausblenden" : "Ordnerleiste einblenden") { model.folderBar.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
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
