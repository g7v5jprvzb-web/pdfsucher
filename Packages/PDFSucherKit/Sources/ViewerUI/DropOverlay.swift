// DropOverlay.swift — 1.1 Task 3 (spec 1.1 §4 „Drag & Drop“)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Highlights the whole window while files are dragged over it.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).opacity(0.85)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(8)
            Label(ViewerText.dropPrompt, systemImage: "plus.rectangle.on.folder")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("dropOverlay")
    }
}

/// Turns dropped item providers into file paths.
enum DropLoader {
    /// A file reference URL (`file:///.file/id=…`) as its path URL; other URLs unchanged.
    nonisolated static func fileURL(_ url: URL) -> URL {
        (url as NSURL).filePathURL ?? url
    }

    @MainActor static func fileURL(from provider: NSItemProvider) async -> URL? {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        return url.map(fileURL)
    }
}

extension View {
    /// Accepts dropped files anywhere on the view; `onDrop` gets their URLs (in drop order).
    func acceptsFileDrops(isTargeted: Binding<Bool>, onDrop: @escaping @MainActor ([URL]) -> Void) -> some View {
        self.onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await DropLoader.fileURL(from: provider) { urls.append(url) }
                }
                if !urls.isEmpty { onDrop(urls) }
            }
            return true
        }
    }
}
