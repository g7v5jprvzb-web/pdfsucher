import Foundation
import PDFKit
import SearchKit
import Testing
import TestSupport
@testable import AppCore

/// Highlights are computed on the live `PDFPage.string` (not the normalized index text):
/// PageMatcher runs on `TextNormalizer.normalizeMapped(text).text` and every match is mapped back.
@Suite("Highlighter")
struct HighlighterTests {
    private func marked(_ text: String, _ input: String, partialWords: Bool = false) -> [String] {
        let ranges = Highlighter.make(QueryParser.parse(input, partialWords: partialWords))?(text) ?? []
        return ranges.map { String(text[$0]) }
    }

    @Test func plainWordIsMarked() {
        #expect(marked("Der Vertrag und noch ein Vertrag.", "Vertrag") == ["Vertrag", "Vertrag"])
    }

    @Test func hyphenatedWordMarksBothLineParts() {
        #expect(marked("Der Ver-\ntrag gilt.", "Vertrag") == ["Ver-", "trag"])
        #expect(marked("Der Ver- \r\n  trag gilt.", "Vertrag") == ["Ver-", "trag"])
    }

    @Test func partOfHyphenatedWordMarksOnlyThatPart() {
        #expect(marked("Der Ver-\ntrag gilt.", "*trag*") == ["trag"])
    }

    @Test func ligatureWordIsMarkedWhole() {
        #expect(marked("Wir \u{FB01}nden es.", "finden") == ["\u{FB01}nden"])
    }

    @Test func decomposedUmlautMapsToOriginalCharacters() {
        #expect(marked("Herr Mu\u{0308}ller kommt.", "Müller") == ["Mu\u{0308}ller"])
    }

    @Test func emptyQueryHasNoHighlighter() {
        #expect(Highlighter.make(ParsedQuery(terms: [])) == nil)
    }

    @Test func matchesInsideOneLigatureGiveOneRange() {
        #expect(marked("Ka\u{FB00}ee", "*f*") == ["\u{FB00}"])
    }

    @Test func hyphenatedWordHighlightsBothParts() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("getrennt.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Dieser Ver-\ntrag beginnt heute."])
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let text = try #require(page.string)
        let highlight = try #require(Highlighter.make(QueryParser.parse("Vertrag", partialWords: false)))
        let ranges = highlight(text)
        let selections = ranges.compactMap { page.selection(for: NSRange($0, in: text)) }
        #expect(selections.count == 2)
        #expect(selections.first?.string?.contains("Ver") == true)
        #expect(selections.last?.string?.contains("trag") == true)
        // two separate lines on the page
        let boxes = selections.map { $0.bounds(for: page) }
        #expect(boxes.count == 2 && abs(boxes[0].midY - boxes[1].midY) > 5)
    }

    /// PDFKit's text extraction already turns this fixture's ﬁ into "fi" (no U+FB01 in
    /// `page.string`), so this only checks the word is marked on a real page; the mapping of a real
    /// ligature character is covered by `ligatureWordIsMarkedWhole`.
    @Test func ligatureWordHighlightedOnPDFPage() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("ligatur.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Wir \u{FB01}nden alles."])
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let text = try #require(page.string)
        let highlight = try #require(Highlighter.make(QueryParser.parse("finden", partialWords: false)))
        let ranges = highlight(text)
        #expect(ranges.count == 1)
        let selection = try #require(ranges.first.flatMap { page.selection(for: NSRange($0, in: text)) })
        #expect(selection.string?.replacingOccurrences(of: "\u{FB01}", with: "fi") == "finden")
    }
}
