import PDFSearchCore
import SwiftUI
import UIKit

/// Screen 5: collected pages and photos, in an order the user can change; share, print or save as one PDF.
struct SelectionView: View {
    @Environment(AppModel.self) private var model
    @State private var isWorking = false
    @State private var shareItem: ShareItem?
    @State private var fileToSave: URL?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.selection.isEmpty {
                    ContentUnavailableView {
                        Label("Noch nichts ausgewählt", systemImage: "checklist")
                    } description: {
                        Text("Tippe in einer Seite oder einem Foto auf „Auswählen“ oder halte eine Kachel gedrückt. Die gesammelten Seiten kannst du hier als ein PDF teilen, drucken oder sichern.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(model.selection) { item in
                                SelectionRow(item: item)
                            }
                            .onMove { model.selection.move(fromOffsets: $0, toOffset: $1) }
                            .onDelete { model.selection.remove(atOffsets: $0) }
                        } footer: {
                            Text("Reihenfolge per Ziehen ändern (Bearbeiten). Fotos werden als eigene Seite eingefügt.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.defaultMinListRowHeight, 44)
                    .safeAreaInset(edge: .bottom) { actions }
                }
            }
            .navigationTitle("Auswahl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.selection.isEmpty {
                        Button("Leeren", role: .destructive) { model.selection.removeAll() }
                            .tint(.red)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.selection.isEmpty { EditButton() }
                    GlobalSearchButton()
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
                    .presentationDetents([.medium, .large])
            }
            .fileMover(isPresented: Binding(get: { fileToSave != nil }, set: { if !$0 { fileToSave = nil } }),
                       file: fileToSave) { _ in fileToSave = nil }
            .alert("PDF konnte nicht erstellt werden", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                Task { if let url = await makePDF() { shareItem = ShareItem(url: url) } }
            } label: {
                Label("Als PDF teilen", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                Button {
                    Task { if let url = await makePDF() { Printing.print(url) } }
                } label: {
                    Label("Drucken", systemImage: "printer").frame(maxWidth: .infinity).frame(height: 30)
                }
                Button {
                    Task { if let url = await makePDF() { fileToSave = url } }
                } label: {
                    Label("In „Dateien“ sichern", systemImage: "folder").frame(maxWidth: .infinity).frame(height: 30)
                }
            }
            .buttonStyle(.bordered)
        }
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView() } }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Writes the selection to a temporary PDF named after the search.
    private func makePDF() async -> URL? {
        isWorking = true
        defer { isWorking = false }
        let items = model.composeItems()
        let name = PDFComposer.suggestedFileName(searchText: model.query, pageCount: items.count)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(path: name)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PDFComposer.Outcome, Error> in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return .success(try PDFComposer.compose(items, to: destination))
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(let result):
            if result.skipped > 0 {
                errorMessage = "\(result.skipped) Seite(n) ließen sich nicht lesen und fehlen im PDF."
            }
            return destination
        case .failure:
            errorMessage = "Keine der ausgewählten Dateien ließ sich lesen. Sind die Ordner noch vorhanden?"
            return nil
        }
    }
}

private struct SelectionRow: View {
    @Environment(AppModel.self) private var model
    let item: SelectedPage

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailImage(url: model.url(folderID: item.folderID, relativePath: item.relativePath),
                           kind: item.kind, page: item.pageNumber, maxPixel: 120)
                .frame(width: 30, height: 40)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(.separator), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.kind == .pdf ? "Seite \(item.pageNumber) · \(model.folderName(item.folderID))"
                                       : "Foto · \(model.folderName(item.folderID))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
enum Printing {
    static func print(_ url: URL) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = url.deletingPathExtension().lastPathComponent
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        _ = controller.present(animated: true, completionHandler: nil)
    }
}
