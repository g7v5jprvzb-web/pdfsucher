import Foundation
import SearchKit
import Testing
@testable import ViewerUI

/// Spec 1.1 §11: search help; tooltip and help from one source.
@MainActor @Suite("Search help")
struct SearchHelpTests {
    @Test func entriesFollowTheSpec() {
        #expect(SearchHelp.entries.map(\.title) == [
            "Ganzes Wort", "Wortanfang", "Wortende", "Wortteil", "Schalter „Wortteile finden“", "Mehrere Wörter",
            "Genaue Wortfolge", "Groß-/Kleinschreibung und Akzente", "Getrennte Wörter", "Kurze Wortteile", "Scans und Bilder", "Nicht unterstützt",
        ])
        #expect(SearchHelp.entries.allSatisfy { !$0.line.isEmpty && !$0.detail.isEmpty })
    }

    @Test func tooltipHasOneLinePerEntry() {
        let lines = SearchHelp.tooltip.split(separator: "\n").map(String.init)
        #expect(lines.count == SearchHelp.entries.count + 1)      // plus the pointer to „?“
        #expect(lines.last == "Mehr: „?“ im Suchfeld oder Hilfe → Suchhilfe")
    }

    @Test func tooltipAndHelpShareEntries() {
        let tooltip = SearchHelp.tooltip
        for entry in SearchHelp.entries {
            #expect(tooltip.contains(entry.line), "\(entry.title)")
        }
        #expect(SearchHelp.entries.first?.line == "Vertrag – ganzes Wort (nicht „Vertragsende“)")
    }

    @Test func keyboardLinesFollowRebinding() {
        let k = KeyboardSettings(defaults: UserDefaults(suiteName: "Help-\(UUID())")!)
        #expect(SearchHelp.keyboardLines(k).contains("⌘F: ins Suchfeld springen, Suchtext markieren"))
        #expect(SearchHelp.keyboardLines(k).contains("↩︎: Häkchen setzen/entfernen (außerhalb des Suchfelds)"))
        #expect(SearchHelp.keyboardLines(k).contains("Esc: Suchfeld leeren"))
        _ = k.set(KeyShortcut(key: "t", modifiers: .control), for: .toggleTick)
        #expect(SearchHelp.keyboardLines(k).contains("⌃T: Häkchen setzen/entfernen"))
        k.typeToSearch = false
        #expect(!SearchHelp.keyboardLines(k).contains("Esc: Suchfeld leeren"))
        #expect(SearchHelp.keyboardLines(k).contains("Leertaste: Häkchen setzen/entfernen"))
    }

    @Test func sortLinesCoverAllModes() {
        #expect(SearchHelp.sortLines.count == SortMode.allCases.count)
        #expect(SearchHelp.sortLines[0].hasPrefix("Trefferanzahl:"))
    }

    @Test func everyEntryHasExamplesExceptKeyboard() {
        #expect(SearchHelp.entries.allSatisfy { !$0.examples.isEmpty })
    }

    /// Spec 1.2: scans are no longer „nicht unterstützt“; the help names the recognition.
    @Test func helpDescribesRecognition() {
        let scans = SearchHelp.entries.first { $0.title == "Scans und Bilder" }
        #expect(scans?.line == "Scans und Bilder (PNG, JPEG, HEIC, DNG) – Text wird automatisch erkannt")
        #expect(scans?.examples.contains { $0.asScan } == true)
        #expect(!SearchHelp.entries.contains { $0.detail.contains("Version 2") || $0.line.contains("Scans ohne Text") })
    }

    @Test func problemCopy() {
        #expect(ViewerText.indexStatus(.problems(failed: ["a.png"], noText: [])) == "Index: aktuell · 1 Datei nicht lesbar")
        #expect(ViewerText.indexStatus(.problems(failed: [], noText: ["a.pdf", "b.png"])) == "Index: aktuell · 2 Dateien ohne erkannten Text")
        #expect(ViewerText.indexStatus(.problems(failed: ["a.png"], noText: ["b.pdf"])) == "Index: aktuell · 1 Datei nicht lesbar · 1 Datei ohne erkannten Text")
        #expect(ViewerText.noTextSection == "Kein Text erkannt (auch nicht durch die Texterkennung)")
        #expect(ViewerText.unreadableSection == "Nicht lesbar (beschädigt oder passwortgeschützt)")
        // Texterkennung off: nothing was recognized, so nothing claims it was tried (review of Task 6).
        #expect(ViewerText.indexStatus(.problems(failed: [], noText: ["a.pdf"]), recognitionOn: false) == "Index: aktuell · 1 Datei ohne Text")
        #expect(ViewerText.noTextSection(recognitionOn: false) == "Ohne Text (Texterkennung ist aus)")
        #expect(ViewerText.noTextSection(recognitionOn: true) == ViewerText.noTextSection)
    }
}

/// 1.2.1 §1: copy of the add prompt and the setting.
@Suite("Add prompt copy")
struct AddPromptCopyTests {
    @Test func copy() {
        #expect(AddPrompt(newItems: ["Rechnungen"], existing: 3).title == "„Rechnungen“ hinzufügen?")
        #expect(AddPrompt(newItems: ["a", "b", "c"], existing: 1).title == "3 Objekte hinzufügen?")
        #expect(AddPrompt(newItems: ["a"], existing: 3).message == "Sollen die neuen Quellen zusätzlich durchsucht werden oder die bisherigen 3 Quellen ersetzen?")
        #expect([AddPrompt.addTitle, AddPrompt.replaceTitle, AddPrompt.cancelTitle, AddPrompt.rememberTitle] == ["Zusätzlich", "Ersetzen", "Abbrechen", "Nicht mehr fragen"])
        #expect(AddSourcesPolicy.allCases.map(\.title) == ["Fragen", "Immer zusätzlich", "Immer ersetzen"])
    }

    @MainActor @Test func policyPersistsAndFallsBack() {
        let defaults = UserDefaults(suiteName: "AddPolicy-\(UUID())")!
        #expect(GridSettings(defaults: defaults).addSourcesPolicy == .ask)
        GridSettings(defaults: defaults).addSourcesPolicy = .replace
        #expect(GridSettings(defaults: defaults).addSourcesPolicy == .replace)
        defaults.set("immer", forKey: "sources.addPolicy")
        #expect(GridSettings(defaults: defaults).addSourcesPolicy == .ask)
    }
}
