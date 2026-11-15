import Foundation
import SearchKit
import SwiftUI
import Testing
@testable import ViewerUI

/// 1.3.2 Teil A: the row header of a file name hit — the hint „Treffer im Dateinamen“ (name only) and the query
/// highlighted in the name (name only and name + content), never in the extension or the counts.
@Suite("File name hit in the row header")
struct FileNameRowTests {
    let root = URL(fileURLWithPath: "/Akten", isDirectory: true)

    func hit(_ name: String, pages: [PageHit] = [], nameMatch: Bool) -> DocumentHit {
        DocumentHit(url: root.appendingPathComponent(name), relativePath: name, modifiedAt: .distantPast, pageHits: pages,
                    totalMatches: pages.reduce(0) { $0 + $1.matchCount }, relevance: 0, sourceRoot: root, pageCount: 3,
                    nameMatch: nameMatch)
    }

    let ranges: HighlightRanges = { PageMatcher(QueryParser.parse("rechnung", partialWords: false)).ranges(in: $0) ?? [] }

    func highlighted(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
    }

    @Test func hintOnlyForNameOnlyHits() {
        #expect(DocumentRow.showsNameHint(hit("Rechnung.pdf", nameMatch: true)))
        #expect(!DocumentRow.showsNameHint(hit("Rechnung.pdf", pages: [PageHit(pageIndex: 0, matchCount: 1)], nameMatch: true)))
        #expect(!DocumentRow.showsNameHint(hit("Rechnung.pdf", nameMatch: false)))
        #expect(ViewerText.nameHit == "Treffer im Dateinamen")
    }

    @Test func theNameIsHighlightedNotTheExtensionOrTheCount() {
        let text = DocumentRow.headerText(hit("Rechnung März.pdf", nameMatch: true), ranges: ranges, color: .yellow)
        #expect(String(text.characters) == "Rechnung März.pdf (3 Seiten)")
        #expect(highlighted(text) == ["Rechnung"])
        let both = DocumentRow.headerText(hit("Rechnung März.pdf", pages: [PageHit(pageIndex: 1, matchCount: 2)], nameMatch: true),
                                          ranges: ranges, color: .yellow)
        #expect(String(both.characters) == "Rechnung März.pdf (2 Treffer)")
        #expect(highlighted(both) == ["Rechnung"])
    }

    @Test func theExtensionIsNeverHighlighted() {
        let mappe: HighlightRanges = { PageMatcher(QueryParser.parse("mappe", partialWords: false)).ranges(in: $0) ?? [] }
        let text = DocumentRow.headerText(hit("Mappe.mappe", nameMatch: true), ranges: mappe, color: .yellow)
        #expect(highlighted(text) == ["Mappe"], "only the name, not the extension")
    }

    @Test func noHighlightWithoutANameMatch() {
        let text = DocumentRow.headerText(hit("Rechnung März.pdf", pages: [PageHit(pageIndex: 0, matchCount: 1)], nameMatch: false),
                                          ranges: ranges, color: .yellow)
        #expect(highlighted(text).isEmpty)
        #expect(highlighted(DocumentRow.headerText(hit("Rechnung.pdf", nameMatch: true), ranges: nil, color: .yellow)).isEmpty)
    }

    /// An unreadable or not yet laid out document found by its name: the hint, the name highlighted, and the body
    /// that browsing shows (error symbol or placeholder).
    @Test func unreadableOrPendingNameHitKeepsItsBody() {
        let broken = DocumentHit(url: root.appendingPathComponent("Rechnung.pdf"), relativePath: "Rechnung.pdf", modifiedAt: .distantPast,
                                 pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: root, pageCount: 0, isUnreadable: true,
                                 nameMatch: true)
        #expect(DocumentRow.showsNameHint(broken))
        #expect(ViewerText.rowHint(broken) == ViewerText.unreadableRow)
        #expect(highlighted(DocumentRow.headerText(broken, ranges: ranges, color: RGBA(r: 1, g: 1, b: 0, a: 1))) == ["Rechnung"])
        let pending = DocumentHit(url: root.appendingPathComponent("Rechnung.docx"), relativePath: "Rechnung.docx", modifiedAt: .distantPast,
                                  pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: root, pageCount: 0, kind: .word,
                                  nameMatch: true)
        #expect(DocumentRow.showsNameHint(pending))
        #expect(ViewerText.rowHint(pending) == ViewerText.layoutPending)
        #expect(RowPages.count(for: pending, showAll: false) == 0)
    }
}

