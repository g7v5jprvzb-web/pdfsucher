import AppKit
import Foundation
import IndexKit
import SearchKit
import SwiftUI
import Testing
@testable import ViewerUI

/// Spec 1.3 §8a: the „Dateitypen“ filter — the pure filter, its setting, the button title and the menu.
@MainActor @Suite("File type filter")
struct FileKindsFilterTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "FileKinds-\(UUID())")! }

    func hit(_ name: String, _ kind: DocumentKind) -> DocumentHit {
        let root = URL(fileURLWithPath: "/docs", isDirectory: true)
        return DocumentHit(url: root.appendingPathComponent(name), relativePath: name, modifiedAt: .distantPast,
                           pageHits: [PageHit(pageIndex: 0, matchCount: 1)], totalMatches: 1, relevance: 0,
                           sourceRoot: root, pageCount: 1, kind: kind)
    }

    var mixed: [DocumentHit] {
        [hit("a.pdf", .pdf), hit("b.docx", .word), hit("c.pptx", .powerpoint), hit("d.jpg", .image), hit("e.pdf", .pdf)]
    }

    // MARK: FileKindFilter (pure)

    @Test func filterKeepsOrderAndOnlyChosenKinds() {
        let filter = FileKindFilter(kinds: [.pdf, .word])
        #expect(filter.apply(mixed).map(\.relativePath) == ["a.pdf", "b.docx", "e.pdf"])
        #expect(filter.includes(hit("x.docx", .word)))
        #expect(!filter.includes(hit("x.jpg", .image)))
        #expect(filter.includes(.pdf) && !filter.includes(.powerpoint))
        #expect(FileKindFilter.all.apply(mixed) == mixed)
        #expect(FileKindFilter.all.isAll && !filter.isAll)
    }

    @Test func emptyFilterMeansAll() {
        #expect(FileKindFilter(kinds: []) == .all, "a filter never hides everything")
    }

    @Test func combinationsFilter() {
        let kinds = GridSettings.allFileKinds
        var count = 0
        for mask in 1..<(1 << kinds.count) {
            let chosen = Set(kinds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let shown = FileKindFilter(kinds: chosen).apply(mixed)
            #expect(shown.allSatisfy { chosen.contains($0.kind) })
            #expect(shown.count == mixed.filter { chosen.contains($0.kind) }.count)
            count += 1
        }
        #expect(count == 15)
    }

    @Test func labelNamesTheSelection() {
        #expect(FileKindFilter(kinds: [.image]).label == "Bilder")
        #expect(FileKindFilter.all.label == "Dateitypen")
    }

    // MARK: GridSettings

    @Test func defaultAllKinds() {
        let s = GridSettings(defaults: defaults())
        #expect(s.fileKinds == Set(GridSettings.allFileKinds))
        #expect(GridSettings.allFileKinds == [.pdf, .word, .powerpoint, .image])
    }

    @Test func persistsKinds() {
        let d = defaults()
        let s = GridSettings(defaults: d)
        s.toggleFileKind(.powerpoint)
        s.toggleFileKind(.image)
        #expect(s.fileKinds == [.pdf, .word])
        #expect(GridSettings(defaults: d).fileKinds == [.pdf, .word])
        #expect(Set(d.stringArray(forKey: "filter.kinds") ?? []) == ["pdf", "word"])
        d.set(["bogus"], forKey: "filter.kinds")
        #expect(GridSettings(defaults: d).fileKinds == Set(GridSettings.allFileKinds), "invalid: all")
        d.set([String](), forKey: "filter.kinds")
        #expect(GridSettings(defaults: d).fileKinds == Set(GridSettings.allFileKinds), "empty: all")
        d.set(["image", "bogus"], forKey: "filter.kinds")
        #expect(GridSettings(defaults: d).fileKinds == [.image])
    }

    @Test func lastKindStaysChecked() {
        let s = GridSettings(defaults: defaults())
        for kind in [DocumentKind.pdf, .word, .powerpoint] { s.toggleFileKind(kind) }
        #expect(s.fileKinds == [.image])
        s.toggleFileKind(.image)
        #expect(s.fileKinds == [.image], "the last tick stays")
        s.fileKinds = []
        #expect(s.fileKinds == [.image], "never empty")
        s.toggleFileKind(.word)
        #expect(s.fileKinds == [.image, .word])
    }

    // MARK: Title

    @Test func titleShowsSelection() {
        #expect(ViewerText.fileKindsTitle(Set(GridSettings.allFileKinds)) == "Dateitypen")
        #expect(ViewerText.fileKindsTitle([.word, .pdf]) == "PDF, Word")
        #expect(ViewerText.fileKindsTitle([.image]) == "Bilder")
        #expect(ViewerText.fileKindsTitle([.image, .powerpoint, .pdf]) == "PDF, PowerPoint, Bilder")
    }

    // MARK: Menu

    func width<V: View>(_ view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
    }

    /// The menu sits in the view controls (`ToolbarArea`) and takes its font from there (`toolbarFontSize`):
    /// it has no font size of its own.
    @Test func menuUsesToolbarFont() {
        let settings = GridSettings(defaults: defaults())
        let small = width(FileKindsMenu(settings: settings).font(.system(size: 10)).controlSize(ToolbarScale.controlSize(10)))
        let large = width(FileKindsMenu(settings: settings).font(.system(size: 20)).controlSize(ToolbarScale.controlSize(20)))
        #expect(small > 0)
        #expect(large > small, "the menu follows the toolbar font (\(small) → \(large))")

        // In the view controls line: a longer title widens the line.
        let all = width(GridControls(settings: settings))
        settings.toggleFileKind(.image)
        let three = width(GridControls(settings: settings))
        #expect(three > all, "„PDF, Word, PowerPoint“ is wider than „Dateitypen“ (\(all) → \(three))")
    }

    // MARK: Review fixes

    @Test func showAllFileKindsTicksEverything() {
        let s = GridSettings(defaults: defaults())
        s.fileKinds = [.image]
        s.showAllFileKinds()
        #expect(s.fileKinds == Set(GridSettings.allFileKinds))
    }

    @Test func hiddenTexts() {
        #expect(ViewerText.hiddenByFilter(1, browsing: true) == "1 Datei ausgeblendet")
        #expect(ViewerText.hiddenByFilter(3, browsing: true) == "3 Dateien ausgeblendet")
        #expect(ViewerText.hiddenByFilter(1, browsing: false) == "1 Dokument mit Treffern ausgeblendet")
        #expect(ViewerText.hiddenByFilter(1200, browsing: false) == "1.200 Dokumente mit Treffern ausgeblendet")
        #expect(ViewerText.withHidden("Keine Treffer", hidden: 2) == "Keine Treffer · 2 ausgeblendet")
        #expect(ViewerText.withHidden("Keine Treffer", hidden: 0) == "Keine Treffer")
        #expect(ViewerText.hiddenByFilterDetail([.image]) == "Der Filter „Dateitypen“ zeigt nur: Bilder.")
    }

    /// Review (Important): the empty grid tells that the filter hides everything instead of „Keine PDFs“/„Keine Treffer“.
    @Test func emptyStateWhenFilterHidesEverything() {
        typealias S = EmptyGridState
        #expect(S.make(hasHits: true, hasSources: true, browsing: true, hiddenByFilter: 3) == nil)
        #expect(S.make(hasHits: false, hasSources: false, browsing: true, hiddenByFilter: 0) == .noSources)
        #expect(S.make(hasHits: false, hasSources: true, browsing: true, hiddenByFilter: 0) == .noFiles)
        #expect(S.make(hasHits: false, hasSources: true, browsing: false, hiddenByFilter: 0) == .noResults)
        #expect(S.make(hasHits: false, hasSources: true, browsing: true, hiddenByFilter: 4) == .hiddenByFilter(4, browsing: true))
        #expect(S.make(hasHits: false, hasSources: true, browsing: false, hiddenByFilter: 2) == .hiddenByFilter(2, browsing: false))
    }

    /// The hidden state shows a button that switches every kind back on.
    @Test func hiddenEmptyStateRenders() {
        let settings = GridSettings(defaults: defaults())
        settings.fileKinds = [.image]
        let view = HiddenByFilterView(count: 2, browsing: false, settings: settings)
        #expect(width(view) > 0)
    }
}
