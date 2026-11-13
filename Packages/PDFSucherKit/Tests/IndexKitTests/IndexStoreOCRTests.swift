import Foundation
@testable import IndexKit
import Testing
import TestSupport

@Suite("IndexStore OCR data (schema 2)")
struct IndexStoreOCRTests {
    private let root = URL(fileURLWithPath: "/tmp/PDFSucherRoot", isDirectory: true)

    private func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 1_700_000_000) -> ScannedFile {
        ScannedFile(relativePath: path, url: root.appendingPathComponent(path), fileSize: size,
                    modifiedAt: Date(timeIntervalSince1970: modified))
    }

    private func withStore(_ body: (URL, IndexStore) throws -> Void) throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try body(url, try IndexStore(fileURL: url, root: root))
    }

    private let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)

    /// A pending image as phase 1 writes it.
    private func addPendingImage(_ store: IndexStore, _ path: String = "foto.png", size: Int64 = 100) throws {
        try store.upsert(file(path, size: size), pages: [PageText(pageIndex: 0, text: "", needsOCR: true)], status: .noText)
    }

    @Test func schemaVersionIsTwo() {
        #expect(IndexStore.schemaVersion == 2)
    }

    @Test func schemaVersion1FileIsRebuilt() throws {
        try withStore { url, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "alt")], status: .ok)
            try store.batch { db in try db.run("UPDATE meta SET value = '1' WHERE key = 'schema_version'", []) }
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(reopened.wasRebuilt)
            #expect(try reopened.documents().isEmpty)
        }
    }

    @Test func pendingImageHasOneEmptyPage() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let doc = try #require(try store.documents().first)
            #expect(doc.kind == .image && doc.pageCount == 1 && doc.status == .noText)
            #expect(try store.allPages().map(\.text) == [""])
            #expect(try store.ocrWords(docId: doc.id, pageIndex: 0).isEmpty)
        }
    }

    @Test func pendingJobsListPagesNeedingOCR() throws {
        try withStore { _, store in
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "Text genug für die Suche hier"),
                                                     PageText(pageIndex: 1, text: "", needsOCR: true),
                                                     PageText(pageIndex: 2, text: "S. 3", needsOCR: true)], status: .ok)
            try addPendingImage(store, "a.jpg")
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "nur Text, keine Erkennung")], status: .ok)
            let jobs = try store.pendingOCRJobs()
            #expect(jobs.map(\.relativePath) == ["a.jpg", "b.pdf", "b.pdf"])
            #expect(jobs.map(\.pageIndex) == [0, 1, 2])
            #expect(jobs.map(\.kind) == [.image, .pdf, .pdf])
            #expect(jobs[0].fileSize == 100 && jobs[0].modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    @Test func storeOCRMakesTextSearchable() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            let words = [OCRWord(range: NSRange(location: 4, length: 16), box: box)]
            #expect(try store.storeOCR(job, text: "Das Prüfungsergebnis", words: words))
            #expect(try store.match("Prüfungsergebnis", in: .words).count == 1)
            #expect(try store.match("\"fungserg\"", in: .trigram).count == 1)
            let reader: any IndexReading = store // dispatch through the protocol, not the default
            #expect(try reader.ocrWords(docId: job.docId, pageIndex: 0) == words)
            #expect(try store.pendingOCRJobs().isEmpty)
            #expect(try store.documents().first?.status == .ok)
        }
    }

    @Test func storeOCRKeepsDocumentPendingUntilAllPagesDone() throws {
        try withStore { _, store in
            try store.upsert(file("scan.pdf"), pages: [PageText(pageIndex: 0, text: "", needsOCR: true),
                                                        PageText(pageIndex: 1, text: "", needsOCR: true)], status: .noText)
            let jobs = try store.pendingOCRJobs()
            #expect(try store.storeOCR(jobs[0], text: "erste Seite", words: []))
            #expect(try store.documents().first?.status == .noText) // not finished yet
            #expect(try store.pendingOCRJobs().count == 1)
            #expect(try store.storeOCR(jobs[1], text: "", words: []))
            #expect(try store.documents().first?.status == .ok)
        }
    }

    @Test func storeOCRIgnoredWhenFileChanged() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            try addPendingImage(store, size: 200) // phase 1 of a later run saw a new version
            #expect(try store.storeOCR(job, text: "veraltet", words: []) == false)
            #expect(try store.match("veraltet", in: .words).isEmpty)
            #expect(try store.pendingOCRJobs().count == 1)
        }
    }

    @Test func storeOCRIgnoredWhenDocumentRemoved() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            try store.remove(relativePaths: ["foto.png"])
            #expect(try store.storeOCR(job, text: "weg", words: []) == false)
            #expect(try store.allPages().isEmpty)
        }
    }

    @Test func ocrWordsEmptyForTextPage() throws {
        try withStore { _, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Text")], status: .ok)
            let doc = try #require(try store.documents().first)
            #expect(doc.kind == .pdf)
            #expect(try store.ocrWords(docId: doc.id, pageIndex: 0).isEmpty)
            #expect(try store.ocrWords(docId: 999, pageIndex: 0).isEmpty)
        }
    }

    @Test func noTextWhenOCRFindsNothing() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.storeOCR(job, text: "", words: []))
            #expect(try store.documents().first?.status == .noText)
            #expect(try store.pendingOCRJobs().isEmpty)
        }
    }

    @Test func emptyOCRResultKeepsShortTextLayer() throws {
        try withStore { _, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "S. 3", needsOCR: true)], status: .ok)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.storeOCR(job, text: "", words: []))
            #expect(try store.allPages().map(\.text) == ["S. 3"])
            #expect(try store.documents().first?.status == .ok)
        }
    }

    @Test func unreadableMarksError() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.markOCRUnreadable(job))
            #expect(try store.documents().first?.status == .error)
            #expect(try store.pendingOCRJobs().isEmpty)
        }
    }

    @Test func resetOCRRequeues() throws {
        try withStore { _, store in
            try addPendingImage(store, "a.png")
            try addPendingImage(store, "b.png")
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "normaler Text ohne Erkennung")], status: .ok)
            let jobs = try store.pendingOCRJobs()
            #expect(try store.storeOCR(jobs[0], text: "Bild eins", words: []))
            #expect(try store.markOCRUnreadable(jobs[1]))
            try store.resetOCR()
            #expect(try store.pendingOCRJobs().map(\.relativePath) == ["a.png", "b.png"])
            #expect(try store.match("eins", in: .words).count == 1) // old result stays searchable meanwhile
        }
    }

    @Test func ocrCountsCountsPagesAndImages() throws {
        try withStore { _, store in
            try addPendingImage(store, "a.png")
            try addPendingImage(store, "b.png")
            try store.upsert(file("scan.pdf"), pages: [PageText(pageIndex: 0, text: "", needsOCR: true),
                                                        PageText(pageIndex: 1, text: "", needsOCR: true),
                                                        PageText(pageIndex: 2, text: "Text genug für die Suche hier")], status: .ok)
            let jobs = try store.pendingOCRJobs()
            let w = [OCRWord(range: NSRange(location: 0, length: 4), box: box)]
            #expect(try store.storeOCR(jobs[0], text: "Bild", words: w))
            #expect(try store.storeOCR(jobs[1], text: "", words: [])) // nothing recognized
            #expect(try store.storeOCR(jobs[2], text: "Seite eins", words: w))
            #expect(try store.storeOCR(jobs[3], text: "Seite zwei", words: w))
            let counts = try store.ocrCounts()
            #expect(counts.pages == 2 && counts.images == 1)
        }
    }

    @Test func upsertDropsOldWords() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.storeOCR(job, text: "Wort", words: [OCRWord(range: NSRange(location: 0, length: 4), box: box)]))
            try addPendingImage(store, size: 300)
            let doc = try #require(try store.documents().first)
            #expect(try store.ocrWords(docId: doc.id, pageIndex: 0).isEmpty)
            var count: SQLiteValue?
            try store.batch { db in count = try db.query("SELECT count(*) AS n FROM ocr_words", [])[0]["n"] }
            #expect(count == .int(0))
        }
    }

    @Test func deleteIndexClearsOCRData() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.storeOCR(job, text: "Wort", words: [OCRWord(range: NSRange(location: 0, length: 4), box: box)]))
            try store.deleteIndex()
            #expect(try store.documents().isEmpty)
            try addPendingImage(store)
            #expect(try store.pendingOCRJobs().count == 1)
        }
    }

    // MARK: Review fixes (Task 3)

    private func ftsIntegrity(_ store: IndexStore) throws {
        try store.batch { db in
            try db.execute("INSERT INTO pages_words(pages_words) VALUES('integrity-check')")
            try db.execute("INSERT INTO pages_trigram(pages_trigram) VALUES('integrity-check')")
        }
    }

    @Test func emptyRerunKeepsPreviousResultWhole() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            let words = [OCRWord(range: NSRange(location: 0, length: 4), box: box)]
            #expect(try store.storeOCR(job, text: "Wort", words: words))
            try store.resetOCR()
            let again = try #require(try store.pendingOCRJobs().first)
            #expect(try store.storeOCR(again, text: "", words: []))
            let doc = try #require(try store.documents().first)
            #expect(try store.ocrWords(docId: doc.id, pageIndex: 0) == words)
            #expect(try store.allPages().map(\.text) == ["Wort"])
            #expect(doc.status == .ok)
            try ftsIntegrity(store)
        }
    }

    @Test func rerunWithDifferentTextReplacesOldText() throws {
        try withStore { _, store in
            try addPendingImage(store)
            #expect(try store.storeOCR(try #require(try store.pendingOCRJobs().first), text: "alter Text", words: []))
            try store.resetOCR()
            #expect(try store.storeOCR(try #require(try store.pendingOCRJobs().first), text: "neuer Inhalt", words: []))
            #expect(try store.match("alter", in: .words).isEmpty)
            #expect(try store.match("\"lte\"", in: .trigram).isEmpty)
            #expect(try store.match("Inhalt", in: .words).count == 1)
            try ftsIntegrity(store)
        }
    }

    @Test func unreadablePDFPageOnlyFinishesThatPage() throws {
        try withStore { _, store in
            try store.upsert(file("gemischt.pdf"), pages: [PageText(pageIndex: 0, text: "Text genug für die Suche hier"),
                                                            PageText(pageIndex: 1, text: "", needsOCR: true)], status: .ok)
            let job = try #require(try store.pendingOCRJobs().first)
            #expect(try store.markOCRUnreadable(job))
            #expect(try store.documents().first?.status == .ok)
            #expect(try store.pendingOCRJobs().isEmpty)
        }
    }

    @Test func staleUnreadableIsIgnored() throws {
        try withStore { _, store in
            try addPendingImage(store)
            let job = try #require(try store.pendingOCRJobs().first)
            try addPendingImage(store, size: 999)
            #expect(try store.markOCRUnreadable(job) == false)
            #expect(try store.documents().first?.status == .noText)
        }
    }

    @Test func jobForReusedIdOfOtherFileIsStale() throws {
        try withStore { _, store in
            try addPendingImage(store, "a.png")
            let job = try #require(try store.pendingOCRJobs().first)
            try store.deleteIndex()
            try addPendingImage(store, "b.png") // same id, size and date, other file
            #expect(try store.storeOCR(job, text: "falsch", words: []) == false)
        }
    }

    @Test func ocrCountsIgnoresPagesWhereOCRFoundNothing() throws {
        try withStore { _, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "S. 3", needsOCR: true)], status: .ok)
            #expect(try store.storeOCR(try #require(try store.pendingOCRJobs().first), text: "", words: []))
            #expect(try store.ocrCounts().pages == 0)
        }
    }
}
