import SwiftUI

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showTree: Bool
    @Binding var previewOnLeft: Bool
    @Binding var showFolders: Bool
    @State private var speech = SpeechInput()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Button { showTree.toggle() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.title2)
                        .symbolVariant(showTree ? .fill : .none)
                }
                .accessibilityLabel(showTree ? "Ordnerbaum ausblenden" : "Ordnerbaum einblenden")

                Text("PDF Search")
                    .font(.title2.bold())
                    .fixedSize()

                searchField

                Toggle(isOn: $model.wholeIPad) {
                    Label("Ganzes iPad", systemImage: "ipad.landscape")
                }
                .toggleStyle(.button)
                .fixedSize()

                Picker("Typ", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Menu {
                    Picker("Sortierung", selection: $model.sort) {
                        ForEach(ResultSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(model.sort.title, systemImage: "arrow.up.arrow.down")
                        .fixedSize()
                }

                Button { previewOnLeft.toggle() } label: {
                    Image(systemName: "rectangle.2.swap").font(.title3)
                }
                .accessibilityLabel(previewOnLeft ? "Vorschau nach rechts" : "Vorschau nach links")

                Button { showFolders = true } label: {
                    Image(systemName: "folder.badge.gearshape").font(.title3)
                }
                .accessibilityLabel("Ordner und Index")
            }
            if let message = speech.message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("In PDFs und JPEGs suchen", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Suche löschen")
            }
            Button {
                speech.toggle { text in model.query = text }
            } label: {
                Image(systemName: speech.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(speech.isListening ? Color.red : Color.accentColor)
                    .symbolEffect(.pulse, isActive: speech.isListening)
            }
            .accessibilityLabel(speech.isListening ? "Sprachsuche beenden" : "Sprachsuche")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .frame(minWidth: 220, maxWidth: .infinity)
    }
}
