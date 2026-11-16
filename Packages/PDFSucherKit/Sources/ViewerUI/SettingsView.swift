// SettingsView.swift — Task 4.3
import AppKit
import IndexKit
import SearchKit
import SwiftUI

/// Settings window: tabs „Allgemein“, „Vorschau“, „Darstellung“, „Texterkennung“, „Speicher“, „Tastatur“,
/// „Tastenkürzel“. `onDeleteIndex` and `tileCache` fill „Speicher“ (Index, Kachel-Cache).
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
    private let tileCache: TileDiskCache?
    /// 1.3 Teil B Task 12: the „Word/PowerPoint“ tab (not shown without `office`).
    private let office: OfficePreferences?
    private let layoutCounts: ((URL) async -> LayoutCounts?)?
    private let onClearSlideCache: (() async -> Void)?

    /// - Parameters:
    ///   - folderSources: loaded folders; empty disables „Index löschen …“.
    ///   - onDeleteIndex: deletes the index of one folder or (nil) of all folders.
    /// - Parameters:
    ///   - ocr, ocrCounts, onRerunOCR: the „Texterkennung“ tab (spec 1.2 §7); without `ocr` it is not shown.
    ///   - office, layoutCounts, onClearSlideCache: the „Word/PowerPoint“ tab (1.3); without `office` it is not shown,
    ///     without `onClearSlideCache` it has no „Folien-Cache leeren“.
    public init(settings: GridSettings, keyboard: KeyboardSettings, ocr: OCRPreferences? = nil,
                ocrCounts: ((URL) async -> (pages: Int, images: Int)?)? = nil, onRerunOCR: ((URL) -> Void)? = nil,
                folderSources: [URL] = [], onDeleteIndex: ((URL?) -> Void)? = nil, history: SearchHistory? = nil,
                office: OfficePreferences? = nil, layoutCounts: ((URL) async -> LayoutCounts?)? = nil,
                onClearSlideCache: (() async -> Void)? = nil, tileCache: TileDiskCache? = nil) {
        self.office = office
        self.layoutCounts = layoutCounts
        self.onClearSlideCache = onClearSlideCache
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
            if let office {
                OfficeTab(office: office, folders: folderSources, counts: layoutCounts, onClearSlideCache: onClearSlideCache)
                    .tabItem { Label("Word/PowerPoint", systemImage: "doc.richtext") }.tag(SettingsTab.office)
            }
            if onDeleteIndex != nil || tileCache != nil {
                StorageTab(folderSources: folderSources, onDeleteIndex: onDeleteIndex, tileCache: tileCache)
                    .tabItem { Label("Speicher", systemImage: "internaldrive") }.tag(SettingsTab.storage)
            }
            keys.tabItem { Label("Tastatur", systemImage: "keyboard") }.tag(SettingsTab.keyboard)
            ShortcutsTab(keyboard: keyboard).tabItem { Label("Tastenkürzel", systemImage: "command") }.tag(SettingsTab.shortcuts)
        }
        // Every tab fits without scrolling; the window can be resized and keeps its size (1.2.4).
        // One ideal size for every tab, so switching tabs does not resize the window (review I3).
        .frame(minWidth: SettingsLayout.minContentSize.width, idealWidth: SettingsLayout.defaultContentSize.width, maxWidth: .infinity,
               minHeight: SettingsLayout.minContentSize.height, idealHeight: SettingsLayout.defaultContentSize.height,
               maxHeight: .infinity)
        .background(WindowFrameKeeper(
            load: { [settings] in settings.settingsWindowFrame },
            save: { [settings] in settings.settingsWindowFrame = $0 },
            defaultContentSize: { screen in SettingsLayout.contentSize(forVisibleScreen: screen) },
            savesProgrammaticResizes: false,
            makesResizable: true))
    }

    /// The tabs in their order; „Texterkennung“, „Word/PowerPoint“ and „Speicher“ only with their settings.
    var shownTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            switch tab {
            case .ocr: ocr != nil
            case .office: office != nil
            case .storage: onDeleteIndex != nil || tileCache != nil
            default: true
            }
        }
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
                Toggle("Vorschaubreite an Zoom anpassen", isOn: $settings.previewFollowsZoom)
                    .accessibilityIdentifier("previewFollowsZoomToggle")
                Toggle("Zoom über die Fensterbreite hinaus erlauben", isOn: $settings.previewZoomBeyondWidth)
                    .accessibilityIdentifier("previewZoomBeyondWidthToggle")
            } header: {
                Text("Breite")
            } footer: {
                Text("Neben dem Raster wird die Vorschau so schmal wie die gezoomte Seite, höchstens so breit wie eingestellt; das Raster bekommt den Platz. Über die Breite hinaus: weiter zoomen und waagerecht scrollen.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Toggle("Tab erreicht auch das Suchfeld", isOn: $keyboard.tabIncludesSearch)
                    .accessibilityIdentifier("tabIncludesSearchToggle")
                Toggle("Tab erreicht auch die Vorschau", isOn: $keyboard.tabIncludesPreview)
                    .accessibilityIdentifier("tabIncludesPreviewToggle")
                Text(keyboard.tabOrderText() + (keyboard.tabIncludesSearch ? "" : " · ins Suchfeld mit ⌘F oder Klick"))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("tabOrderText")
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
                Toggle("Dateigröße hinter dem Dateinamen zeigen", isOn: $settings.showFileSize)
                    .accessibilityIdentifier("showFileSizeToggle")
                Toggle("Änderungsdatum hinter dem Dateinamen zeigen", isOn: $settings.showModifiedDate)
                    .accessibilityIdentifier("showModifiedDateToggle")
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
                Toggle("Auch Dateinamen durchsuchen", isOn: $settings.searchFileNames)
                    .help("Findet Dateien auch über ihren Namen (ohne Endung), mit denselben Regeln wie den Text")
                    .accessibilityIdentifier("searchFileNamesToggle")
                Picker("Wartezeit nach dem Tippen", selection: $settings.debounceMs) {
                    ForEach(GridSettings.debounceChoices, id: \.self) { ms in
                        Text(ms == GridSettings.debounceChoices[0] ? "\(ms) ms (Standard)" : "\(ms) ms").tag(ms)
                    }
                }
                .help("So lange wartet die Suche nach dem letzten Tastendruck")
                .accessibilityIdentifier("debouncePicker")
            }
        }
        .formStyle(.grouped)
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


/// Settings tab „Word/PowerPoint“ (1.3 Teil B Task 12): the Office switch, the PowerPoint display, the counts per
/// folder and „Folien-Cache leeren“.
struct OfficeTab: View {
    @Bindable var office: OfficePreferences
    let folders: [URL]
    let counts: ((URL) async -> LayoutCounts?)?
    @State private var clearAction: SlideCacheClearAction?

    init(office: OfficePreferences, folders: [URL], counts: ((URL) async -> LayoutCounts?)?,
         onClearSlideCache: (() async -> Void)?) {
        self.office = office
        self.folders = folders
        self.counts = counts
        _clearAction = State(initialValue: onClearSlideCache.map(SlideCacheClearAction.init))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Word- und PowerPoint-Dateien durchsuchen", isOn: $office.includeOffice)
                    .help("Aus: Word- und PowerPoint-Dateien werden nicht mehr aufgelistet; ihr Text wird aus dem Index entfernt")
            } footer: {
                Text(ViewerText.officeFormatsFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("PowerPoint-Darstellung", selection: $office.powerPointRenderer) {
                    Text("Eigener Viewer").tag(OfficeRendererChoice.slideKit)
                    Text("Quick Look (macOS)").tag(OfficeRendererChoice.quickLook)
                }
                .help("Wie Folien gezeichnet und gelesen werden. Wechselt dadurch die Darstellung, werden alle PowerPoint-Dateien neu eingelesen; bis dahin werden sie nicht gefunden.")
                Picker("Fehlende Schriften", selection: $office.fontSubstitution) {
                    Text("wie PowerPoint").tag(OfficeFontChoice.powerPoint)
                    Text("ähnliche Schrift").tag(OfficeFontChoice.similar)
                }
                .disabled(office.powerPointRenderer == .quickLook)
                .help("Nur für den eigenen Viewer (später auch für Word). „wie PowerPoint“ ersetzt fehlende Schriften wie PowerPoint (meist durch Calibri); Office-Schriften wie Garamond oder Century Gothic bekommen auch dann einen ähnlichen Ersatz.")
            } header: {
                Text("PowerPoint")
            } footer: {
                Text("„Fehlende Schriften“ gilt nur für den eigenen Viewer. Nach einem Wechsel werden PowerPoint-Dateien erst wieder gefunden, wenn sie neu eingelesen sind.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !folders.isEmpty {
                Section("Quellen") {
                    ForEach(folders, id: \.self) { folder in LayoutSourceRow(folder: folder, counts: counts) }
                }
            }
            if let clearAction {
                Section {
                    Button("Folien-Cache leeren") { Task { await clearAction.run() } }
                        .disabled(clearAction.isRunning)
                        .help("Löscht die gespeicherten Folienbilder (Quick Look) aller Quellen")
                } header: {
                    Text("Folien-Cache")
                } footer: {
                    Text(ViewerText.slideCacheFooter(office.powerPointRenderer))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// „Folien-Cache leeren“: runs the model's action once at a time; the button is disabled meanwhile.
@MainActor @Observable final class SlideCacheClearAction {
    private(set) var isRunning = false
    @ObservationIgnored private let action: () async -> Void

    init(_ action: @escaping () async -> Void) { self.action = action }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await action()
    }
}

/// One folder's Word/PowerPoint counts, refreshed every 2 s while the tab is open (like `OCRSourceRow`).
private struct LayoutSourceRow: View {
    let folder: URL
    let counts: ((URL) async -> LayoutCounts?)?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(folder.lastPathComponent)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task(id: folder.path) {
            while !Task.isCancelled {
                if let counts, let c = await counts(folder) { text = ViewerText.layoutCounts(c) }
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
