import Testing
import Foundation
import PDFKit
import IndexKit
import TestSupport

@Suite("PDFKitTextSource")
struct PDFKitTextSourceTests {
    @Test func readsAllPages() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("three.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Erste Seite", "Zweite\nSeite", "Dritte ﬁnden"])
        let pages = try PDFKitTextSource().pages(of: url)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
        #expect(pages[0].text == "Erste Seite")
        #expect(pages[1].text == "Zweite Seite")
        #expect(pages[2].text.contains("finden"))
        #expect(pages.allSatisfy { $0.text == TextNormalizer.normalize($0.text) })
    }

    @Test func mappedPageTextMatchesStoredTextAndHighlightsBothLineParts() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("split.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Der Ver-\ntrag endet ﬁnal\nmit  Ende"])
        let stored = try PDFKitTextSource().pages(of: url)[0].text
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let pageString = try #require(page.string)
        let mapped = TextNormalizer.normalizeMapped(pageString)
        #expect(Array(mapped.text.utf16) == Array(stored.utf16))
        #expect(stored.contains("Vertrag"))

        let hit = (mapped.text as NSString).range(of: "Vertrag")
        let original = mapped.originalRange(for: hit)
        let selected = try #require(page.selection(for: original)?.string)
        #expect(selected.contains("Ver") && selected.contains("trag"))
        #expect(!selected.contains("Der") && !selected.contains("endet"))

        let ende = mapped.originalRange(for: (mapped.text as NSString).range(of: "Ende"))
        #expect(page.selection(for: ende)?.string == "Ende")
    }

    @Test func emptyPageGivesEmptyText() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.pdf")
        try PDFFixtures.makePDF(at: url, pages: [""])
        #expect(try PDFKitTextSource().pages(of: url) == [PageText(pageIndex: 0, text: "")])
    }

    @Test func throwsOnGarbage() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.pdf")
        try Data("not a pdf".utf8).write(to: url)
        #expect(throws: TextSourceError.unreadable(url)) { try PDFKitTextSource().pages(of: url) }
    }

    @Test func throwsOnMissingFile() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gone.pdf")
        #expect(throws: TextSourceError.unreadable(url)) { try PDFKitTextSource().pages(of: url) }
    }

    @Test func throwsOnTruncated() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.pdf")
        try PDFFixtures.makePDF(at: good, pages: ["Hallo"])
        let data = try Data(contentsOf: good)
        let url = dir.appendingPathComponent("cut.pdf")
        for fraction in [0.05, 0.6, 0.9] {
            try data.prefix(Int(Double(data.count) * fraction)).write(to: url)
            #expect(throws: TextSourceError.unreadable(url)) { try PDFKitTextSource().pages(of: url) }
        }
    }

    @Test func throwsOnLocked() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.pdf")
        try PDFFixtures.makePDF(at: plain, pages: ["Geheim"])
        let doc = try #require(PDFDocument(url: plain))
        let url = dir.appendingPathComponent("locked.pdf")
        #expect(doc.write(to: url, withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "y"]))
        #expect(throws: TextSourceError.locked(url)) { try PDFKitTextSource().pages(of: url) }
    }

    @Test func ownerPasswordOnlyIsReadable() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.pdf")
        try PDFFixtures.makePDF(at: plain, pages: ["Offen lesbar"])
        let doc = try #require(PDFDocument(url: plain))
        let url = dir.appendingPathComponent("owner.pdf")
        #expect(doc.write(to: url, withOptions: [.ownerPasswordOption: "y"]))
        #expect(try PDFKitTextSource().pages(of: url).first?.text == "Offen lesbar")
    }
}
