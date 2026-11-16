// SourcesMenu.swift — 1.1 Task 3 (spec 1.1 §4 „Hinzufügen statt Ersetzen“)
import AppKit
import SearchKit
import SwiftUI

/// „Quellen (n)“: every loaded source as a submenu (remove it, delete and rebuild its index, show it in the Finder),
/// plus „Alle entfernen“. 1.3.10: a submenu, because a menu item cannot have a context menu of its own (macOS menus
/// treat a right click like a click).
struct SourcesMenu: View {
    let model: any ViewerModel

    struct Entry: Equatable {
        let url: URL
        let title: String
        let detail: String
        let symbol: String
        var isFolder: Bool { symbol == "folder" }
        var accessibilityLabel: String { "„\(title)“ entfernen" }
    }

    nonisolated static let removeAllTitle = "Alle entfernen"

    nonisolated static func entries(_ sources: [LoadedSourceRef]) -> [Entry] {
        sources.map { source in
            Entry(url: source.url, title: source.url.lastPathComponent, detail: source.url.path,
                  symbol: source.isFolder ? "folder" : "doc.richtext")
        }
    }

    var body: some View {
        let sources = model.sources
        Menu {
            ForEach(Self.entries(sources), id: \.url) { entry in
                Menu {
                    Button {
                        model.removeSource(entry.url)
                    } label: {
                        Label(ViewerText.removeAsSource, systemImage: "xmark")
                    }
                    .help("\(entry.detail) entfernen")
                    .accessibilityLabel(entry.accessibilityLabel)
                    if entry.isFolder {
                        Button(ViewerText.rebuildIndex) { model.requestDeleteIndex(for: entry.url) }
                            .help("Löscht den gespeicherten Text von „\(entry.title)“ (nach Rückfrage) und indexiert neu")
                    }
                    Divider()
                    Button(ViewerText.revealInFinder) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                } label: {
                    Label(entry.title, systemImage: entry.symbol)
                }
                .help(entry.detail)
            }
            if !sources.isEmpty {
                Divider()
                Button(Self.removeAllTitle) { model.removeAllSources() }
            }
        } label: {
            Text(ViewerText.sourcesTitle(count: sources.count)).monospacedDigit()
        }
        .fixedSize()
        .disabled(sources.isEmpty)
        .help("Geladene Ordner und Dateien; je Eintrag: entfernen, Index löschen und neu aufbauen, im Finder zeigen")
        .accessibilityIdentifier("sourcesMenu")
    }
}
