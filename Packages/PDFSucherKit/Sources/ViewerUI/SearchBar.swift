// SearchBar.swift — Task 4.3
import SearchKit
import SwiftUI

/// Open menu, search field, „Wortteile finden“ and sort picker (grid controls: `GridControls`).
struct SearchBar: View {
    let model: any ViewerModel
    var search = SearchFieldHandle()

    var body: some View {
        @Bindable var settings = model.settings
        HStack(spacing: 12) {
            Button { model.openSources() } label: {
                Label("Öffnen …", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .fixedSize()
            .help("Ordner und PDFs hinzufügen (mehrere mit ⌘-Klick); auch per Ziehen ins Fenster")
            SourcesMenu(model: model)

            SearchTextField(text: Binding(get: { model.queryText }, set: { model.queryText = $0 }),
                            placeholder: "Suchbegriff", handle: search, toolTip: SearchHelp.tooltip,
                            onSubmit: { model.noteSearchArrived() },
                            fontSize: CGFloat(model.settings.effectiveToolbarFontSize))
                // Before the overlay: after it, the identifier would replace those of ⌄ and „?“ (UI run 1.2.2).
                .accessibilityIdentifier("searchField")
                .frame(minWidth: 180)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 2) {
                        HistoryButton(model: model, search: search)
                        HelpButton(keyboard: model.keyboard)
                    }
                    .padding(.trailing, 3)
                }

            Toggle("Wortteile finden", isOn: $settings.partialWords)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Jedes Wort ohne * wie *wort* suchen")

            Picker("Sortierung", selection: $settings.sort) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(ViewerText.sortLabel(mode, browsing: model.isBrowsing)).tag(mode)
                }
            }
            .fixedSize()

        }
    }
}

/// „?“ inside the search field: the search help as a popover (spec 1.1 §11).
struct HelpButton: View {
    let keyboard: KeyboardSettings
    @State private var shows = false

    var body: some View {
        Button { shows.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(FieldIconButtonStyle())
        .help("Suchhilfe")
        .accessibilityLabel("Suchhilfe")
        .accessibilityIdentifier("searchHelpButton")
        .popover(isPresented: $shows, arrowEdge: .bottom) { SearchHelpView(keyboard: keyboard) }
    }
}

/// ⌄ and „?“ in the search field (1.2.4, Chris): full label colour so they look clickable, a light
/// highlight on hover, a visible press; grey only when disabled.
struct FieldIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
            .padding(2)
            .background(Circle().fill(Color(nsColor: .labelColor)
                .opacity(!isEnabled ? 0 : configuration.isPressed ? 0.22 : hovering ? 0.10 : 0)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Rows stepper (only active in automatic mode) and pages per row, on the second toolbar line.
struct GridControls: View {
    @Bindable var settings: GridSettings

    var body: some View {
        // 1.2.2 §2: the line wraps instead of cutting anything off (large toolbar font, a narrow window). Further
        // controls go into this flow.
        ToolbarFlow(spacing: 12, lineSpacing: 6) {
            FileKindsMenu(settings: settings)        // spec 1.3 §8a
            Stepper("Reihen: \(settings.rows)", value: $settings.rows, in: GridSettings.range)
                .monospacedDigit()
                .disabled(!settings.rowsApply)
                .help(settings.rowsApply ? "Sichtbare Reihen; bestimmen die Kachelgröße"
                                         : "Nur bei „Automatisch“: bei fester Anzahl füllen die Seiten die Breite")
                .accessibilityIdentifier("rowsStepper")
            ColumnsControl(settings: settings)
            HeaderFontControl(settings: settings)
            Toggle("Alle Seiten", isOn: $settings.showAllPages)
                .toggleStyle(.checkbox)
                .help("Alle Seiten jedes Treffer-Dokuments zeigen; Trefferseiten sind markiert")
                .accessibilityIdentifier("showAllPages")
            PreviewPositionPicker(settings: settings)
        }
    }
}

/// Preview on top, left or right (spec 1.1 §3): three symbols.
struct PreviewPositionPicker: View {
    @Bindable var settings: GridSettings

    var body: some View {
        Picker("Vorschau", selection: $settings.previewPosition) {
            ForEach(PreviewPosition.allCases, id: \.self) { position in
                Label(Self.label(position), systemImage: Self.symbol(position)).labelStyle(.iconOnly)
                    .help(Self.label(position)).tag(position)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Lage der großen Vorschau")
        .accessibilityIdentifier("previewPosition")
    }

    static func symbol(_ p: PreviewPosition) -> String {
        switch p {
        case .top: "rectangle.tophalf.inset.filled"
        case .leading: "rectangle.lefthalf.inset.filled"
        case .trailing: "rectangle.righthalf.inset.filled"
        }
    }

    static func label(_ p: PreviewPosition) -> String {
        switch p {
        case .top: "Vorschau oben"
        case .leading: "Vorschau links"
        case .trailing: "Vorschau rechts"
        }
    }
}

/// A− / „16 pt“ / A+ for the row header size (spec 1.1 §1).
struct HeaderFontControl: View {
    @Bindable var settings: GridSettings

    var body: some View {
        HStack(spacing: 2) {
            Button { settings.decreaseHeaderFont() } label: {
                Text("A−").font(.system(size: settings.effectiveToolbarFontSize * 11 / 13, weight: .semibold))
            }
                .disabled(!settings.canDecreaseHeaderFont)
                .help("Überschriften kleiner")
                .accessibilityLabel("Überschriften kleiner")
                .accessibilityIdentifier("headerFontDecrease")
            Text("\(settings.headerFontSize) pt")
                .monospacedDigit()
                .frame(minWidth: 38)
                .accessibilityIdentifier("headerFontSize")
            Button { settings.increaseHeaderFont() } label: {
                Text("A+").font(.system(size: settings.effectiveToolbarFontSize * 14 / 13, weight: .semibold))
            }
                .disabled(!settings.canIncreaseHeaderFont)
                .help("Überschriften größer")
                .accessibilityLabel("Überschriften größer")
                .accessibilityIdentifier("headerFontIncrease")
        }
        .buttonStyle(.borderless)
    }
}

/// „Seiten pro Reihe“: slider 1…10 (fixed: exactly n pages fill the width) plus „Automatisch“; in
/// automatic mode the slider is disabled and the label shows how many pages currently fit the window width.
struct ColumnsControl: View {
    @Bindable var settings: GridSettings

    var body: some View {
        let automatic = settings.columnsMode == .automatic
        let shown = automatic ? settings.automaticColumns : settings.columns
        let shownText = shown > 0 ? "\(shown)" : "–"     // automatic: before the grid measured itself
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Seiten pro Reihe:")
                // Fixed width, so the toolbar does not jump when the number gets a second digit.
                Text("00").hidden().overlay(alignment: .leading) { Text(shownText) }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("columnsLabel")
            Slider(value: Binding(get: { Double(automatic ? min(max(shown, 1), 10) : settings.columns) },
                                  set: { settings.columns = Int($0.rounded()) }),
                   in: 1...10, step: 1) {
                Text("Seiten pro Reihe")
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(automatic)
            .accessibilityValue(shownText)
            .accessibilityIdentifier("columnsSlider")
            Toggle("Automatisch", isOn: Binding(get: { automatic },
                                                set: { settings.columnsMode = $0 ? .automatic : .fixed }))
                .toggleStyle(.checkbox)
                .help("So viele Seiten pro Reihe, wie in die Fensterbreite passen")
                .accessibilityIdentifier("columnsAutomatic")
        }
    }
}
