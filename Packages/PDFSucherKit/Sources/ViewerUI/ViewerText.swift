// ViewerText.swift — Task 4.3 (German UI copy, kept out of the views so it can be tested)
import Foundation
import SearchKit

public enum ViewerText {
    private static let german = Locale(identifier: "de_DE")

    /// Integer with German digit grouping, e.g. 3180 → "3.180".
    static func number(_ n: Int) -> String { n.formatted(.number.locale(german)) }

    /// Shown while a search runs longer than a moment (spec §4.2).
    public static let searching = "Suche läuft…"
    /// Shown while the print document is built in the background.
    public static let preparingPrint = "Druck wird vorbereitet…"

    /// "Gefunden in 3 Dokumenten, 21 Seiten" — usable by the app to fill `ViewerModel.summary`.
    public static func summary(hits: [DocumentHit]) -> String {
        guard !hits.isEmpty else { return "Keine Treffer" }
        let pages = hits.reduce(0) { $0 + $1.pageHits.count }
        let docs = hits.count == 1 ? "1 Dokument" : "\(number(hits.count)) Dokumenten"
        let pageText = pages == 1 ? "1 Seite" : "\(number(pages)) Seiten"
        return "Gefunden in \(docs), \(pageText)"
    }

    /// - Parameter recognitionOn: „Texterkennung“ is on; off, files without text are just „ohne Text“.
    public static func indexStatus(_ status: IndexStatus, recognitionOn: Bool = true) -> String? {
        switch status {
        case .none: nil
        case .building(let folder, let folders, let done, let total):
            folders > 1 ? "Index Ordner \(folder)/\(folders): \(number(done))/\(number(total))"
                        : "Index: wird aufgebaut (\(number(done))/\(number(total)))"
        case .recognizing(let folder, let folders, let done, let total):
            folders > 1 ? "Texterkennung Ordner \(folder)/\(folders): \(number(done))/\(number(total))"
                        : "Texterkennung \(number(done))/\(number(total))"
        case .upToDate: "Index: aktuell"
        case .problems(let failed, let noText):
            "Index: aktuell" + (failed.isEmpty ? "" : " · " + files(failed.count) + " nicht lesbar")
                + (noText.isEmpty ? "" : " · " + files(noText.count) + (recognitionOn ? " ohne erkannten Text" : " ohne Text"))
        case .unreachable: "Ordner nicht erreichbar · Suche im gespeicherten Index"
        }
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 Datei" : "\(number(n)) Dateien" }

    static func selection(count: Int) -> String {
        switch count {
        case 0: "Keine Seiten ausgewählt"
        case 1: "1 Seite ausgewählt"
        default: "\(number(count)) Seiten ausgewählt"
        }
    }

    /// Search hit: „<name> (<n> Treffer)“; browse entry (no page hits): „<name> (<n> Seiten)“, just the
    /// name while the page count is not known yet or the file is unreadable.
    static func rowHeader(_ hit: DocumentHit) -> String {
        let name = hit.url.lastPathComponent
        guard hit.pageHits.isEmpty else { return "\(name) (\(number(hit.totalMatches)) Treffer)" }
        guard !hit.isUnreadable, hit.pageCount > 0 else { return name }
        return "\(name) (\(pages(hit.pageCount)))"
    }

    static func pages(_ n: Int) -> String { n == 1 ? "1 Seite" : "\(number(n)) Seiten" }

    /// Summary while browsing (spec 1.1 §12): „1.234 Dateien, 25.310 Seiten“.
    public static func browseSummary(files: Int, pages: Int) -> String {
        (files == 1 ? "1 Datei" : "\(number(files)) Dateien") + ", " + self.pages(pages)
    }

    /// Row body of a file that cannot be read.
    static let unreadableRow = "nicht lesbar"
    /// Row body while the page count of a not yet indexed file is unknown.
    static let pagesPending = "Seiten werden gelesen …"

    /// Without a search term, match count and relevance mean nothing: they sort by folder.
    public static func browseSortMode(_ mode: SortMode) -> SortMode {
        mode == .matchCount || mode == .relevance ? .folder : mode
    }

    static func sortLabel(_ mode: SortMode, browsing: Bool) -> String {
        browsing && browseSortMode(mode) != mode ? sortLabel(mode) + " (ohne Suche: nach Ordner)" : sortLabel(mode)
    }

    /// Folder line next to a row header: the folder inside its source, with several sources prefixed
    /// by the source folder (for a single PDF: the folder it lies in).
    static func rowFolder(_ hit: DocumentHit, showSource: Bool) -> String {
        let inner = (hit.relativePath as NSString).deletingLastPathComponent
        guard showSource else { return inner }
        let isFileSource = hit.sourceRoot.standardizedFileURL.path == hit.url.standardizedFileURL.path
        let source = isFileSource ? hit.url.deletingLastPathComponent().lastPathComponent : hit.sourceRoot.lastPathComponent
        return inner.isEmpty ? source : source + "/" + inner
    }

    /// 1.2.2 §1: search history.
    static let historyTitle = "Letzte Suchbegriffe"
    static let historyEmpty = "Noch keine Suchbegriffe"
    static let historyClear = "Verlauf löschen"
    /// Toolbar menu „Quellen (n)“.
    static func sourcesTitle(count: Int) -> String { "Quellen (\(count))" }
    /// Shown over the whole window while files are dragged onto it.
    static let dropPrompt = "Zum Hinzufügen loslassen"

    /// Menu title: with a plain key (no ⌘/⌃/⌥, not usable as menu key equivalent) the key is named in it.
    public static func menuTitle(_ action: ShortcutAction, shortcut: KeyShortcut) -> String {
        shortcut.keyboardShortcut == nil ? "\(action.title) (\(shortcut.display))" : action.title
    }

    static func matchBadge(_ n: Int) -> String { n == 1 ? "1 Treffer" : "\(number(n)) Treffer" }

    /// Settings „Texterkennung“, per source (spec 1.2 §7).
    public static func ocrCounts(pages: Int, images: Int) -> String {
        guard pages > 0 || images > 0 else { return "Noch nichts erkannt" }
        return self.pages(pages) + " und " + (images == 1 ? "1 Bild" : "\(number(images)) Bilder") + " erkannt"
    }

    static let recognitionStopped = "Texterkennung angehalten"
    static let resumeRecognition = "Fortsetzen"

    /// Symbol before the row header: images get a photo symbol (spec 1.2 §5).
    static func rowSymbol(_ hit: DocumentHit) -> String? { hit.isImage ? "photo" : nil }
    /// Badge on a PDF page whose text was recognized (spec 1.2 §5).
    static let ocrBadge = "Texterkennung"
    static let imageLabel = "Bild"

    static func pageLabel(_ pageIndex: Int) -> String { "S. \(pageIndex + 1)" }

    static func sortLabel(_ mode: SortMode) -> String {
        switch mode {
        case .matchCount: "Trefferanzahl"
        case .relevance: "Relevanz"
        case .modifiedDate: "Änderungsdatum"
        case .fileName: "Dateiname"
        case .folder: "Ordner"
        }
    }

    static func tilePlaceholder(fileExists: Bool, folderUnreachable: Bool) -> String {
        if fileExists { return previewUnavailable }
        return folderUnreachable ? self.folderUnreachable : missingFile
    }

    static func noResults(query: String) -> String { "Keine Seite enthält „\(query)“." }

    static let missingFile = "Datei nicht mehr vorhanden"
    static let folderUnreachable = "Ordner nicht erreichbar"
    static let previewUnavailable = "Vorschau nicht verfügbar"
    static let noTextSection = "Kein Text erkannt (auch nicht durch die Texterkennung)"
    static let unreadableSection = "Nicht lesbar (beschädigt oder passwortgeschützt)"
    static func noTextSection(recognitionOn: Bool) -> String { recognitionOn ? noTextSection : "Ohne Text (Texterkennung ist aus)" }
    static let noFocusedPage = "Auf eine Trefferseite unten klicken, um sie hier groß anzuzeigen."
}
