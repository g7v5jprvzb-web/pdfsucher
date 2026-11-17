import PDFSearchCore
import SwiftUI

/// Screen 2: search field with microphone, filters, two-page preview and one row per document.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var voice = VoiceInput()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.searchPath) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case .page(let fileID, let page):
                    PageScreen(fileID: fileID, startPage: page)
                case .photo(let fileID):
                    PhotoScreen(fileID: fileID)
                }
            }
        }
        .onChange(of: model.query) { model.runSearch() }
        .onChange(of: model.scope) { model.runSearch() }
        .onChange(of: model.kindFilter) { model.runSearch() }
        .onChange(of: model.sort) { model.runSearch() }
        .onChange(of: model.hitsOnly) { model.hitsOnlyChanged() }
        .onChange(of: model.focusRequest) { fieldFocused = true }
        .onChange(of: model.voiceRequest) { startVoice() }
        .onChange(of: model.tab) { _, tab in if tab != .search { voice.stop() } }
        .alert("Spracheingabe", isPresented: Binding(
            get: { voice.errorMessage != nil },
            set: { if !$0 { voice.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voice.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Suchbegriff", text: $model.query)
                        .focused($fieldFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { model.rememberQuery() }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Suchbegriff löschen")
                    }
                    Button {
                        if voice.isListening { voice.stop() } else { startVoice() }
                    } label: {
                        Image(systemName: voice.isListening ? "mic.circle.fill" : "mic.fill")
                            .font(.system(size: voice.isListening ? 22 : 17))
                            .symbolEffect(.pulse, isActive: voice.isListening)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(voice.isListening ? Color.red : Color.accentColor)
                    .accessibilityLabel(voice.isListening ? "Spracheingabe beenden" : "Per Sprache suchen")
                }
                .padding(.leading, 10)
                .padding(.trailing, 2)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))

                HitsOnlyToggle()
            }

            HStack(spacing: 6) {
                Menu {
                    Button {
                        model.scope = .everywhere
                    } label: {
                        Label("Ganzes iPhone", systemImage: "iphone")
                    }
                    if !model.folders.isEmpty {
                        Section("Nur in Ordner") {
                            ForEach(model.folders) { folder in
                                Button(folder.name) { model.scope = .folder(folder.id) }
                            }
                        }
                    }
                } label: {
                    Label(model.scopeTitle, systemImage: model.scope == .everywhere ? "iphone" : "folder")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                }
                .accessibilityLabel("Suchbereich: \(model.scopeTitle)")

                Picker("Dateityp", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Menu {
                    Picker("Sortierung", selection: $model.sort) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel("Sortierung: \(model.sort.title)")
            }

            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var summary: String {
        let result = model.result
        if model.isSearching && result.documents.isEmpty { return "Suche …" }
        var parts: [String] = [model.hitsOnly ? "Nur Trefferseiten" : "Alle Seiten"]
        let pdfs = result.pdfDocuments.count
        if pdfs > 0 { parts.append("\(result.pdfHitPageCount) Seiten in \(pdfs) PDF") }
        if !result.photos.isEmpty { parts.append(result.photos.count == 1 ? "1 Foto" : "\(result.photos.count) Fotos") }
        if model.isIndexingAnything { parts.append("Index wird aufgebaut") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if model.isLoaded && model.folders.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Ordner", systemImage: "folder.badge.plus")
            } description: {
                Text("Füge in der Bibliothek Ordner hinzu, dann kannst du hier suchen.")
            } actions: {
                Button("Zur Bibliothek") { model.tab = .library }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            StartHints()
        } else if model.result.documents.isEmpty && !model.isSearching {
            ContentUnavailableView {
                Label("Keine Treffer", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("„\(model.query)“ kommt in \(model.scope == .everywhere ? "keiner Datei" : "„\(model.scopeTitle)“") vor.")
            } actions: {
                if model.scope != .everywhere {
                    Button("Im ganzen iPhone suchen") { model.scope = .everywhere }
                }
            }
        } else {
            VStack(spacing: 0) {
                if model.previewOnTop, model.previewDocument != nil { PreviewSpread() }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.result.pdfDocuments) { document in
                            DocumentRow(document: document)
                        }
                        if !model.result.photos.isEmpty {
                            PhotoGrid(photos: model.result.photos)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .scrollDismissesKeyboard(.immediately)
                if !model.previewOnTop, model.previewDocument != nil { PreviewSpread() }
            }
        }
    }

    private func startVoice() {
        fieldFocused = false
        let model = self.model
        let voice = self.voice
        Task {
            await voice.start { text in
                model.query = text
            }
        }
    }
}

/// The icon next to the search field: only pages with hits (filled) or all pages.
struct HitsOnlyToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.hitsOnly.toggle()
        } label: {
            Image(systemName: model.hitsOnly ? "doc.text.magnifyingglass" : "doc.on.doc")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(model.hitsOnly ? Color.white : Color.primary)
                .frame(width: 42, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(model.hitsOnly ? Color.accentColor : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.hitsOnly ? "Nur Trefferseiten" : "Alle Seiten")
        .accessibilityHint("Wechselt zwischen nur Trefferseiten und allen Seiten")
    }
}

private struct StartHints: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if !model.recentSearches.isEmpty {
                Section("Zuletzt gesucht") {
                    ForEach(model.recentSearches, id: \.self) { text in
                        Button {
                            model.query = text
                        } label: {
                            Label(text, systemImage: "clock.arrow.circlepath")
                        }
                        .tint(Color.primary)
                    }
                }
            }
            Section {
                Text("Gesucht wird in allen PDFs und JPEG-Fotos deiner Ordner, auch nach Wortteilen. Groß- und Kleinschreibung und Akzente spielen keine Rolle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }
}

// MARK: - Two-page preview

private struct PreviewSpread: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let document = model.previewDocument {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    ForEach(model.previewPages, id: \.self) { page in
                        NavigationLink(value: SearchRoute.page(fileID: document.fileID, page: page)) {
                            ThumbnailImage(url: model.url(of: document), kind: .pdf, page: page, maxPixel: 700)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.white)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .overlay(alignment: .bottom) {
                                    Text("\(page)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Seite \(page) groß öffnen")
                    }
                    if model.previewPages.count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 246)

                HStack(spacing: 2) {
                    Button { model.stepPreview(by: -1) } label: {
                        Image(systemName: "chevron.left").frame(width: 36, height: 30)
                    }
                    .accessibilityLabel("Vorherige Doppelseite")
                    Text("\(Text(document.name).bold()) · S. \(model.previewPages.map(String.init).joined(separator: " und "))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                    Button { model.stepPreview(by: 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 36, height: 30)
                    }
                    .accessibilityLabel("Nächste Doppelseite")
                    Button {
                        withAnimation(.snappy) { model.previewOnTop.toggle() }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.square")
                            .font(.system(size: 17))
                            .frame(width: 36, height: 30)
                    }
                    .tint(Color.secondary)
                    .accessibilityLabel(model.previewOnTop ? "Vorschau nach unten verschieben" : "Vorschau nach oben verschieben")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemFill))
        }
    }
}

// MARK: - Result rows

private struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    let document: DocumentHit

    var body: some View {
        let hitPages = Set(document.hitPageNumbers)
        let url = model.url(of: document)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                KindBadge(kind: .pdf)
                Text(document.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(folderLabel) · \(document.totalHits) Treffer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.trailing, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(model.visiblePages(of: document), id: \.self) { page in
                        PageTile(
                            url: url,
                            page: page,
                            isHit: hitPages.contains(page),
                            isInPreview: model.previewDocument?.fileID == document.fileID && model.previewPages.contains(page),
                            isSelected: model.isSelected(fileID: document.fileID, page: page)
                        )
                        .onTapGesture { model.showInPreview(document.fileID, page: page) }
                        .contextMenu {
                            Button("Öffnen", systemImage: "arrow.up.left.and.arrow.down.right") {
                                model.rememberQuery()
                                model.searchPath.append(.page(fileID: document.fileID, page: page))
                            }
                            Button(model.isSelected(fileID: document.fileID, page: page) ? "Aus Auswahl entfernen" : "Zur Auswahl",
                                   systemImage: "checkmark.circle") {
                                model.toggleSelection(document, page: page)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(height: 57)
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private var folderLabel: String {
        document.subfolder.isEmpty ? model.folderName(document.folderID) : (document.subfolder as NSString).lastPathComponent
    }
}

private struct PageTile: View {
    let url: URL?
    let page: Int
    let isHit: Bool
    let isInPreview: Bool
    let isSelected: Bool

    var body: some View {
        ThumbnailImage(url: url, kind: .pdf, page: page, maxPixel: 160)
            .frame(width: 42, height: 57)
            .background(Color.white)
            .opacity(isHit || isInPreview ? 1 : 0.5)
            .overlay(alignment: .top) {
                if isHit { Rectangle().fill(Color.yellow).frame(height: 3) }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(page)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 2)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                    .foregroundStyle(.black)
                    .padding(2)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isInPreview ? Color.accentColor : Color(.separator), lineWidth: isInPreview ? 2 : 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Seite \(page)\(isHit ? ", Treffer" : "")\(isSelected ? ", ausgewählt" : "")")
            .accessibilityAddTraits(.isButton)
    }
}

private struct PhotoGrid: View {
    @Environment(AppModel.self) private var model
    let photos: [DocumentHit]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                KindBadge(kind: .jpeg)
                Text("Fotos mit Treffer").font(.subheadline.weight(.semibold))
                Spacer()
                Text(photos.count == 1 ? "1 Foto" : "\(photos.count) Fotos").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(photos) { photo in
                    NavigationLink(value: SearchRoute.photo(fileID: photo.fileID)) {
                        ThumbnailImage(url: model.url(of: photo), kind: .jpeg, page: 1, maxPixel: 220)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .topTrailing) {
                                if model.isSelected(fileID: photo.fileID, page: 1) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.white, Color.accentColor)
                                        .padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { model.rememberQuery() })
                    .accessibilityLabel("Foto \(photo.name) öffnen")
                    .contextMenu {
                        Button(model.isSelected(fileID: photo.fileID, page: 1) ? "Aus Auswahl entfernen" : "Zur Auswahl",
                               systemImage: "checkmark.circle") {
                            model.toggleSelection(photo, page: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }
}

struct KindBadge: View {
    let kind: FileKind

    var body: some View {
        Text(kind == .pdf ? "PDF" : "JPEG")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(kind == .pdf ? Color.red : Color.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill((kind == .pdf ? Color.red : Color.orange).opacity(0.13)))
    }
}
