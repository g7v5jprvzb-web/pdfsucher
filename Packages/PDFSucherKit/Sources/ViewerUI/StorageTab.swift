// StorageTab.swift — settings tab „Speicher“: indexes, caches and protocols on disk, each with its size
import IndexKit
import SwiftUI

/// What the app measures and deletes for „Speicher“ beyond the index of a folder (1.3.10). Without it the tab shows
/// only the index, the tile cache and the protocols.
@MainActor public struct StorageActions {
    /// Size of the index of one folder or (nil) of all folders.
    public var indexBytes: (URL?) async -> Int
    /// Index files of folders no longer loaded.
    public var orphanIndexes: () async -> [URL]
    public var deleteOrphanIndexes: () async -> Void
    public var slideCacheBytes: () async -> Int
    /// Recognizes every recognized page of one folder or (nil) of all folders again.
    public var rerunOCR: (URL?) -> Void

    public init(indexBytes: @escaping (URL?) async -> Int, orphanIndexes: @escaping () async -> [URL],
                deleteOrphanIndexes: @escaping () async -> Void, slideCacheBytes: @escaping () async -> Int,
                rerunOCR: @escaping (URL?) -> Void) {
        self.indexBytes = indexBytes
        self.orphanIndexes = orphanIndexes
        self.deleteOrphanIndexes = deleteOrphanIndexes
        self.slideCacheBytes = slideCacheBytes
        self.rerunOCR = rerunOCR
    }
}

/// One line per thing on disk: its size and a button that deletes it after asking. Sources and settings are never
/// touched. „Je Quelle“ (index, OCR) follows the chosen folder; „Caches und Protokolle“ is for the whole app.
struct StorageTab: View {
    let folderSources: [URL]
    let onDeleteIndex: ((URL?) -> Void)?
    let tileCache: TileDiskCache?
    var storage: StorageActions?
    var ocrCounts: ((URL) async -> (pages: Int, images: Int)?)?
    var onClearSlideCache: (() async -> Void)?

    /// Folder for the index and OCR lines; nil = all folders.
    @State private var target: URL?
    @State private var sizes = Sizes()
    @State private var confirm: Item?
    @State private var running: Set<Item> = []
    /// 1.3.9: measurement log of the indexing (`IndexMetrics`), off by default.
    @AppStorage(IndexMetrics.defaultsKey) private var metricsEnabled = false
    /// 1.4.2: diagnosis log of the result rows (`RowDiagnostics`), off by default.
    @AppStorage(IndexMetrics.rowsDefaultsKey) private var rowDiagnosticsEnabled = false

    enum Item: String, Identifiable, CaseIterable {
        case ocr, orphans, slides, tiles, logs
        var id: String { rawValue }
    }

    struct Sizes {
        var index: Int?
        var ocr: (pages: Int, images: Int)?
        var orphans: [URL]?
        var orphanBytes: Int?
        var slides: Int?
        var tiles: Int?
        var logs: (count: Int, bytes: Int)?
    }

    private var canDeleteIndex: Bool { !folderSources.isEmpty }

    var body: some View {
        Form {
            Section {
                if folderSources.count > 1 {
                    Picker("Quelle", selection: $target) {
                        Text("Alle Ordner").tag(URL?.none)
                        ForEach(folderSources, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                    }
                }
                if let onDeleteIndex {
                    row("Textindex", value: storage == nil ? nil : Self.size(sizes.index), button: "Löschen …",
                        label: "Index löschen …", disabled: !canDeleteIndex,
                        help: SettingsView.deleteIndexHelp(canDelete: canDeleteIndex)) { onDeleteIndex(target) }
                }
                if storage != nil, ocrCounts != nil {
                    row("Texterkennung (OCR)", value: Self.ocrText(sizes.ocr), button: "Neu erkennen …",
                        label: "Texterkennung neu ausführen …", disabled: folderSources.isEmpty || running.contains(.ocr),
                        help: "Erkennt alle bisher erkannten Seiten und Bilder neu") { confirm = .ocr }
                }
            } header: {
                Text("Je Quelle")
            } footer: {
                Text("Nach dem Löschen wird der Index sofort neu aufgebaut. Die Dateien selbst bleiben unverändert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if storage != nil {
                    row("Verwaiste Indexe", value: Self.orphanText(sizes.orphans, bytes: sizes.orphanBytes),
                        button: "Löschen …", label: "Verwaiste Indexe löschen …",
                        disabled: (sizes.orphans ?? []).isEmpty || running.contains(.orphans),
                        help: "Indexe von Ordnern, die nicht mehr als Quelle geladen sind") { confirm = .orphans }
                    if onClearSlideCache != nil {
                        row("Folien-Cache (Word/PowerPoint)", value: Self.size(sizes.slides), button: "Leeren …",
                            label: "Folien-Cache leeren …", disabled: running.contains(.slides),
                            help: "Löscht die gespeicherten Folienbilder") { confirm = .slides }
                    }
                }
                if tileCache != nil {
                    row("Kachel-Cache (Seitenbilder)", value: Self.size(sizes.tiles), button: "Leeren …",
                        label: "Kachel-Cache leeren", disabled: running.contains(.tiles),
                        help: "Löscht die gespeicherten Seitenbilder. Sie entstehen beim nächsten Anzeigen neu.") { confirm = .tiles }
                }
                row("Mess-Protokolle", value: sizes.logs.map { Self.filesText($0.count, bytes: $0.bytes) } ?? "…",
                    button: "Löschen …", label: "Mess-Protokolle löschen …",
                    disabled: (sizes.logs?.count ?? 0) == 0 || running.contains(.logs),
                    help: "Löscht die Protokolldateien in ~/Library/Logs/PDFSucher") { confirm = .logs }
            } header: {
                Text("Caches und Protokolle")
            } footer: {
                Text("Belegt insgesamt: \(Self.size(total)). Quellen und Einstellungen bleiben beim Löschen immer erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Mess-Protokoll für Indizierung schreiben", isOn: $metricsEnabled)
                    .onChange(of: metricsEnabled) { _, on in IndexMetrics.shared.setEnabled(on) }
                    .accessibilityIdentifier("indexMetricsToggle")
                Toggle("Diagnose-Protokoll für Ergebniszeilen schreiben", isOn: $rowDiagnosticsEnabled)
                    .onChange(of: rowDiagnosticsEnabled) { _, on in IndexMetrics.rows.setEnabled(on) }
                    .accessibilityIdentifier("rowDiagnosticsToggle")
            } header: {
                Text("Messung")
            } footer: {
                Text("Dauer je Datei und Phase bzw. Aufbau der Ergebniszeilen, ohne Dateiinhalte und ohne Dateinamen: ~/Library/Logs/PDFSucher")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirm.map(question) ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button(actionTitle(item), role: .destructive) { run(item) }
            Button("Abbrechen", role: .cancel) {}
        } message: { item in
            Text(explanation(item))
        }
        .onChange(of: folderSources) { _, folders in
            // A removed folder must not stay picked (the model ignores it; the picker shows „Alle“ again).
            if let chosen = target, !folders.contains(chosen) { target = nil }
        }
        .task { await measureSlow() }
        .task(id: target) {
            // Index, OCR and protocols change while indexing runs (and after „Index löschen“): every 3 s while shown.
            while !Task.isCancelled {
                await measureFast()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Rows

    private func row(_ title: String, value: String?, button: String, label: String, disabled: Bool = false,
                     help: String, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let value { Text(value).monospacedDigit().foregroundStyle(.secondary) }
                Button(button, role: .destructive, action: action)
                    .disabled(disabled)
                    .help(help)
                    .accessibilityLabel(label)
            }
        }
    }

    private var targetName: String? {
        if let target { return "„\(target.lastPathComponent)“" }
        return folderSources.count == 1 ? "„\(folderSources[0].lastPathComponent)“" : nil
    }

    func question(_ item: Item) -> String {
        switch item {
        case .ocr: targetName.map { "Texterkennung von \($0) neu ausführen?" } ?? "Texterkennung aller \(folderSources.count) Ordner neu ausführen?"
        case .orphans: "\(sizes.orphans.map { Self.indexCount(Self.indexNames($0)) } ?? "Verwaiste Indexe") löschen?"
        case .slides: "Folien-Cache leeren?"
        case .tiles: "Kachel-Cache leeren?"
        case .logs: "Mess-Protokolle löschen?"
        }
    }

    func actionTitle(_ item: Item) -> String {
        switch item {
        case .ocr: "Neu erkennen"
        case .slides, .tiles: "Leeren"
        case .orphans, .logs: "Löschen"
        }
    }

    func explanation(_ item: Item) -> String {
        switch item {
        case .ocr: "Alle erkannten Seiten und Bilder werden neu erkannt. Bis dahin bleibt der bisher erkannte Text durchsuchbar."
        case .orphans: "Diese Indexe gehören zu Ordnern, die nicht mehr als Quelle geladen sind. Wird ein solcher Ordner wieder hinzugefügt, wird er neu indexiert."
        case .slides: "Die gespeicherten Folienbilder werden gelöscht. Word- und PowerPoint-Dateien werden bei Bedarf neu eingelesen."
        case .tiles: "Die gespeicherten Seitenbilder werden gelöscht. Sie entstehen beim nächsten Anzeigen neu."
        case .logs: "Alle Protokolldateien in ~/Library/Logs/PDFSucher werden gelöscht. Die Einstellung „Mess-Protokoll“ bleibt, wie sie ist."
        }
    }

    // MARK: Actions

    private func run(_ item: Item) {
        confirm = nil
        running.insert(item)
        Task {
            switch item {
            case .ocr: storage?.rerunOCR(target)
            case .orphans: await storage?.deleteOrphanIndexes()
            case .slides: await onClearSlideCache?()
            case .tiles:
                sizes.tiles = nil
                await tileCache?.removeAll()
            case .logs: await Task.detached(priority: .userInitiated) {
                IndexMetrics.shared.deleteLogs()
                IndexMetrics.rows.deleteLogs()
            }.value
            }
            running.remove(item)
            await measureSlow()
            await measureFast()
        }
    }

    // MARK: Measuring

    private func measureFast() async {
        if let storage { sizes.index = await storage.indexBytes(target) }
        if storage != nil, let ocrCounts {
            var pages = 0, images = 0
            for folder in folderSources where target == nil || target == folder {
                if let counts = await ocrCounts(folder) { pages += counts.pages; images += counts.images }
            }
            sizes.ocr = (pages, images)
        }
        sizes.logs = await Task.detached(priority: .utility) {
            let files = IndexMetrics.shared.logFiles() + IndexMetrics.rows.logFiles()
            return (files.count, Self.bytes(of: files))
        }.value
    }

    private func measureSlow() async {
        if let storage {
            let orphans = await storage.orphanIndexes()
            sizes.orphans = orphans
            sizes.orphanBytes = await Task.detached(priority: .utility) { Self.bytes(of: orphans) }.value
            if onClearSlideCache != nil { sizes.slides = await storage.slideCacheBytes() }
        }
        if let tileCache { sizes.tiles = await Task.detached(priority: .utility) { tileCache.byteCount }.value }
    }

    private var total: Int {
        (sizes.index ?? 0) + (sizes.orphanBytes ?? 0) + (sizes.slides ?? 0) + (sizes.tiles ?? 0) + (sizes.logs?.bytes ?? 0)
    }

    // MARK: Texts

    nonisolated static func size(_ bytes: Int?) -> String { bytes.map(SettingsView.tileCacheSize) ?? "…" }

    nonisolated static func bytes(of files: [URL]) -> Int {
        files.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0) }
    }

    nonisolated static func ocrText(_ counts: (pages: Int, images: Int)?) -> String {
        guard let counts else { return "…" }
        let pages = counts.pages == 1 ? "1 Seite" : "\(counts.pages) Seiten"
        let images = counts.images == 1 ? "1 Bild" : "\(counts.images) Bilder"
        return "\(pages), \(images)"
    }

    nonisolated static func filesText(_ count: Int, bytes: Int) -> String {
        count == 0 ? "keine" : "\(count == 1 ? "1 Datei" : "\(count) Dateien"), \(SettingsView.tileCacheSize(bytes))"
    }

    /// One index is up to four files (`.sqlite`, `-wal`, `-shm`, `-journal`): counted once.
    nonisolated static func indexNames(_ files: [URL]) -> Int {
        Set(files.map { $0.lastPathComponent.components(separatedBy: ".sqlite").first ?? $0.lastPathComponent }).count
    }

    nonisolated static func indexCount(_ count: Int) -> String { count == 1 ? "1 verwaisten Index" : "\(count) verwaiste Indexe" }

    nonisolated static func orphanText(_ files: [URL]?, bytes: Int?) -> String {
        guard let files, let bytes else { return "…" }
        let count = indexNames(files)
        return count == 0 ? "keine" : "\(count == 1 ? "1 Index" : "\(count) Indexe"), \(SettingsView.tileCacheSize(bytes))"
    }
}
