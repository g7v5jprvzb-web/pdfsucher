import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// „Ordner und Index“: share folders, index in the foreground, list unreadable files.
struct FoldersIndexView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.places) { place in
                        HStack {
                            Image(systemName: place.id == SharedPlace.builtInID ? "ipad" : "folder")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(place.place.name)
                                if place.id == SharedPlace.builtInID {
                                    Text("Dateien-App › Auf meinem iPad › PDF Search").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if place.id != SharedPlace.builtInID {
                                Button(role: .destructive) { model.removePlace(place.id) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(place.place.name) entfernen")
                            }
                        }
                    }
                    ForEach(model.placeErrors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Button { picking = true } label: {
                        Label("Ordner hinzufügen …", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Freigegebene Orte")
                } footer: {
                    Text("iPadOS lässt eine App nur in Orten suchen, die du ihr freigibst. „Ganzes iPad“ sucht über alle Orte dieser Liste.")
                }

                Section {
                    Button { picking = true } label: {
                        Label("„Auf meinem iPad“ als Ganzes freigeben …", systemImage: "ipad")
                    }
                    Button { picking = true } label: {
                        Label("iCloud Drive als Ganzes freigeben …", systemImage: "icloud")
                    }
                } header: {
                    Text("Alles freigeben")
                } footer: {
                    Text("Im Auswahlfenster links den Ort („Auf meinem iPad“ oder „iCloud Drive“) antippen, nichts darin auswählen und oben rechts „Öffnen“ tippen. iCloud-Dateien, die nur in der Cloud liegen, lädt PDF Search vor dem Lesen.")
                }

                Section("Index") {
                    if model.isIndexing {
                        VStack(alignment: .leading, spacing: 6) {
                            if let fraction = model.progressFraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            Text(model.progressText).font(.footnote).foregroundStyle(.secondary)
                            Text("Bitte PDF Search im Vordergrund lassen, bis das Indizieren fertig ist.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent("Stand", value: model.indexStatus)
                        if model.interruptions > 0 {
                            LabeledContent("Im Hintergrund unterbrochen", value: "\(model.interruptions)×, danach fortgesetzt")
                                .accessibilityIdentifier("interruptions")
                        }
                        Button {
                            Task { await model.reindex() }
                        } label: {
                            Label("Jetzt indizieren", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section {
                    if model.unreadable.isEmpty {
                        Text("Keine").foregroundStyle(.secondary)
                    }
                    ForEach(model.unreadable) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).lineLimit(2).truncationMode(.middle)
                            Text("\(file.place) · \(file.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Nicht lesbare Dateien (\(model.unreadable.count))")
                }
            }
            .accessibilityIdentifier("foldersSheet")
            .navigationTitle("Ordner und Index")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .sheet(isPresented: $picking) {
                FolderPicker { urls in model.addFolders(urls) }
                    .ignoresSafeArea()
            }
        }
    }
}

/// UIDocumentPickerViewController in folder mode.
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}
