// SystemEnvironment.swift — Task 5.1 (AppKit panels and dialogs for AppModel)
import AppCore
import AppKit
import IndexKit
import UniformTypeIdentifiers

@MainActor final class SystemEnvironment: AppEnvironment {
    func chooseSources() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SupportedSourceTypes.openPanelTypes      // the one list (1.2.1)
        panel.prompt = "Hinzufügen"
        panel.message = "Ordner, PDFs, Bilder, Word- und PowerPoint-Dateien wählen (mehrere mit ⌘-Klick oder ⇧-Klick; Unterordner werden mit durchsucht)"
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.prompt = "Sichern"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func runPrint(_ operation: NSPrintOperation) {
        // The print document is built in the background, so another window (settings, a panel) may be
        // key by now: attach the sheet to the visible main document window, never to a panel.
        let documentWindow = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel) && $0.identifier?.rawValue.hasPrefix("main") == true
        } ?? NSApp.mainWindow.flatMap { $0 is NSPanel ? nil : $0 }
        if let window = documentWindow, window.attachedSheet == nil {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func openInPreview(_ url: URL) {
        let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        if let preview {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Word/PowerPoint originals: whatever app macOS assigns to the file (Pages, Keynote, Office …);
    /// never launched by bundle id or scripted.
    func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func confirmDeleteIndex(question: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question
        alert.informativeText = "Der gespeicherte Text der PDFs wird gelöscht und danach neu eingelesen. Die PDFs selbst bleiben unverändert."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
