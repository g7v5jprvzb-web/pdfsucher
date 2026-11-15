#if DEBUG
import AppKit
import SearchKit
import SwiftUI
import Testing
@testable import ViewerUI

/// The folder bar with 10,000 files (50 × 7 × 12 folders, 2,501 nodes) in a real window: first layout, a
/// filter on a deep folder (the tree opens to it), the same again, then every folder open and one toggle.
/// Measured 2026-11-13 (M-series, debug): show 0.10 s, reveal 0.10 s, all open 0.54 s, toggle 0.14 s; with
/// OutlineGroup before: show 0.10 s, filter 0.06 s (without opening).
@MainActor @Suite("Folder bar performance", .serialized)
struct FolderSidebarPerformanceTests {
    let root = URL(fileURLWithPath: "/Akten", isDirectory: true)

    func model() -> SampleViewerModel {
        let model = SampleViewerModel()
        let files = (0..<10_000).map { root.appendingPathComponent("Ordner\($0 % 50)/Jahr\($0 % 7)/Monat\($0 % 12)/d\($0).pdf") }
        model.folderTree = FolderTree.build(sources: [LoadedSourceRef(url: root, isFolder: true)], files: files)
        return model
    }

    /// Lets SwiftUI and AppKit finish the pending work (layout, list updates).
    func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    @Test func tenThousandFilesShowAndRevealFast() {
        let model = model()
        let clock = ContinuousClock()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var host: NSHostingView<AnyView>!
        let show = clock.measure {
            host = NSHostingView(rootView: AnyView(FolderSidebar(model: model).frame(width: 260, height: 700)))
            window.contentView = host
            settle(host)
        }
        let deep = root.appendingPathComponent("Ordner37/Jahr4/Monat9", isDirectory: true)
        let reveal = clock.measure {
            model.selectFolder(deep, adding: false)
            settle(host)
        }
        let again = clock.measure {
            model.clearFolderFilter()
            settle(host)
            model.selectFolder(deep, adding: false)
            settle(host)
        }
        #expect(model.folderBar.isExpanded(root.appendingPathComponent("Ordner37/Jahr4")), "the tree opened to the folder")
        #expect(!model.folderBar.isExpanded(deep))
        // Worst case: every folder open (about 4,600 rows).
        var urls: [URL] = []
        func collect(_ node: FolderNode) { urls.append(node.url); node.children.forEach(collect) }
        model.folderTree.forEach(collect)
        let bar = model.folderBar
        let calls = clock.measure { for url in urls { bar.setExpanded(url, true) } }
        let all = clock.measure { settle(host) }
        let toggle = clock.measure {
            bar.setExpanded(root.appendingPathComponent("Ordner3"), false)
            settle(host)
        }
        print("FolderSidebar 10k: \(urls.count) setExpanded \(calls), one toggle with all open \(toggle)")
        print("FolderSidebar 10k: show \(show), reveal \(reveal), clear+again \(again), all open \(all)")
        #expect(calls < .milliseconds(1500), "opening \(urls.count) folders \(calls)")
        #expect(all < .milliseconds(2000), "all open \(all)")
        #expect(toggle < .milliseconds(500), "one toggle with all open \(toggle)")
        // Each includes 50–100 ms of run loop for SwiftUI's updates.
        #expect(show < .milliseconds(1500), "show \(show)")
        #expect(reveal < .milliseconds(1000), "reveal \(reveal)")
        #expect(again < .milliseconds(1000), "again \(again)")
        window.close()
    }
}
#endif
