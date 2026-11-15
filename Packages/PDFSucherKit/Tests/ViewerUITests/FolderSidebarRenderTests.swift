#if DEBUG
import AppKit
import SearchKit
import SwiftUI
import Testing
@testable import ViewerUI

/// Renders the folder bar and the filter header light and dark for a visual check (opt-in:
/// `PDFSUCHER_FOLDER_SHOTS=<dir>`).
@MainActor @Suite("Folder bar rendering")
struct FolderSidebarRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_FOLDER_SHOTS"] != nil))
    func renderLightAndDark() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSUCHER_FOLDER_SHOTS"]!)
        let model = SampleViewerModel()
        let root = URL(fileURLWithPath: "/Users/chris/Akten", isDirectory: true)
        let files = ["a.pdf", "Verträge/2024/v1.pdf", "Verträge/2024/v2.pdf", "Verträge/2023/v3.pdf", "Steuer/2024/bescheid.pdf",
                     "Fotos/beleg.jpg"].map { root.appendingPathComponent($0) }
        let single = URL(fileURLWithPath: "/Users/chris/Downloads/rechnung.pdf")
        model.folderTree = FolderTree.build(sources: [LoadedSourceRef(url: root, isFolder: true), LoadedSourceRef(url: single, isFolder: false)],
                                            files: files + [single])
        for (appearance, name) in [(NSAppearance.Name.aqua, "hell"), (.darkAqua, "dunkel")] {
            let view = HStack(spacing: 0) {
                FolderSidebar(model: model).frame(width: 260)
                Divider()
                VStack(spacing: 0) {
                    HeaderPreview()
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .frame(width: 700, height: 520)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("ordnerleiste-\(name).png"))
        }
    }

    /// The header as it shows with a filter on.
    private struct HeaderPreview: View {
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                Text("Ordner: Akten › Verträge › 2024 (2 Dateien)")
                Button {} label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(FieldIconButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
#endif
