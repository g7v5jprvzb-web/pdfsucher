// SourcesMenu.swift — 1.1 Task 3 (spec 1.1 §4 „Hinzufügen statt Ersetzen“)
import SearchKit
import SwiftUI

/// „Quellen (n)“: every loaded source with ✕ to remove it, plus „Alle entfernen“.
struct SourcesMenu: View {
    let model: any ViewerModel

    struct Entry: Equatable {
        let url: URL
        let title: String
        let detail: String
        let symbol: String
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
                Button {
                    model.removeSource(entry.url)
                } label: {
                    Label("✕  \(entry.title)", systemImage: entry.symbol)
                }
                .help("\(entry.detail) entfernen")
                .accessibilityLabel(entry.accessibilityLabel)
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
        .help("Geladene Ordner und PDFs; ein Eintrag entfernt die Quelle")
        .accessibilityIdentifier("sourcesMenu")
    }
}
