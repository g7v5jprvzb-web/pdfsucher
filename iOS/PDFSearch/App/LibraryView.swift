import PDFSearchCore
import SwiftUI
import UniformTypeIdentifiers

/// Library: picked folders, their index state, recent searches. No title bar: the bar at the
/// bottom already says where you are.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showsFolderPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.folders) { folder in
                        FolderRow(folder: folder)
                    }
                } header: {
                    HStack {
                        Text("Ordner")
                        Spacer()
                        Button {
                            showsFolderPicker = true
                        } label: {
                            Label("Hinzufügen", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .textCase(nil)
                        }
                        .accessibilityLabel("Ordner aus „Dateien“ hinzufügen")
                    }
                }

                if !model.recentSearches.isEmpty {
                    Section {
                        RecentSearches()
                            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    } header: {
                        HStack {
                            Text("Zuletzt gesucht")
                            Spacer()
                            Button("Alle löschen", role: .destructive) { model.clearRecentSearches() }
                                .font(.subheadline)
                                .textCase(nil)
                                .tint(.red)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 40)
            .contentMargins(.top, 0, for: .scrollContent)
            .refreshable { model.refreshAll() }
            .overlay {
                if model.isLoaded && model.folders.isEmpty {
                    EmptyLibrary { showsFolderPicker = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let removed = model.removedFolder {
                    UndoBanner(removed: removed)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.removedFolder)
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.addFolder(url) }
                }
            }
        }
    }
}

/// "„Downloads“ entfernt · Rückgängig", shown for a few seconds after the X.
private struct UndoBanner: View {
    @Environment(AppModel.self) private var model
    let removed: RemovedFolder

    var body: some View {
        HStack(spacing: 8) {
            Text("„\(removed.name)“ entfernt")
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Rückgängig") { Task { await model.undoRemoveFolder() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.72, blue: 0.95))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.17)))
        .task(id: removed.id) {
            try? await Task.sleep(for: .seconds(6))
            model.dismissUndo(removed.id)
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
            Button {
                Task { await model.removeFolder(folder.id) }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(folder.name) aus der Suche entfernen")
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
                    HStack(spacing: 0) {
                        Button(text) { model.search(for: text) }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .padding(.leading, 12)
                            .frame(height: 32)
                        Button {
                            withAnimation(.snappy) { model.removeRecentSearch(text) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 30, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("„\(text)“ aus Zuletzt gesucht löschen")
                    }
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
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
