import PDFSearchCore
import SwiftUI
import UniformTypeIdentifiers

/// Screen 1: picked folders, their index state, recent searches.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showsFolderPicker = false
    @State private var folderToRemove: FolderItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    searchShortcut
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 4))

                Section("Ordner") {
                    ForEach(model.folders) { folder in
                        FolderRow(folder: folder)
                            .swipeActions {
                                Button("Entfernen", role: .destructive) { folderToRemove = folder }
                            }
                    }
                    Button {
                        showsFolderPicker = true
                    } label: {
                        Label("Ordner aus „Dateien“ hinzufügen", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                    }
                }

                if !model.recentSearches.isEmpty {
                    Section("Zuletzt gesucht") {
                        RecentSearches()
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 40)
            .contentMargins(.top, 4, for: .scrollContent)
            .refreshable { model.refreshAll() }
            .overlay {
                if model.isLoaded && model.folders.isEmpty {
                    EmptyLibrary { showsFolderPicker = true }
                }
            }
            .navigationTitle("Bibliothek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.startGlobalSearch()
                    } label: {
                        Label("Überall", systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Ganzes iPhone durchsuchen")
                }
            }
            .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.addFolder(url) }
                }
            }
            .confirmationDialog(
                "„\(folderToRemove?.name ?? "")“ aus der Bibliothek entfernen?",
                isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Entfernen", role: .destructive) {
                    if let id = folderToRemove?.id { Task { await model.removeFolder(id) } }
                    folderToRemove = nil
                }
            } message: {
                Text("Die Dateien bleiben in „Dateien“ erhalten. Nur der Suchindex wird gelöscht.")
            }
        }
    }

    private var searchShortcut: some View {
        HStack(spacing: 6) {
            Button {
                model.startGlobalSearch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Ganzes iPhone durchsuchen")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.startVoiceSearch()
            } label: {
                Image(systemName: "mic.fill")
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Per Sprache suchen")
        }
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(iconColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 4)
            if folder.stats.notDownloaded > 0, !folder.isIndexing {
                Button("Laden") { Task { await model.downloadMissing(in: folder.id) } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.mini)
            }
            Button {
                model.searchInFolder(folder.id)
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Nur in \(folder.name) suchen")
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let error = folder.lastError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
        } else if folder.isIndexing {
            HStack(spacing: 6) {
                ProgressView(value: folder.progress?.fraction ?? 0)
                    .frame(maxWidth: 110)
                Text(progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text(countsText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var progressText: String {
        guard let progress = folder.progress, progress.total > 0 else { return "Suche Dateien …" }
        return "\(progress.processed) von \(progress.total)"
    }

    private var countsText: String {
        var parts: [String] = []
        parts.append("\(folder.stats.pdfCount.formatted()) PDF")
        parts.append("\(folder.stats.jpegCount.formatted()) JPEG")
        if folder.stats.notDownloaded > 0 { parts.append("\(folder.stats.notDownloaded) nicht geladen") }
        if folder.stats.failed > 0 { parts.append("\(folder.stats.failed) nicht lesbar") }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        folder.stats.jpegCount > folder.stats.pdfCount ? "photo.on.rectangle" : "folder"
    }

    private var iconColor: Color {
        folder.stats.jpegCount > folder.stats.pdfCount ? .orange : .accentColor
    }
}

private struct RecentSearches: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.recentSearches, id: \.self) { text in
                    Button(text) { model.search(for: text) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Color.primary)
                }
            }
        }
    }
}

private struct EmptyLibrary: View {
    let addFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Noch keine Ordner", systemImage: "folder.badge.plus")
        } description: {
            Text("Wähle Ordner aus der Dateien-App, zum Beispiel aus iCloud Drive oder „Auf meinem iPhone“. PDF Search liest PDFs und JPEG-Fotos darin und durchsucht sie dann sofort.")
        } actions: {
            Button("Ordner hinzufügen", action: addFolder)
                .buttonStyle(.borderedProminent)
        }
    }
}
