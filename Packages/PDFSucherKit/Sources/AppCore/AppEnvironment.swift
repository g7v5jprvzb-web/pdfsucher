// AppEnvironment.swift — Task 5.1
import AppKit
import Foundation

/// Everything `AppModel` needs from AppKit that shows a window or leaves the app: open and save
/// panels, the print dialog, Preview, a confirmation. The app passes `SystemEnvironment`;
/// tests pass a fake.
@MainActor public protocol AppEnvironment: AnyObject {
    /// Open panel: folders and PDFs, several at once; empty = cancelled.
    func chooseSources() -> [URL]
    func chooseSaveLocation(defaultName: String) -> URL?
    func runPrint(_ operation: NSPrintOperation)
    func openInPreview(_ url: URL)
    /// Asks before deleting; `question` names the folder or the number of folders.
    func confirmDeleteIndex(question: String) -> Bool
}
