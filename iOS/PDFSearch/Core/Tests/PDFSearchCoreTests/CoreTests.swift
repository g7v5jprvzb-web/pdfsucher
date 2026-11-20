import Foundation
import PDFKit
import Synchronization
import Testing
@testable import PDFSearchCore

@Suite("Textfaltung")
struct TextFoldingTests {
    @Test func foldsCaseAccentsAndWhitespace() {
        #expect(TextFolding.fold("  Vertrags-\nänderung   im\tBÜRO ") == "vertragsanderung im buro")
    }

    @Test func joinsHyphenatedLineBreakOnlyBeforeLowercase() {
        #expect(TextFolding.fold("Ver-\ntrag") == "vertrag")
        #expect(TextFolding.fold("Nord-\nSüd") == "nord- sud")
    }

    @Test func expandsLigaturesAndDropsSoftHyphen() {
        #expect(TextFolding.fold("O\u{FB03}ce Ver\u{00AD}trag") == "office vertrag")
    }

    @Test func termsAreFoldedAndUnique() {
        #expect(TextFolding.terms(of: "„Vertrag“ VERTRAG Miete") == ["vertrag", "miete"])
        #expect(TextFolding.terms(of: "   ").isEmpty)
    }

    @Test func countsNonOverlappingOccurrences() {
        #expect(TextFolding.occurrences(of: "aa", in: "aaaa") == 2)
        #expect(TextFolding.occurrences(of: "vertrag", in: "vertrag und mietvertrag") == 2)
        #expect(TextFolding.occurrences(of: "", in: "x") == 0)
    }
}

@Suite("Index")
struct IndexStoreTests {
    @Test func usesFullTextIndexWithTrigram() async throws {
        let store = try IndexStore()
        #expect(store.usesFullTextIndex)
    }

    @Test func storesAndRemovesFolders() async throws {
        let store = try IndexStore()
        let folder = try await store.addFolder(name: "Verträge", bookmark: Data([1, 2, 3]))
        try await store.store(FileEntry(relativePath: "a.pdf", kind: .pdf, size: 10, modified: 1), folderID: folder.id,
                              pages: ["Der Vertrag"], state: .indexed)
        #expect(try await store.folders().map(\.name) == ["Verträge"])
        #expect(try await store.folders().first?.bookmark == Data([1, 2, 3]))
        #expect(try await store.stats(folderID: folder.id) == FolderStats(pdfCount: 1))

        try await store.removeFolder(id: folder.id)
        #expect(try await store.folders().isEmpty)
        let result = try await SearchService(store: store).search(SearchRequest(text: "vertrag"))
        #expect(result.documents.isEmpty)
    }

    @Test func replacingAFileReplacesItsPages() async throws {
        let store = try IndexStore()
        let folder = try await store.addFolder(name: "F", bookmark: Data())
        let entry = FileEntry(relativePath: "a.pdf", kind: .pdf, size: 10, modified: 1)
        try await store.store(entry, folderID: folder.id, pages: ["alt"], state: .indexed)
        try await store.store(entry, folderID: folder.id, pages: ["neu"], state: .indexed)
        let service = SearchService(store: store)
        #expect(try await service.search(SearchRequest(text: "alt")).documents.isEmpty)
        #expect(try await service.search(SearchRequest(text: "neu")).documents.count == 1)
        #expect(try await store.files(inFolder: folder.id).count == 1)
    }
}

@Suite("Suche")
struct SearchTests {
    private func makeIndex() async throws -> (IndexStore, Int64, Int64) {
        let store = try IndexStore()
        let a = try await store.addFolder(name: "Verträge", bookmark: Data())
        let b = try await store.addFolder(name: "Belege", bookmark: Data())
        try await store.store(FileEntry(relativePath: "vertrag_2024.pdf", kind: .pdf, size: 1, modified: 100), folderID: a.id,
                              pages: ["Der Vertrag beginnt.", "Nichts hier.", "Vertrag, Vertrag und Mietvertrag."], state: .indexed)
        try await store.store(FileEntry(relativePath: "Unterordner/angebot.pdf", kind: .pdf, size: 1, modified: 300), folderID: a.id,
                              pages: ["Angebot zum VERTRÄG"], state: .indexed)
        try await store.store(FileEntry(relativePath: "IMG_2041.jpg", kind: .jpeg, size: 1, modified: 200), folderID: b.id,
                              pages: ["Rechnung gemäß Vertrag"], state: .indexed)
        try await store.store(FileEntry(relativePath: "kaputt.pdf", kind: .pdf, size: 1, modified: 1), folderID: b.id,
                              pages: [], state: .failed)
        return (store, a.id, b.id)
    }

    @Test func findsPagesGroupedByDocumentSortedByHits() async throws {
        let (store, _, _) = try await makeIndex()
        let result = try await SearchService(store: store).search(SearchRequest(text: "Vertrag"))
        #expect(result.documents.map(\.name) == ["vertrag_2024.pdf", "angebot.pdf", "IMG_2041.jpg"])
        let first = try #require(result.documents.first)
        #expect(first.pages == [PageHit(number: 1, count: 1), PageHit(number: 3, count: 3)])
        #expect(first.totalHits == 4)
        #expect(first.pageCount == 3)
        #expect(result.documents[1].subfolder == "Unterordner")
        #expect(result.pdfHitPageCount == 3)
        #expect(result.photos.count == 1)
    }

    @Test func findsWordParts() async throws {
        let (store, _, _) = try await makeIndex()
        let result = try await SearchService(store: store).search(SearchRequest(text: "mietver"))
        #expect(result.documents.map(\.name) == ["vertrag_2024.pdf"])
        #expect(result.documents.first?.pages.map(\.number) == [3])
    }

    @Test func shortTermsUseLikeAndAllTermsMustMatch() async throws {
        let (store, _, _) = try await makeIndex()
        let service = SearchService(store: store)
        #expect(try await service.search(SearchRequest(text: "zu")).documents.map(\.name) == ["angebot.pdf"])
        #expect(try await service.search(SearchRequest(text: "vertrag rechnung")).documents.map(\.name) == ["IMG_2041.jpg"])
        #expect(try await service.search(SearchRequest(text: "vertrag xyzxyz")).documents.isEmpty)
    }

    @Test func scopeAndKindFilter() async throws {
        let (store, a, b) = try await makeIndex()
        let service = SearchService(store: store)
        #expect(try await service.search(SearchRequest(text: "vertrag", scope: .folder(b))).documents.map(\.name) == ["IMG_2041.jpg"])
        #expect(try await service.search(SearchRequest(text: "vertrag", scope: .folder(a))).documents.count == 2)
        #expect(try await service.search(SearchRequest(text: "vertrag", kinds: [.jpeg])).documents.map(\.name) == ["IMG_2041.jpg"])
        #expect(try await service.search(SearchRequest(text: "vertrag", kinds: [.pdf])).documents.count == 2)
    }

    @Test func sortOrders() async throws {
        let (store, _, _) = try await makeIndex()
        let service = SearchService(store: store)
        #expect(try await service.search(SearchRequest(text: "vertrag", sort: .name)).documents.map(\.name)
                == ["angebot.pdf", "IMG_2041.jpg", "vertrag_2024.pdf"])
        #expect(try await service.search(SearchRequest(text: "vertrag", sort: .modified)).documents.map(\.name)
                == ["angebot.pdf", "IMG_2041.jpg", "vertrag_2024.pdf"])
    }

    @Test func emptyFieldListsAllReadableFiles() async throws {
        let (store, a, _) = try await makeIndex()
        let service = SearchService(store: store)
        let all = try await service.allFiles(sort: .name)
        // kaputt.pdf could not be read and is left out.
        #expect(all.documents.map(\.name) == ["angebot.pdf", "IMG_2041.jpg", "vertrag_2024.pdf"])
        #expect(all.terms.isEmpty)
        #expect(all.documents.allSatisfy { $0.pages.isEmpty })
        #expect(all.documents.last?.pageCount == 3)
        #expect(try await service.allFiles(sort: .hits).documents.map(\.name) == ["angebot.pdf", "IMG_2041.jpg", "vertrag_2024.pdf"])
        #expect(try await service.allFiles(scope: .folder(a), kinds: [.pdf], sort: .modified).documents.map(\.name)
                == ["angebot.pdf", "vertrag_2024.pdf"])
        #expect(try await service.allFiles(kinds: [.jpeg]).documents.map(\.name) == ["IMG_2041.jpg"])
        #expect(try await service.allFiles(kinds: []).documents.isEmpty)
    }

    @Test func specialCharactersAreSafe() async throws {
        let (store, _, _) = try await makeIndex()
        let service = SearchService(store: store)
        for text in ["\"", "a\"b\"c", "%", "_", "\\", "AND OR NOT", "*", "(vertrag"] {
            _ = try await service.search(SearchRequest(text: text))
        }
    }
}

final class ProgressLog: Sendable {
    private let log = Mutex<[Int]>([])
    func append(_ value: Int) { log.withLock { $0.append(value) } }
    var values: [Int] { log.withLock { $0 } }
}

@Suite("Indizieren")
struct IndexerTests {
    final class CountingExtractor: PageTextExtracting {
        private let reads = Mutex<[String]>([])
        var names: [String] { reads.withLock { $0 } }
        func pages(of file: ScannedFile) throws -> [String] {
            reads.withLock { $0.append(file.relativePath) }
            return try DefaultTextExtractor().pages(of: file)
        }
    }

    @Test func indexesPDFsInSubfoldersAndSkipsUnchanged() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.makePDF("vertrag.pdf", pages: ["Der Vertrag tritt in Kraft.", "Seite zwei ohne das Wort.", "Noch ein Vertrag."])
        try folder.makePDF("Ordner/Tief/angebot.pdf", pages: ["Angebot"])
        try Data("kein pdf".utf8).write(to: folder.file("notiz.txt"))
        try Data("kaputt".utf8).write(to: folder.file("kaputt.pdf"))

        let store = try IndexStore()
        let record = try await store.addFolder(name: "Test", bookmark: Data())
        let extractor = CountingExtractor()
        let indexer = Indexer(store: store, extractor: extractor)

        let first = try await indexer.index(folderID: record.id, root: folder.url)
        #expect(first.added == 2)
        #expect(first.failed == 1)
        #expect(Set(extractor.names) == ["vertrag.pdf", "Ordner/Tief/angebot.pdf", "kaputt.pdf"])

        let result = try await SearchService(store: store).search(SearchRequest(text: "vertrag"))
        #expect(result.documents.map(\.relativePath) == ["vertrag.pdf"])
        #expect(result.documents.first?.hitPageNumbers == [1, 3])

        let second = try await indexer.index(folderID: record.id, root: folder.url)
        #expect(second.unchanged == 3)
        #expect(extractor.names.count == 3)

        try folder.makePDF("vertrag.pdf", pages: ["Jetzt steht hier Miete."])
        try folder.setModified("vertrag.pdf", to: Date(timeIntervalSinceNow: 60))
        try FileManager.default.removeItem(at: folder.file("Ordner/Tief/angebot.pdf"))
        let third = try await indexer.index(folderID: record.id, root: folder.url)
        #expect(third.updated == 1)
        #expect(third.removed == 1)
        #expect(try await SearchService(store: store).search(SearchRequest(text: "vertrag")).documents.isEmpty)
        #expect(try await SearchService(store: store).search(SearchRequest(text: "miete")).documents.count == 1)
    }

    @Test func reportsProgress() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.makePDF("a.pdf", pages: ["eins"])
        try folder.makePDF("b.pdf", pages: ["zwei"])
        let store = try IndexStore()
        let record = try await store.addFolder(name: "Test", bookmark: Data())
        let seen = ProgressLog()
        try await Indexer(store: store).index(folderID: record.id, root: folder.url) { progress in
            seen.append(progress.processed)
        }
        #expect(seen.values == [0, 1, 2])
    }

    @Test func recognizesTextInJPEG() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.makeJPEG("IMG_0001.jpg", text: "Vertrag 4471")
        let store = try IndexStore()
        let record = try await store.addFolder(name: "Fotos", bookmark: Data())
        let summary = try await Indexer(store: store).index(folderID: record.id, root: folder.url)
        #expect(summary.added == 1)
        let result = try await SearchService(store: store).search(SearchRequest(text: "vertrag"))
        #expect(result.photos.map(\.name) == ["IMG_0001.jpg"])
    }

    @Test func locatesTermInImage() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let url = try folder.makeJPEG("IMG_0002.jpg", text: "Vertrag 4471")
        let image = try ImageLoading.cgImage(at: url, maxPixelSize: 2000)
        let analysis = try ImageTextLocator.analyze(image, terms: ["vertrag"])
        let match = try #require(analysis.matches.first)
        #expect(match.rect.minX >= 0 && match.rect.maxX <= 1)
        #expect(match.rect.minY >= 0 && match.rect.maxY <= 1)
        #expect(match.rect.minX < 0.5)
    }
}

@Suite("Ordner durchsuchen")
struct FolderScannerTests {
    @Test func listsOnlyPDFAndJPEGAndSkipsHidden() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.makePDF("A.pdf", pages: ["x"])
        try folder.makeJPEG("Fotos/B.JPEG", text: "x")
        try folder.makeJPEG("Fotos/C.jpg", text: "x")
        try folder.makePDF(".versteckt/D.pdf", pages: ["x"])
        try Data().write(to: folder.file("E.docx"))
        try Data().write(to: folder.file(".F.pdf.icloud"))

        let files = FolderScanner.scan(root: folder.url)
        #expect(files.map(\.relativePath) == ["A.pdf", "F.pdf", "Fotos/B.JPEG", "Fotos/C.jpg"])
        #expect(files.first { $0.relativePath == "F.pdf" }?.isDownloaded == false)
        #expect(files.first { $0.relativePath == "A.pdf" }?.isDownloaded == true)
        #expect(files.first { $0.relativePath == "Fotos/C.jpg" }?.kind == .jpeg)
    }

    @Test func stopsBelowMaximumDepth() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let deep = (1...11).map { "e\($0)" }.joined(separator: "/")
        try folder.makePDF("\(deep)/zu-tief.pdf", pages: ["x"])
        try folder.makePDF("e1/e2/ok.pdf", pages: ["x"])
        #expect(FolderScanner.scan(root: folder.url).map(\.relativePath) == ["e1/e2/ok.pdf"])
    }
}

@Suite("PDF erzeugen")
struct ComposerTests {
    @Test func combinesPDFPagesAndPhotosInOrder() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let pdf = try folder.makePDF("a.pdf", pages: ["Seite eins", "Seite zwei", "Seite drei"])
        let photo = try folder.makeJPEG("b.jpg", text: "Foto")
        let output = folder.file("out.pdf")
        let outcome = try PDFComposer.compose([
            ComposeItem(url: pdf, kind: .pdf, pageNumber: 3),
            ComposeItem(url: photo, kind: .jpeg, pageNumber: 1),
            ComposeItem(url: pdf, kind: .pdf, pageNumber: 1),
            ComposeItem(url: folder.file("fehlt.pdf"), kind: .pdf, pageNumber: 1),
        ], to: output)
        #expect(outcome == PDFComposer.Outcome(pageCount: 3, skipped: 1))
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.string?.contains("drei") == true)
        #expect(document.page(at: 2)?.string?.contains("eins") == true)
    }

    @Test func emptySelectionThrows() {
        #expect(throws: ComposeError.nothingToWrite) {
            try PDFComposer.compose([], to: URL(fileURLWithPath: "/tmp/never.pdf"))
        }
    }

    @Test func suggestedFileName() {
        #expect(PDFComposer.suggestedFileName(searchText: "Vertrag/2024", pageCount: 6) == "Vertrag-2024 – 6 Seiten.pdf")
        #expect(PDFComposer.suggestedFileName(searchText: " ", pageCount: 1) == "Auswahl – 1 Seite.pdf")
    }
}
