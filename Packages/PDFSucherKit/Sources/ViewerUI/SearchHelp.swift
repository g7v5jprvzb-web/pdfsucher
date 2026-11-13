// SearchHelp.swift — 1.1 Task 12 (spec 1.1 §11): one source for the tooltip, the „?“ popover and
// Hilfe → Suchhilfe. Every example is a test against the real search (AppCoreTests).
import SearchKit
import SwiftUI

/// A search and the page texts it finds and does not find.
public struct HelpExample: Sendable, Hashable, CustomStringConvertible {
    public let query: String
    public var partialWords = false
    public let finds: [String]
    public var doesNotFind: [String] = []
    /// The texts as scanned pages (only an image, found by the text recognition, spec 1.2).
    public var asScan = false
    public var description: String { "„\(query)“\(partialWords ? " (Wortteile)" : "")\(asScan ? " (Scan)" : "")" }
}

public struct HelpEntry: Sendable {
    public let title: String
    /// One line of the tooltip, with an example.
    public let line: String
    /// The longer explanation in the help.
    public let detail: String
    public let examples: [HelpExample]
}

public enum SearchHelp {
    public static let entries: [HelpEntry] = [
        HelpEntry(title: "Ganzes Wort", line: "Vertrag – ganzes Wort (nicht „Vertragsende“)",
                  detail: "`Vertrag` findet „Vertrag“, nicht „Vertragsende“.",
                  examples: [HelpExample(query: "Vertrag", finds: ["Der Vertrag gilt."], doesNotFind: ["Das Vertragsende naht."])]),
        HelpEntry(title: "Wortanfang", line: "Vertrag* – Wortanfang („Vertrag“, „Vertragsende“)",
                  detail: "`Vertrag*` findet „Vertrag“ und „Vertragsende“.",
                  examples: [HelpExample(query: "Vertrag*", finds: ["Der Vertrag gilt.", "Das Vertragsende naht."],
                                         doesNotFind: ["Der Auftrag kommt."])]),
        HelpEntry(title: "Wortende", line: "*ende – Wortende („Ende“, „Vertragsende“)",
                  detail: "`*ende` findet „Ende“ und „Vertragsende“, nicht „Endergebnis“.",
                  examples: [HelpExample(query: "*ende", finds: ["Das Ende kommt.", "Das Vertragsende naht."],
                                         doesNotFind: ["Das Endergebnis steht."])]),
        HelpEntry(title: "Wortteil", line: "*trag* – Wortteil („Vertrag“, „Auftrag“, „Tragweite“)",
                  detail: "`*trag*` findet „Vertrag“, „Auftrag“ und „Tragweite“.",
                  examples: [HelpExample(query: "*trag*", finds: ["Der Vertrag gilt.", "Der Auftrag kommt.", "Von großer Tragweite."],
                                         doesNotFind: ["Die Miete steigt."])]),
        HelpEntry(title: "Schalter „Wortteile finden“", line: "„Wortteile finden“ an – jedes Wort wie *wort*",
                  detail: "Mit dem Schalter „Wortteile finden“ wird jedes Wort ohne `*` wie `*wort*` gesucht.",
                  examples: [HelpExample(query: "trag", partialWords: true, finds: ["Der Vertrag gilt.", "Der Auftrag kommt."],
                                         doesNotFind: ["Die Miete steigt."])]),
        HelpEntry(title: "Mehrere Wörter", line: "Miete Kündigung – alle Wörter auf derselben Seite",
                  detail: "`Miete Kündigung` findet Seiten, auf denen beide Wörter stehen.",
                  examples: [HelpExample(query: "Miete Kündigung", finds: ["Die Miete und die Kündigung."],
                                         doesNotFind: ["Nur die Miete.", "Nur die Kündigung."])]),
        HelpEntry(title: "Genaue Wortfolge", line: "\"neuer Vertrag\" – genau diese Wortfolge",
                  detail: "`\"neuer Vertrag\"` findet die Wörter genau in dieser Reihenfolge.",
                  examples: [HelpExample(query: "\"neuer Vertrag\"", finds: ["Ein neuer Vertrag liegt vor."],
                                         doesNotFind: ["Der Vertrag ist neuer."])]),
        HelpEntry(title: "Groß-/Kleinschreibung und Akzente", line: "müller – findet auch „MÜLLER“, „Muller“; ß = ss",
                  detail: "Groß-/Kleinschreibung und Akzente sind egal: `müller` findet „MÜLLER“ und „Muller“. `ß` und `ss` gelten als gleich.",
                  examples: [HelpExample(query: "müller", finds: ["Herr MÜLLER kommt.", "Herr Muller kommt."], doesNotFind: ["Herr Maier kommt."]),
                             HelpExample(query: "straße", finds: ["Lange Strasse 5.", "Lange Straße 5."]),
                             HelpExample(query: "strasse", finds: ["Lange Strasse 5.", "Lange Straße 5."])]),
        HelpEntry(title: "Getrennte Wörter", line: "Vertrag – findet auch am Zeilenende getrenntes „Ver-“ / „trag“",
                  detail: "Am Zeilenende getrennte Wörter („Ver-“ / „trag“) werden gefunden und markiert.",
                  examples: [HelpExample(query: "Vertrag", finds: ["Der Ver-\ntrag gilt."], doesNotFind: ["Die Miete steigt."])]),
        HelpEntry(title: "Kurze Wortteile", line: "*ab* – Wortteile unter 3 Buchstaben gehen, sind langsamer",
                  detail: "Wortteile mit weniger als 3 Buchstaben wie `*ab*` werden gefunden, die Suche ist dann aber langsamer.",
                  examples: [HelpExample(query: "*ab*", finds: ["Am Abend.", "Wir haben Zeit."], doesNotFind: ["Die Miete steigt."])]),
        HelpEntry(title: "Scans und Bilder", line: "Scans und Bilder (PNG, JPEG, HEIC, DNG) – Text wird automatisch erkannt",
                  detail: "Gescannte PDFs und Bilder werden im Hintergrund per Texterkennung gelesen (Einstellungen → Texterkennung) und danach wie normaler Text durchsucht und markiert. Gefunden wird nur, was erkannt wurde; schlechte Scans können Fehler enthalten.",
                  examples: [HelpExample(query: "Kündigung", finds: ["Kündigung zum Jahresende"], doesNotFind: ["Mietvertrag ohne Frist"], asScan: true)]),
        HelpEntry(title: "Nicht unterstützt", line: "Kein ODER/NICHT; Klammern und Sonderzeichen trennen Wörter (E-Mail = „E Mail“)",
                  detail: "ODER und NICHT gibt es nicht: sie werden als normale Wörter gesucht. Klammern und Sonderzeichen trennen Wörter: `(Vertrag)` und `Vertrag!` suchen wie `Vertrag`; `E-Mail` findet „E-Mail“ und „E Mail“, aber nicht „Email“. Handschrift wird nicht gezielt erkannt.",
                  examples: [HelpExample(query: "Vertrag!", finds: ["Der Vertrag gilt."]),
                             HelpExample(query: "(Vertrag)", finds: ["Der Vertrag gilt."], doesNotFind: ["Die Miete steigt."]),
                             HelpExample(query: "E-Mail", finds: ["Per E-Mail.", "Per E Mail."], doesNotFind: ["Per Email."]),
                             HelpExample(query: "Miete ODER Kündigung", finds: ["Miete oder Kündigung."],
                                         doesNotFind: ["Die Miete und die Kündigung."])]),
    ]

    /// The tooltip of the search field: one line per entry (spec §11).
    public static var tooltip: String {
        (entries.map(\.line) + ["Mehr: „?“ im Suchfeld oder Hilfe → Suchhilfe"]).joined(separator: "\n")
    }

    /// Keyboard part, from the current settings and bindings.
    @MainActor public static func keyboardLines(_ k: KeyboardSettings) -> [String] {
        var lines = ["⌘F: ins Suchfeld springen, Suchtext markieren"]
        if k.typeToSearch {
            lines += ["Tippen: geht direkt ins Suchfeld (Einstellung „Tippen sucht sofort“)",
                      "⌫: letzten Buchstaben löschen · ⌘⌫ / ⌥⌫: letztes Wort löschen",
                      "Esc: Suchfeld leeren"]
        } else {
            lines += ["Leertaste: Häkchen setzen/entfernen", "+ / −: Vorschau vergrößern / verkleinern"]
        }
        for action in ShortcutAction.allCases {
            let shortcut = k.shortcut(for: action)
            // Plain keys (e.g. ↩︎) belong to the search field while it has the focus.
            let note = shortcut.keyboardShortcut == nil ? " (außerhalb des Suchfelds)" : ""
            lines.append("\(shortcut.display): \(action.title)\(note)")
        }
        lines.append("Pfeiltasten: zwischen den Seiten wechseln · Tab: " + (k.tabSkipsSearch ? "Vorschau ↔ Trefferraster" : "Suchfeld → Vorschau → Trefferraster"))
        return lines
    }

    public static let sortLines: [String] = SortMode.allCases.map { mode in
        let text = switch mode {
        case .matchCount: "die meisten Treffer zuerst"
        case .relevance: "am besten passende Dokumente zuerst"
        case .modifiedDate: "zuletzt geänderte zuerst"
        case .fileName: "nach Dateiname"
        case .folder: "nach Quelle und Ordner, Unterordner nach ihrem Ordner"
        }
        return "\(ViewerText.sortLabel(mode)): \(text)"
    }
}

/// The help itself (popover of „?“, window Hilfe → Suchhilfe).
public struct SearchHelpView: View {
    let keyboard: KeyboardSettings

    public init(keyboard: KeyboardSettings) { self.keyboard = keyboard }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Suchhilfe").font(.title2.bold())
                ForEach(SearchHelp.entries, id: \.title) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline)
                        Text(.init(entry.detail)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Text("Tastatur").font(.headline)
                ForEach(SearchHelp.keyboardLines(keyboard), id: \.self) { Text($0) }
                Divider()
                Text("Sortierung").font(.headline)
                ForEach(SearchHelp.sortLines, id: \.self) { Text($0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 560)
        .accessibilityIdentifier("searchHelp")
    }
}
