// ViewerText.swift — Task 4.3 (German UI copy, kept out of the views so it can be tested)
import Foundation
import IndexKit
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
        case .layingOut(let folder, let folders, let done, let total):
            folders > 1 ? "Word/PowerPoint Ordner \(folder)/\(folders): \(number(done))/\(number(total))"
                        : "Word/PowerPoint \(number(done))/\(number(total))"
        case .preparingWordParts(let folder, let folders, let done, let total):
            (folders > 1 ? "Ordner \(folder)/\(folders): " : "") + "Wortteil-Suche wird vorbereitet … (\(percent(done, total)) %)"
        case .upToDate: "Index: aktuell"
        case .problems(let failed, let noText):
            "Index: aktuell" + (failed.isEmpty ? "" : " · " + files(failed.count) + " nicht lesbar")
                + (noText.isEmpty ? "" : " · " + files(noText.count) + (recognitionOn ? " ohne erkannten Text" : " ohne Text"))
        case .unreachable: "Ordner nicht erreichbar · Suche im gespeicherten Index"
        }
    }

    static func percent(_ done: Int, _ total: Int) -> Int { total > 0 ? min(100, done * 100 / total) : 0 }

    /// Behind the summary of a search for word parts (`*ab*`, `*ab`) while the Wortteil-Index is being built (1.3.12).
    public static let wordPartsSlow = "Wortteil-Suche kann gerade langsamer sein"

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

    /// Behind the row header (1.3.7): „2,4 MB · 14.11.2026, 09:12“, each part only when switched on and known;
    /// nil when nothing is shown.
    static func rowDetails(_ hit: DocumentHit, showSize: Bool, showDate: Bool) -> String? {
        var parts: [String] = []
        if showSize, let size = hit.fileSize { parts.append(fileSize(size)) }
        if showDate, hit.modifiedAt.timeIntervalSince1970 > 0 { parts.append(modifiedDate(hit.modifiedAt)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// File size as Finder shows it, German: „2,4 MB“, „830 KB“.
    static func fileSize(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(german)) }

    /// Date and time, German: „14.11.2026, 09:12“.
    static func modifiedDate(_ date: Date) -> String {
        // Fixed pattern: `.shortened` gives „9:12“ in German, we want Finder-style „09:12“.
        date.formatted(.verbatim("\(day: .twoDigits).\(month: .twoDigits).\(year: .defaultDigits), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                 locale: german, timeZone: .current, calendar: .current))
    }

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

    /// Ordnerleiste.
    static let folderSourcesSection = "Quellen"
    static let folderPlacesSection = "Orte"
    static let allSources = "Alle Quellen"
    static let revealInFinder = "Im Finder zeigen"
    static let removeAsSource = "Als Quelle entfernen"
    /// Ordnerleiste and „Quellen (n)“: deletes the folder's index after asking, then indexes again.
    static let rebuildIndex = "Index löschen und neu aufbauen …"
    static let clearFolderFilter = "Ordnerfilter aufheben"
    static let showFolderBar = "Ordnerleiste einblenden"
    static let hideFolderBar = "Ordnerleiste ausblenden"
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

    /// Settings „Word/PowerPoint“: footer of the first section, every format read.
    static let officeFormatsFooter = "Liest .docx, .docm, .dotx, .doc, .pptx und .pptm ohne Microsoft Office. Doppelklick öffnet das Original."

    /// Settings „Folien-Cache“ footer: the cache serves Quick Look only.
    static func slideCacheFooter(_ renderer: OfficeRendererChoice) -> String {
        switch renderer {
        case .quickLook: "Nur für Quick Look: Folienbilder werden beim nächsten Durchlauf neu erzeugt."
        case .slideKit: "Der eigene Viewer braucht keine Folienbilder: Leeren gibt nur Speicherplatz frei (Bilder aus Quick Look)."
        }
    }

    /// Settings „Word/PowerPoint“, per folder (1.3 Teil B Task 12): „12 Word-Dateien gelesen, 1 nicht lesbar ·
    /// 30 PowerPoint-Dateien gelesen · 4 warten“; a kind without files is left out, none read → „2 PowerPoint-Dateien nicht lesbar“; nothing at all → „Keine Word- oder
    /// PowerPoint-Dateien“.
    public static func layoutCounts(_ c: LayoutCounts) -> String {
        func kind(_ name: String, read: Int, failed: Int) -> String? {
            func files(_ n: Int) -> String { n == 1 ? "1 \(name)-Datei" : "\(number(n)) \(name)-Dateien" }
            switch (read, failed) {
            case (0, 0): return nil
            case (0, _): return files(failed) + " nicht lesbar"
            case (_, 0): return files(read) + " gelesen"
            default: return files(read) + " gelesen, \(number(failed)) nicht lesbar"
            }
        }
        let parts = [kind("Word", read: c.wordRead, failed: c.wordFailed),
                     kind("PowerPoint", read: c.powerpointRead, failed: c.powerpointFailed),
                     c.waiting > 0 ? (c.waiting == 1 ? "1 wartet" : "\(number(c.waiting)) warten") : nil].compactMap { $0 }
        return parts.isEmpty ? "Keine Word- oder PowerPoint-Dateien" : parts.joined(separator: " · ")
    }

    static let recognitionStopped = "Texterkennung angehalten"
    static let resumeRecognition = "Fortsetzen"

    /// Symbol before the row header: images get a photo symbol (spec 1.2 §5), Word and PowerPoint their own
    /// (1.3 Teil B); PDFs none.
    static func rowSymbol(_ hit: DocumentHit) -> String? {
        switch hit.kind {
        case .pdf: nil
        case .image: "photo"
        case .word: "doc.richtext"
        case .powerpoint: "rectangle.inset.filled.on.rectangle"
        }
    }
    /// Name of a document kind (VoiceOver label of the row symbol, file type filter).
    static func kindLabel(_ kind: DocumentKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .word: "Word"
        case .powerpoint: "PowerPoint"
        case .image: "Bild"
        }
    }
    /// Name of a kind in the „Dateitypen“ menu and its title (spec 1.3 §8a): images are „Bilder“.
    static func fileKindLabel(_ kind: DocumentKind) -> String { kind == .image ? "Bilder" : kindLabel(kind) }
    /// Title of the „Dateitypen“ menu: „Dateitypen“ while every kind is shown, else the shown kinds in menu
    /// order („PDF, Word“).
    static func fileKindsTitle(_ kinds: Set<DocumentKind>) -> String {
        let all = GridSettings.allFileKinds
        guard !kinds.isSuperset(of: all), !kinds.isEmpty else { return fileKindsMenu }
        return all.filter(kinds.contains).map(fileKindLabel).joined(separator: ", ")
    }
    static let fileKindsMenu = "Dateitypen"
    /// Empty grid while the filter hides every result (review of Task 11).
    static func hiddenByFilter(_ n: Int, browsing: Bool) -> String {
        browsing ? (n == 1 ? "1 Datei ausgeblendet" : "\(number(n)) Dateien ausgeblendet")
                 : (n == 1 ? "1 Dokument mit Treffern ausgeblendet" : "\(number(n)) Dokumente mit Treffern ausgeblendet")
    }
    static func hiddenByFilterDetail(_ kinds: Set<DocumentKind>) -> String {
        "Der Filter „\(fileKindsMenu)“ zeigt nur: \(fileKindsTitle(kinds))."
    }
    static let showAllFileKinds = "Alle Dateitypen zeigen"
    /// „Nur Word“ in the „Dateitypen“ menu.
    static func onlyFileKind(_ kind: DocumentKind) -> String { "Nur \(fileKindLabel(kind))" }
    /// A summary with the count of documents the file type filter hides („… · 2 ausgeblendet“).
    public static func withHidden(_ summary: String, hidden: Int) -> String {
        hidden > 0 ? "\(summary) · \(number(hidden)) ausgeblendet" : summary
    }
    static let fileKindsHelp = "Nur Dateien dieser Typen zeigen (Suche und Durchblättern); mindestens ein Typ bleibt an. Im Suchfeld geht auch „typ:word“ (pdf, word, ppt, bild)"
    /// Hint next to the header of a document found by its file name only (spec 1.3.2 §2).
    static let nameHit = "Treffer im Dateinamen"
    static let nameHitHelp = "Der Suchbegriff steht im Dateinamen, nicht im Text. Die Reihe zeigt die Seiten wie beim Durchblättern."
    /// Hint next to the header of a document drawn in simplified form (renderer `textkit`, 1.3 Teil B).
    static let simplified = "vereinfacht"
    static let simplifiedHelp = "Vereinfachte Darstellung: Kopf- und Fußzeilen, Bilder und Formatvorlagen fehlen; der Text ist vollständig durchsuchbar."
    /// Row body of a Word/PowerPoint file whose pages are not laid out yet (page count 0).
    static let layoutPending = "Wird für die Anzeige vorbereitet …"
    /// Row body when a row has no tiles: unreadable, Office not laid out yet, or page count not read yet.
    static func rowHint(_ hit: DocumentHit) -> String {
        if hit.isUnreadable { return unreadableRow }
        return hit.kind.isOffice && hit.pageCount == 0 ? layoutPending : pagesPending
    }
    /// Tooltip of a tile: Office files open in their own app on double click.
    static func tileHelp(kind: DocumentKind) -> String {
        "Klick: groß anzeigen · Doppelklick: " + (kind.isOffice ? "Original öffnen" : "in Vorschau öffnen")
    }
    /// Badge on a PDF page whose text was recognized (spec 1.2 §5).
    static let ocrBadge = "Texterkennung"

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
    /// A Word/PowerPoint page not laid out yet (1.3 Teil B).
    static let previewPreparing = "Vorschau wird vorbereitet …"
    /// The detail view's open button: Office files open in their own app (1.3 Teil B), the rest in Preview.
    static func openOriginal(kind: DocumentKind) -> String {
        switch kind {
        case .word, .powerpoint: "Original öffnen"
        case .pdf, .image: "In Vorschau öffnen"
        }
    }
    static let noTextSection = "Kein Text erkannt (auch nicht durch die Texterkennung)"
    static let unreadableSection = "Nicht lesbar (beschädigt oder passwortgeschützt)"
    static func noTextSection(recognitionOn: Bool) -> String { recognitionOn ? noTextSection : "Ohne Text (Texterkennung ist aus)" }
    static let noFocusedPage = "Auf eine Trefferseite unten klicken, um sie hier groß anzuzeigen."
}
