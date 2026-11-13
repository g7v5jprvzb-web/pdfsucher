// SettingsView.swift — Task 4.3
import AppKit
import SearchKit
import SwiftUI

/// Settings window: tabs „Allgemein“, „Vorschau“, „Tastatur“, „Tastenkürzel“ (1.1).
/// `onDeleteIndex` adds the „Index löschen …“ button.
public struct SettingsView: View {
    @Bindable private var settings: GridSettings
    @Bindable private var keyboard: KeyboardSettings
    private let ocr: OCRPreferences?
    private let ocrCounts: ((URL) async -> (pages: Int, images: Int)?)?
    private let onRerunOCR: ((URL) -> Void)?
    private let onDeleteIndex: ((URL?) -> Void)?
    private let folderSources: [URL]
    /// 1.2.2 §1: „Suchverlauf“ in „Allgemein“ (not shown without it).
    private let history: SearchHistory?
    private var canDeleteIndex: Bool { !folderSources.isEmpty }
    /// Folder whose index „Index löschen …“ deletes; nil = all folders.
    @State private var deleteTarget: URL?
    private let tileCache: TileDiskCache?
    /// Size of the tiles on disk; nil while it is being counted.
    @State private var tileCacheBytes: Int?

    /// - Parameters:
    ///   - folderSources: loaded folders; empty disables „Index löschen …“.
    ///   - onDeleteIndex: deletes the index of one folder or (nil) of all folders.
    /// - Parameters:
    ///   - ocr, ocrCounts, onRerunOCR: the „Texterkennung“ tab (spec 1.2 §7); without `ocr` it is not shown.
    public init(settings: GridSettings, keyboard: KeyboardSettings, ocr: OCRPreferences? = nil,
                ocrCounts: ((URL) async -> (pages: Int, images: Int)?)? = nil, onRerunOCR: ((URL) -> Void)? = nil,
                folderSources: [URL] = [], onDeleteIndex: ((URL?) -> Void)? = nil, history: SearchHistory? = nil,
                tileCache: TileDiskCache? = nil) {
        self.history = history
        self.tileCache = tileCache
        self.settings = settings
        self.keyboard = keyboard
        self.ocr = ocr
        self.ocrCounts = ocrCounts
        self.onRerunOCR = onRerunOCR
        self.folderSources = folderSources
        self.onDeleteIndex = onDeleteIndex
    }

    public var body: some View {
        // The tab chosen last and the window's place are remembered (1.2.1 §2).
        TabView(selection: $settings.settingsTab) {
            general.tabItem { Label("Allgemein", systemImage: "gearshape") }.tag(SettingsTab.general)
            preview.tabItem { Label("Vorschau", systemImage: "doc.viewfinder") }.tag(SettingsTab.preview)
            appearance.tabItem { Label("Darstellung", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            if let ocr {
                OCRTab(ocr: ocr, folders: folderSources, counts: ocrCounts, onRerun: onRerunOCR)
                    .tabItem { Label("Texterkennung", systemImage: "text.viewfinder") }.tag(SettingsTab.ocr)
            }
            keys.tabItem { Label("Tastatur", systemImage: "keyboard") }.tag(SettingsTab.keyboard)
            ShortcutsTab(keyboard: keyboard).tabItem { Label("Tastenkürzel", systemImage: "command") }.tag(SettingsTab.shortcuts)
        }
        .frame(width: 520)
        .background(WindowFrameKeeper(
            load: { [settings] in settings.settingsWindowOrigin.map { CGRect(origin: $0, size: .zero) } },
            save: { [settings] in settings.settingsWindowOrigin = CGPoint(x: $0.minX, y: $0.maxY) },
            size: false))
    }

    /// §13: share of the page width per zoom level.
    private var preview: some View {
        Form {
            Section("Lage") {
                Picker("Vorschau", selection: $settings.previewPosition) {
                    ForEach(PreviewPosition.allCases, id: \.self) { Text(PreviewPositionPicker.label($0)).tag($0) }
                }
            }
            Section {
                ForEach(1...4, id: \.self) { level in
                    Stepper("Stufe \(level): \(settings.zoomLevelFractions[level - 1]) % der Seitenbreite",
                            value: Binding(get: { settings.zoomLevelFractions[level - 1] },
                                           set: { settings.setZoomLevelFraction(level, to: $0) }),
                            in: GridSettings.zoomLevelRange, step: GridSettings.zoomLevelStep)
                        .monospacedDigit()
                }
                Button("Zurücksetzen") { settings.resetZoomLevels() }
                    .disabled(settings.zoomLevelFractions == GridSettings.defaultZoomLevels)
            } header: {
                Text("Zoom-Stufen der großen Vorschau")
            } footer: {
                Text("Stufe 1 (⌘1) füllt die Breite der Vorschau; die übrigen Stufen zeigen die Seite entsprechend kleiner.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// §14: highlight colour.
    private var appearance: some View {
        Form {
            Section {
                ColorPicker("Markierungsfarbe", selection: Binding(
                    get: { Color(.sRGB, red: settings.highlightColor.r, green: settings.highlightColor.g,
                                 blue: settings.highlightColor.b, opacity: settings.highlightColor.a) },
                    set: { color in
                        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                        settings.highlightColor = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
                    }), supportsOpacity: false)
                Button("Zurücksetzen") { settings.resetHighlightColor() }
                    .disabled(settings.highlightColor == .yellow)
            } header: {
                Text("Treffermarkierung")
            } footer: {
                Text("Gilt für die Kacheln und die große Vorschau. Kleine Kacheln (unter 280 pt) zeigen vergrößerte Markierungen und einen Streifen am linken Rand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                // Continuous 10…20 pt; the toolbar follows while dragging (live preview, 1.2.2 §2).
                HStack {
                    Slider(value: Binding(get: { settings.effectiveToolbarFontSize }, set: { settings.toolbarFontSize = $0 }),
                           in: ToolbarScale.range) {
                        Text("Schriftgröße Werkzeugleiste")
                    } minimumValueLabel: {
                        Text("A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text("A").font(.system(size: 20))
                    }
                    .accessibilityIdentifier("toolbarFontSlider")
                    Text(String(format: "%.1f pt", settings.effectiveToolbarFontSize))
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                        .accessibilityIdentifier("toolbarFontValue")
                }
                Button("Zurücksetzen") { settings.resetToolbarFont() }
                    .disabled(settings.toolbarFontSize == nil)
                    .accessibilityIdentifier("toolbarFontReset")
            } header: {
                Text("Werkzeugleiste")
            } footer: {
                Text("Standard ist die Systemgröße (13 pt). Die Leiste bricht bei großer Schrift um.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// §9: Tab order.
    private var keys: some View {
        Form {
            Section("Tastatur") {
                Toggle("Tab überspringt das Suchfeld", isOn: $keyboard.tabSkipsSearch)
                Text(keyboard.tabSkipsSearch
                     ? "Tab wechselt nur zwischen Vorschau und Trefferraster; ins Suchfeld mit ⌘F oder Klick."
                     : "Tab: Suchfeld → Vorschau → Trefferraster.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section("Trefferraster") {
                Picker("Seiten pro Reihe", selection: $settings.columnsMode) {
                    Text("Fest (füllen die Breite)").tag(ColumnsMode.fixed)
                    Text("Automatisch (aus Reihen und Fensterbreite)").tag(ColumnsMode.automatic)
                }
                Stepper("Feste Anzahl: \(settings.columns)", value: $settings.columns, in: GridSettings.range)
                    .disabled(settings.columnsMode == .automatic)
                Stepper("Sichtbare Reihen: \(settings.rows)", value: $settings.rows, in: GridSettings.range)
                    .disabled(!settings.rowsApply)
                Toggle("Alle Seiten der Treffer-Dokumente zeigen", isOn: $settings.showAllPages)
                Stepper("Überschriften: \(settings.headerFontSize) pt", value: $settings.headerFontSize,
                        in: GridSettings.headerFontRange, step: GridSettings.headerFontStep)
                Picker("Sortierung", selection: $settings.sort) {
                    ForEach(SortMode.allCases, id: \.self) { Text(ViewerText.sortLabel($0)).tag($0) }
                }
            }
            if let history {
                HistorySettings(history: history)
            }
            Section("Quellen") {
                Picker("Beim Hinzufügen von Quellen", selection: $settings.addSourcesPolicy) {
                    ForEach(AddSourcesPolicy.allCases, id: \.self) { policy in
                        Text(policy == .ask ? "\(policy.title) (Standard)" : policy.title).tag(policy)
                    }
                }
                .help("Was beim Ziehen oder Öffnen neuer Ordner und Dateien passiert, wenn schon Quellen geladen sind")
            }
            Section("Suche") {
                Toggle("Tippen sucht sofort", isOn: $keyboard.typeToSearch)
                    .help("Jede Taste geht ins Suchfeld, egal wo der Fokus ist; aus: Tasten wirken auf das gewählte Element, ⌘F springt ins Suchfeld")
                if let notice = keyboard.lastResetNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Wortteile finden", isOn: $settings.partialWords)
                Picker("Wartezeit nach dem Tippen", selection: $settings.debounceMs) {
                    ForEach(GridSettings.debounceChoices, id: \.self) { ms in
                        Text(ms == GridSettings.debounceChoices[0] ? "\(ms) ms (Standard)" : "\(ms) ms").tag(ms)
                    }
                }
                .help("So lange wartet die Suche nach dem letzten Tastendruck")
            }
            if let onDeleteIndex {
                Section("Index") {
                    if folderSources.count > 1 {
                        Picker("Ordner", selection: $deleteTarget) {
                            Text("Alle Ordner").tag(URL?.none)
                            ForEach(folderSources, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                        }
                    }
                    Button("Index löschen …", role: .destructive) { onDeleteIndex(deleteTarget) }
                    .disabled(!canDeleteIndex)
                    .help(Self.deleteIndexHelp(canDelete: canDeleteIndex))
                }
            }
            if let tileCache {
                // Spec 1.2.3: rendered tiles on disk; clearing only costs time to render them again.
                Section("Kachel-Cache") {
                    LabeledContent("Belegt", value: tileCacheBytes.map(Self.tileCacheSize) ?? "…")
                    Button("Kachel-Cache leeren") {
                        tileCacheBytes = nil
                        Task {
                            tileCacheBytes = await Task.detached(priority: .userInitiated) {
                                tileCache.removeAll()
                                return tileCache.byteCount
                            }.value
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

    nonisolated static func tileCacheSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func deleteIndexHelp(canDelete: Bool) -> String {
        canDelete ? "Löscht den gespeicherten Text des gewählten Ordners (oder aller Ordner) und indexiert neu" : "Erst einen Ordner öffnen"
    }
}

/// Settings tab „Texterkennung“ (spec 1.2 §7).
struct OCRTab: View {
    @Bindable var ocr: OCRPreferences
    let folders: [URL]
    let counts: ((URL) async -> (pages: Int, images: Int)?)?
    let onRerun: ((URL) -> Void)?

    var body: some View {
        Form {
            Section {
                Toggle("Texterkennung (OCR)", isOn: $ocr.recognizeText)
                    .help("Text in gescannten PDFs und Bildern im Hintergrund erkennen (Apple Vision, ohne Internet)")
                Toggle("Bilder durchsuchen (PNG, JPEG, HEIC, DNG)", isOn: $ocr.includeImages)
                    .help("Aus: Bilder werden nicht mehr aufgelistet; ihr erkannter Text wird aus dem Index entfernt")
            } footer: {
                Text("Die Erkennung läuft im Hintergrund; bereits Erkanntes bleibt beim Anhalten erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !folders.isEmpty {
                Section("Quellen") {
                    ForEach(folders, id: \.self) { folder in
                        OCRSourceRow(folder: folder, counts: counts, onRerun: ocr.recognizeText ? onRerun : nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OCRSourceRow: View {
    let folder: URL
    let counts: ((URL) async -> (pages: Int, images: Int)?)?
    let onRerun: ((URL) -> Void)?
    @State private var text = ""
    @State private var refresh = 0

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(folder.lastPathComponent)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onRerun {
                Button("Texterkennung neu ausführen") { onRerun(folder); refresh += 1 }
                    .help("Alle erkannten Seiten und Bilder dieser Quelle neu erkennen")
                    .accessibilityLabel("Texterkennung für \(folder.lastPathComponent) neu ausführen")
            }
        }
        .task(id: "\(folder.path)#\(refresh)") {
            // Updated while the tab is open (recognition goes on in the background).
            while !Task.isCancelled {
                if let counts, let c = await counts(folder) { text = ViewerText.ocrCounts(pages: c.pages, images: c.images) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}


/// 1.2.2 §1: „Suchverlauf speichern“, number of entries, „Verlauf löschen“.
private struct HistorySettings: View {
    @Bindable var history: SearchHistory

    var body: some View {
        Section("Suchverlauf") {
            Toggle("Suchverlauf speichern", isOn: $history.isEnabled)
                .help("Aus: der Verlauf wird gelöscht und nichts mehr gespeichert")
            Stepper("Einträge: \(history.limit)", value: $history.limit, in: SearchHistory.limitRange, step: 10)
                .monospacedDigit()
                .disabled(!history.isEnabled)
            Button(ViewerText.historyClear) { history.clear() }
                .disabled(history.entries.isEmpty)
        }
    }
}
