// StorageTab.swift — settings tab „Speicher“: the search index and the tile cache on disk
import SwiftUI

/// „Index“ (delete and rebuild, one folder or all) and „Kachel-Cache“ (size, clear). They moved out of
/// „Allgemein“, which no longer fit the window with them (985 pt of 880 pt).
struct StorageTab: View {
    let folderSources: [URL]
    let onDeleteIndex: ((URL?) -> Void)?
    let tileCache: TileDiskCache?
    /// Folder whose index „Index löschen …“ deletes; nil = all folders.
    @State private var deleteTarget: URL?
    /// Size of the tiles on disk; nil while it is being counted.
    @State private var tileCacheBytes: Int?

    private var canDeleteIndex: Bool { !folderSources.isEmpty }

    var body: some View {
        Form {
            if let onDeleteIndex {
                Section {
                    if folderSources.count > 1 {
                        Picker("Ordner", selection: $deleteTarget) {
                            Text("Alle Ordner").tag(URL?.none)
                            ForEach(folderSources, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                        }
                    }
                    Button("Index löschen …", role: .destructive) { onDeleteIndex(deleteTarget) }
                        .disabled(!canDeleteIndex)
                        .help(SettingsView.deleteIndexHelp(canDelete: canDeleteIndex))
                } header: {
                    Text("Index")
                } footer: {
                    Text("Der Index enthält den Text der Dateien. Nach dem Löschen wird er neu aufgebaut.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let tileCache {
                // Spec 1.2.3: rendered tiles on disk; clearing only costs time to render them again.
                Section("Kachel-Cache") {
                    LabeledContent("Belegt", value: tileCacheBytes.map(SettingsView.tileCacheSize) ?? "…")
                    Button("Kachel-Cache leeren") {
                        tileCacheBytes = nil
                        Task {
                            await tileCache.removeAll()
                            tileCacheBytes = await Task.detached(priority: .userInitiated) { tileCache.byteCount }.value
                        }
                    }
                    .help("Löscht die gespeicherten Seitenbilder. Sie entstehen beim nächsten Anzeigen neu.")
                }
                .task { tileCacheBytes = await Task.detached(priority: .utility) { tileCache.byteCount }.value }
            }
        }
        .formStyle(.grouped)
        .onChange(of: folderSources) { _, folders in
            // A removed folder must not stay picked (the model ignores it; the picker shows „Alle“ again).
            if let target = deleteTarget, !folders.contains(target) { deleteTarget = nil }
        }
    }
}
