import Foundation
import IndexKit
import Testing
@testable import SearchKit

/// 1.3.2 Teil A: the file name (without its extension, without folders) is searched with the same rules as the
/// content; a document shows when its name OR its content matches.
@Suite("File name search")
struct FileNameSearchTests {
    let root = URL(fileURLWithPath: "/Volumes/Archiv/PDFs", isDirectory: true)

    private func index() throws -> TestIndex {
        let index = try TestIndex()
        try index.add("Rechnung März 2024.pdf", pages: ["Nur Zahlen 123"])
        try index.add("Verträge/Mietvertrag Büro.pdf", pages: ["Die Miete beträgt 900 Euro"])
        try index.add("Protokoll.pdf", pages: ["Die Rechnung kommt später"])
        try index.add("Rechnung-A_2023.pdf", pages: ["Rechnung A"])
        try index.add("Café Übersicht.pdf", pages: ["leer"])
        try index.add("kaputt Rechnung.pdf", pages: ["Rechnung"], status: .error)
        return index
    }

    private func search(_ input: String, partial: Bool = false, names: Bool = true, sort: SortMode = .fileName,
                        in index: TestIndex) throws -> [DocumentHit] {
        try SearchService(index: index, root: root)
            .search(QueryParser.parse(input, partialWords: partial), sort: sort, searchNames: names)
    }

    private func paths(_ hits: [DocumentHit]) -> [String] { hits.map(\.relativePath) }

    /// „Auch Dateiendung durchsuchen“: `pptx` finds the name and the extension; off, only the name.
    @Test func extensionWhenAsked() throws {
        let index = try TestIndex()
        try index.add("Angebot.pptx", pages: ["Folie"])
        try index.add("pptx_Notizen.pdf", pages: ["leer"])
        try index.add("Bericht.pdf", pages: ["leer"])
        let q = QueryParser.parse("pptx", partialWords: false)
        let service = SearchService(index: index, root: root)
        #expect(Set(paths(try service.search(q, sort: .fileName, searchNames: true, nameWithExtension: true)))
                == ["Angebot.pptx", "pptx_Notizen.pdf"])
        #expect(paths(try service.search(q, sort: .fileName, searchNames: true)) == ["pptx_Notizen.pdf"])
        #expect(paths(try service.search(q, sort: .fileName, searchNames: false, nameWithExtension: true)).isEmpty,
                "names off: the extension does not count either")
        #expect(DocumentHit.searchableName(of: "a/Angebot.pptx", withExtension: true) == "Angebot.pptx")
        #expect(DocumentHit.searchableName(of: "a/Angebot.pptx") == "Angebot")
    }

    @Test func nameOnlyContentOnlyAndBoth() throws {
        let hits = try search("rechnung", in: index())
        #expect(Set(paths(hits)) == ["Rechnung März 2024.pdf", "Protokoll.pdf", "Rechnung-A_2023.pdf", "kaputt Rechnung.pdf"])
        let nameOnly = try #require(hits.first { $0.relativePath == "Rechnung März 2024.pdf" })
        #expect(nameOnly.nameMatch && nameOnly.pageHits.isEmpty && nameOnly.totalMatches == 0)
        let contentOnly = try #require(hits.first { $0.relativePath == "Protokoll.pdf" })
        #expect(!contentOnly.nameMatch && contentOnly.pageHits == [PageHit(pageIndex: 0, matchCount: 1)])
        let both = try #require(hits.first { $0.relativePath == "Rechnung-A_2023.pdf" })
        #expect(both.nameMatch && both.pageHits == [PageHit(pageIndex: 0, matchCount: 1)])
    }

    @Test func caseUmlautsAndAccentsLikeTheContent() throws {
        let index = try index()
        try #expect(paths(search("MÄRZ", in: index)) == ["Rechnung März 2024.pdf"])
        try #expect(paths(search("cafe", in: index)) == ["Café Übersicht.pdf"])
        try #expect(paths(search("ubersicht", in: index)) == ["Café Übersicht.pdf"])
    }

    @Test func prefixInfixAndPhrase() throws {
        let index = try index()
        try #expect(paths(search("Miet*", in: index)) == ["Verträge/Mietvertrag Büro.pdf"], "prefix")
        try #expect(paths(search("vertrag", in: index)).isEmpty, "inside a word only with „Wortteile finden“")
        try #expect(paths(search("vertrag", partial: true, in: index)) == ["Verträge/Mietvertrag Büro.pdf"])
        try #expect(paths(search("\"Rechnung März\"", in: index)) == ["Rechnung März 2024.pdf"], "phrase")
    }

    @Test func notTheExtensionNotTheFolders() throws {
        let index = try index()
        try #expect(paths(search("pdf", in: index)).isEmpty, "the extension")
        try #expect(paths(search("Verträge", in: index)).isEmpty, "a folder name")
    }

    @Test func termsSplitBetweenNameAndContentDoNotMatch() throws {
        // „Protokoll“ only in the name, „später“ only in the content.
        try #expect(paths(search("Protokoll später", in: index())).isEmpty)
    }

    /// Chris, 2026-11-14: locked, unreadable and not yet laid out documents are found by their name too. Their row
    /// shows what browsing shows (error symbol or placeholder) with „Treffer im Dateinamen“; their content never.
    @Test func unreadableAndPendingDocumentsAreFoundByName() throws {
        let index = try index()
        try index.add("Rechnung ohne Text.pdf", pages: ["   "], status: .noText)
        try index.add("Rechnung Entwurf.pdf", pages: [])                  // page count not read yet
        let hits = try search("rechnung", in: index)
        let broken = try #require(hits.first { $0.relativePath == "kaputt Rechnung.pdf" })
        #expect(broken.nameMatch && broken.isUnreadable && broken.pageCount == 0 && broken.pageHits.isEmpty)
        let noText = try #require(hits.first { $0.relativePath == "Rechnung ohne Text.pdf" })
        #expect(noText.nameMatch && !noText.isUnreadable && noText.pageCount == 1)
        let pending = try #require(hits.first { $0.relativePath == "Rechnung Entwurf.pdf" })
        #expect(pending.nameMatch && !pending.isUnreadable && pending.pageCount == 0)
        // Their content is not searched: „kaputt“ is only in the error document's name, its stored text never counts.
        try #expect(search("Rechnung", names: false, in: index).allSatisfy { !$0.isUnreadable })
    }

    @Test func switchedOffSearchesContentOnly() throws {
        let hits = try search("rechnung", names: false, in: index())
        #expect(Set(paths(hits)) == ["Protokoll.pdf", "Rechnung-A_2023.pdf"])
        #expect(hits.filter(\.nameMatch).isEmpty)
    }

    @Test func byRelevanceNameHitsComeFirst() throws {
        let hits = try search("rechnung", sort: .relevance, in: index())
        #expect(hits.prefix(2).filter(\.nameMatch).count == 2, "\(paths(hits))")
        #expect(hits.last?.relativePath == "Protokoll.pdf")
    }

    @Test func otherSortsUnchanged() throws {
        let hits = try search("rechnung", sort: .fileName, in: index())
        #expect(paths(hits) == ["kaputt Rechnung.pdf", "Protokoll.pdf", "Rechnung März 2024.pdf", "Rechnung-A_2023.pdf"])
    }

    /// 10,000 names: the name part of a broad search stays in the milliseconds (spec §5: no FTS column needed).
    /// Measured 2026-11-14: 1.7 ms in a release build, 75 ms in the debug build these tests run in (more under the
    /// load of the full parallel run, hence 250 ms here).
    @Test func tenThousandNamesAreFast() throws {
        let documents = (0..<10_000).map { i in
            StoredDocument(id: Int64(i), relativePath: "Ordner\(i % 50)/Rechnung \(i) Vertrag Müller.pdf", fileSize: 1,
                           modifiedAt: .distantPast, pageCount: 1, status: .ok)
        }
        let matcher = PageMatcher(QueryParser.parse("ver*", partialWords: false))
        let clock = ContinuousClock()
        // Best of 5: the full parallel run loads every core (first run failed there once).
        let best = (0..<5).map { _ in clock.measure { _ = SearchService.nameMatches(documents, matcher: matcher) } }.min()!
        #expect(SearchService.nameMatches(documents, matcher: matcher).count == 10_000)
        #expect(best < .milliseconds(250), "name check of 10,000 files: \(best)")
    }

    // MARK: single files

    private struct Pages: TextSource {
        let texts: [String]
        func pages(of url: URL) throws -> [PageText] { texts.enumerated().map { PageText(pageIndex: $0.offset, text: $0.element) } }
    }

    @Test func aSingleFileMatchesByItsName() throws {
        let url = URL(fileURLWithPath: "/tmp/Rechnung März.pdf")
        let q = QueryParser.parse("rechnung", partialWords: false)
        let byName = try #require(try SingleDocumentSearch(source: Pages(texts: ["nichts"])).search(url: url, query: q, searchNames: true))
        #expect(byName.nameMatch && byName.pageHits.isEmpty && byName.pageCount == 1)
        #expect(try SingleDocumentSearch(source: Pages(texts: ["nichts"])).search(url: url, query: q, searchNames: false) == nil)
        let both = try #require(try SingleDocumentSearch(source: Pages(texts: ["Rechnung"])).search(url: url, query: q, searchNames: true))
        #expect(both.nameMatch && both.pageHits.count == 1)
    }

    /// A PDF without text cannot match by content, but its name can (no „kein Text“ error then).
    @Test func aFileWithoutTextStillMatchesByName() throws {
        let url = URL(fileURLWithPath: "/tmp/Rechnung Scan.pdf")
        let q = QueryParser.parse("rechnung", partialWords: false)
        let hit = try SingleDocumentSearch(source: Pages(texts: ["  "])).search(url: url, query: q, searchNames: true)
        #expect(hit?.nameMatch == true)
        #expect(throws: SingleDocumentSearchError.self) {
            try SingleDocumentSearch(source: Pages(texts: ["  "])).search(url: url, query: QueryParser.parse("anderes", partialWords: false),
                                                                       searchNames: true)
        }
    }
    /// A single file whose text cannot be read (locked, damaged) still matches by its name; the error is passed on with
    /// it unchanged; `nameMatches` lets the caller show the row by its name and still react to the error.
    @Test func anUnreadableSingleFileMatchesByName() throws {
        struct Locked: Error {}
        struct Failing: TextSource { func pages(of url: URL) throws -> [PageText] { throw Locked() } }
        let url = URL(fileURLWithPath: "/tmp/Rechnung gesperrt.pdf")
        let q = QueryParser.parse("rechnung", partialWords: false)
        #expect(SingleDocumentSearch.nameMatches(url, q))
        #expect(!SingleDocumentSearch.nameMatches(url, QueryParser.parse("anderes", partialWords: false)))
        #expect(throws: Locked.self) { try SingleDocumentSearch(source: Failing()).search(url: url, query: q, searchNames: true) }
    }
}
