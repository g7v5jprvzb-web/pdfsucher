import Foundation
@testable import IndexKit
import Testing
import TestSupport

@Suite("IndexStore layout data (schema 3)")
struct IndexStoreLayoutTests {
    private let root = URL(fileURLWithPath: "/tmp/PDFSucherRoot", isDirectory: true)
    private let size = CGSize(width: 595, height: 842)

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

    private func page(_ text: String) -> LaidOutPage {
        let words = text.isEmpty ? [] : [OCRWord(range: NSRange(location: 0, length: (text as NSString).length),
                                                 box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))]
        return LaidOutPage(text: text, words: words, size: size)
    }

    private func result(_ texts: [String], renderer: String = "quicklook", version: Int = 1) -> LayoutResult {
        LayoutResult(pages: texts.map(page), renderer: renderer, layoutVersion: version)
    }

    private func awaiting(_ store: IndexStore, _ path: String = "brief.docx") throws -> LayoutJob {
        try store.upsertAwaitingLayout(file(path))
        return try #require(try store.pendingLayoutJobs().first { $0.relativePath == path })
    }

    @Test func awaitingDocumentIsPendingAndInvisibleToSearch() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            #expect(job.kind == .word && job.fileSize == 100)
            let doc = try #require(try store.documents().first)
            #expect(doc.pageCount == 0 && doc.status == .noText && doc.renderer == nil && doc.layoutVersion == nil)
            #expect(try store.allPages().isEmpty)
        }
    }

    @Test func pendingJobsAreSortedByPath() throws {
        try withStore { _, store in
            _ = try awaiting(store, "b.pptx")
            _ = try awaiting(store, "a.docx")
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "x")], status: .ok)
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.docx", "b.pptx"])
        }
    }

    /// Merge 1.2.1 (Task 12): the preview reads marks through `ocrPage` (as for recognized images); a
    /// laid-out Office page answers with its text and word boxes, a page with a text layer with nil.
    @Test func ocrPageServesLaidOutPages() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            #expect(try store.ocrPage(relativePath: "brief.docx", pageIndex: 0) == nil)   // not laid out yet
            #expect(try store.storeLayout(job, result: result(["erste Seite", "Rechnung Nummer"])))
            let second = try #require(try store.ocrPage(relativePath: "brief.docx", pageIndex: 1))
            #expect(second.text == "Rechnung Nummer" && second.words == page("Rechnung Nummer").words)
            #expect(try store.ocrPage(relativePath: "brief.docx", pageIndex: 2) == nil)
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "Textebene")], status: .ok)
            #expect(try store.ocrPage(relativePath: "c.pdf", pageIndex: 0) == nil)
        }
    }

    @Test func storeLayoutWritesPagesAndWords() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            #expect(try store.storeLayout(job, result: result(["erste Seite", "Rechnung Nummer"], renderer: "textkit", version: 3)))
            let doc = try #require(try store.documents().first)
            #expect(doc.pageCount == 2 && doc.status == .ok && doc.renderer == "textkit" && doc.layoutVersion == 3)
            #expect(try store.pendingLayoutJobs().isEmpty)
            let hits = try store.match("rechnung", in: .words)
            #expect(hits.map(\.pageIndex) == [1])
            let words = try store.ocrWords(docId: job.docId, pageIndex: 1)
            #expect(words == page("Rechnung Nummer").words)
            try store.batch { db in
                let rows = try db.query("SELECT DISTINCT source FROM page_text", [])
                #expect(rows.count == 1 && rows[0]["source"] == .text("layout"))
            }
        }
    }

    @Test func relayoutReplacesPagesAndKeepsFTSConsistent() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.storeLayout(job, result: result(["alpha eins", "beta zwei", "gamma drei"]))
            try store.requestLayout(renderer: "quicklook", olderThan: 2)
            #expect(try store.pendingLayoutJobs().count == 1)
            #expect(try store.storeLayout(job, result: result(["delta vier"], renderer: "wordkit", version: 2)))
            #expect(try store.allPages().map(\.text) == ["delta vier"])
            #expect(try store.match("alpha", in: .words).isEmpty)
            #expect(try store.match("beta", in: .trigram).isEmpty)
            #expect(try store.match("delta", in: .words).count == 1)
            #expect(try store.ocrWords(docId: job.docId, pageIndex: 1).isEmpty)
            try store.batch { db in
                let rows = try db.query("SELECT 1 FROM ocr_words", [])
                #expect(rows.count == 1)
            }
            let doc = try #require(try store.documents().first)
            #expect(doc.pageCount == 1 && doc.renderer == "wordkit" && doc.layoutVersion == 2)
        }
    }

    @Test func storeLayoutRejectsChangedFile() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            let oldDate = LayoutJob(docId: job.docId, relativePath: job.relativePath, kind: job.kind,
                                    fileSize: job.fileSize, modifiedAt: job.modifiedAt.addingTimeInterval(-60))
            let oldSize = LayoutJob(docId: job.docId, relativePath: job.relativePath, kind: job.kind,
                                    fileSize: job.fileSize + 1, modifiedAt: job.modifiedAt)
            #expect(try store.storeLayout(oldDate, result: result(["text"])) == false)
            #expect(try store.storeLayout(oldSize, result: result(["text"])) == false)
            #expect(try store.allPages().isEmpty)
            #expect(try store.pendingLayoutJobs().count == 1)
            #expect(try store.documents().first?.renderer == nil)
        }
    }

    @Test func storeLayoutForRemovedDocumentReturnsFalse() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.remove(relativePaths: [job.relativePath])
            #expect(try store.storeLayout(job, result: result(["text"])) == false)
            #expect(try store.documents().isEmpty)
            #expect(try store.allPages().isEmpty)
        }
    }

    @Test func emptyLayoutIsNoText() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            #expect(try store.storeLayout(job, result: result(["", ""])))
            let doc = try #require(try store.documents().first)
            #expect(doc.status == .noText && doc.pageCount == 2 && doc.renderer == "quicklook")
            #expect(try store.pendingLayoutJobs().isEmpty)
        }
    }

    @Test func markLayoutFailedReturnsFalseForStaleJob() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.upsertAwaitingLayout(file("brief.docx", size: 200)) // file changed meanwhile
            #expect(try store.markLayoutFailed(job, reason: "kaputt") == false)
            #expect(try store.documents().first?.status == .noText)
            #expect(try store.pendingLayoutJobs().count == 1)
            let current = try #require(try store.pendingLayoutJobs().first)
            #expect(try store.markLayoutFailed(current, reason: "kaputt"))
        }
    }

    @Test func failedLayoutIsError() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.markLayoutFailed(job, reason: "kaputt")
            let doc = try #require(try store.documents().first)
            #expect(doc.status == .error)
            #expect(try store.pendingLayoutJobs().isEmpty)
        }
    }

    @Test func requestLayoutMarksOlderVersionsOfThatRendererOnly() throws {
        try withStore { _, store in
            let a = try awaiting(store, "a.docx"), b = try awaiting(store, "b.docx"), c = try awaiting(store, "c.pptx")
            try store.storeLayout(a, result: result(["a"], renderer: "quicklook", version: 1))
            try store.storeLayout(b, result: result(["b"], renderer: "quicklook", version: 2))
            try store.storeLayout(c, result: result(["c"], renderer: "textkit", version: 1))
            try store.requestLayout(renderer: "quicklook", olderThan: 2)
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.docx"])
            // Queued documents stay searchable until the new result arrives.
            #expect(try store.match("a", in: .words).count == 1)
        }
    }

    @Test func upsertAfterFileChangeDropsOldLayout() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.storeLayout(job, result: result(["alt"]))
            try store.upsertAwaitingLayout(file("brief.docx", size: 200))
            let doc = try #require(try store.documents().first)
            #expect(doc.pageCount == 0 && doc.renderer == nil && doc.layoutVersion == nil && doc.id == job.docId)
            #expect(try store.allPages().isEmpty)
            #expect(try store.pendingLayoutJobs().first?.fileSize == 200)
        }
    }

    @Test func schemaUpgradeRebuilds() throws {
        try withStore { url, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "alt")], status: .ok)
            try store.batch { db in try db.run("UPDATE meta SET value = '2' WHERE key = 'schema_version'", []) }
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(reopened.wasRebuilt)
            #expect(try reopened.documents().isEmpty)
            #expect(try reopened.pendingLayoutJobs().isEmpty)
        }
    }

    @Test func failedRelayoutDropsOldPagesAndIsNotRequeued() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            try store.storeLayout(job, result: result(["alt"], version: 1))
            try store.requestLayout(renderer: "quicklook", olderThan: 2)
            try store.markLayoutFailed(job, reason: "kaputt")
            let doc = try #require(try store.documents().first)
            #expect(doc.status == .error && doc.renderer == nil && doc.layoutVersion == nil)
            #expect(try store.allPages().isEmpty)
            try store.batch { db in
                let rows = try db.query("SELECT 1 FROM ocr_words", [])
                #expect(rows.isEmpty)
            }
            try store.requestLayout(renderer: "quicklook", olderThan: 3)
            #expect(try store.pendingLayoutJobs().isEmpty)
        }
    }

    @Test func wordsOutsideThePageTextAreDropped() throws {
        try withStore { _, store in
            let job = try awaiting(store)
            let box = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
            let good = OCRWord(range: NSRange(location: 0, length: 4), box: box)
            let bad = OCRWord(range: NSRange(location: 3, length: 10), box: box)
            let negative = OCRWord(range: NSRange(location: -1, length: 2), box: box)
            let r = LayoutResult(pages: [LaidOutPage(text: "Haus", words: [good, bad, negative], size: size)],
                                 renderer: "quicklook", layoutVersion: 1)
            #expect(try store.storeLayout(job, result: r))
            #expect(try store.ocrWords(docId: job.docId, pageIndex: 0) == [good])
        }
    }

    @Test func pendingJobsSkipUnknownKinds() throws {
        try withStore { _, store in
            _ = try awaiting(store, "a.docx")
            _ = try awaiting(store, "b.docx")
            try store.batch { db in try db.run("UPDATE documents SET kind = 'bogus' WHERE path = 'a.docx'", []) }
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["b.docx"])
        }
    }
    @Test func requestLayoutByKindQueuesEveryDocumentOfThatKind() throws {
        try withStore { _, store in
            let a = try awaiting(store, "a.docx"), b = try awaiting(store, "b.docx"), c = try awaiting(store, "c.pptx")
            _ = try awaiting(store, "d.docx") // never laid out (renderer NULL), still waiting
            try store.storeLayout(a, result: result(["alpha"], renderer: "textkit", version: 1))
            try store.markLayoutFailed(b, reason: "kaputt")
            try store.storeLayout(c, result: result(["gamma"]))
            try store.requestLayout(kind: .word)
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.docx", "b.docx", "d.docx"])
            // Queued documents stay searchable until the new result arrives.
            #expect(try store.match("alpha", in: .words).count == 1)
        }
    }

    @Test func adoptLayoutRendererRequeuesKindOnChangeOnly() throws {
        try withStore { url, store in
            // Fresh index: the value is recorded, nothing to queue.
            #expect(try store.adoptLayoutRenderer(name: "textkit", version: 1, for: .word))
            #expect(try store.adoptLayoutRenderer(name: "quicklook", version: 1, for: .powerpoint))
            #expect(try store.layoutRenderer(for: .word) == "textkit:1")
            let a = try awaiting(store, "a.docx"), b = try awaiting(store, "b.docx"), c = try awaiting(store, "c.pptx")
            try store.storeLayout(a, result: result(["alpha"], renderer: "textkit", version: 1))
            try store.markLayoutFailed(b, reason: "kaputt")
            try store.storeLayout(c, result: result(["gamma"]))
            // Unchanged: nothing queued.
            #expect(try !store.adoptLayoutRenderer(name: "textkit", version: 1, for: .word))
            #expect(try store.pendingLayoutJobs().isEmpty)
            // Other renderer for Word: every Word document again, incl. the failed one; PowerPoint untouched.
            #expect(try store.adoptLayoutRenderer(name: "wordkit", version: 1, for: .word))
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.docx", "b.docx"])
            // Kept across reopening.
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(try reopened.layoutRenderer(for: .word) == "wordkit:1")
            #expect(try reopened.layoutRenderer(for: .powerpoint) == "quicklook:1")
            // A version change counts too.
            try reopened.storeLayout(try #require(try reopened.pendingLayoutJobs().first), result: result(["a2"], renderer: "wordkit"))
            #expect(try reopened.adoptLayoutRenderer(name: "quicklook", version: 2, for: .powerpoint))
            #expect(try reopened.pendingLayoutJobs().map(\.relativePath) == ["b.docx", "c.pptx"])
        }
    }

    /// 1.3 Teil B Task 12: a PowerPoint display switch lays every deck out again with no old words left searchable.
    @Test func resetLayoutClearsTextOfThatKindAndQueuesIt() throws {
        try withStore { _, store in
            let a = try awaiting(store, "a.pptx"), b = try awaiting(store, "b.pptx"), w = try awaiting(store, "w.docx")
            try store.storeLayout(a, result: result(["alpha"]))
            try store.markLayoutFailed(b, reason: "kaputt")
            try store.storeLayout(w, result: result(["wort"], renderer: "textkit"))
            try store.resetLayout(kind: .powerpoint)
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.pptx", "b.pptx"])
            #expect(try store.match("alpha", in: .words).isEmpty, "no word of the old layout is found")
            #expect(try store.match("wort", in: .words).count == 1, "Word untouched")
            for path in ["a.pptx", "b.pptx"] {
                let doc = try #require(try store.documents().first { $0.relativePath == path })
                #expect(doc.pageCount == 0 && doc.status == .noText && doc.renderer == nil && doc.layoutVersion == nil)
            }
            #expect(try store.layoutCounts() == LayoutCounts(wordRead: 1, waiting: 2))
        }
    }

    @Test func deleteIndexForgetsLayoutRenderers() throws {
        try withStore { _, store in
            try store.adoptLayoutRenderer(name: "textkit", version: 1, for: .word)
            try store.deleteIndex()
            #expect(try store.layoutRenderer(for: .word) == nil)
        }
    }

    // MARK: Office UI (1.3 Teil B)

    @Test func layoutCountsPerKind() throws {
        try withStore { _, store in
            let a = try awaiting(store, "a.docx"), b = try awaiting(store, "b.docx"), c = try awaiting(store, "c.docx")
            let d = try awaiting(store, "d.pptx")
            _ = try awaiting(store, "e.pptx") // still waiting
            try store.storeLayout(a, result: result(["alpha"]))
            try store.storeLayout(b, result: result([""])) // laid out without text: read as well
            try store.markLayoutFailed(c, reason: "kaputt")
            try store.storeLayout(d, result: result(["delta"]))
            try store.upsert(file("f.pdf"), pages: [PageText(pageIndex: 0, text: "x")], status: .ok)
            #expect(try store.layoutCounts() == LayoutCounts(wordRead: 2, wordFailed: 1, powerpointRead: 1,
                                                             powerpointFailed: 0, waiting: 1))
        }
    }

    @Test func requestLayoutForOneDocument() throws {
        try withStore { _, store in
            let a = try awaiting(store, "a.pptx"), b = try awaiting(store, "b.pptx")
            try store.storeLayout(a, result: result(["alpha"]))
            try store.storeLayout(b, result: result(["beta"]))
            try store.requestLayout(relativePath: "a.pptx")
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.pptx"])
            // Queued documents stay searchable until the new result arrives.
            #expect(try store.match("alpha", in: .words).count == 1)
            try store.requestLayout(relativePath: "fehlt.pptx") // unknown: nothing
            #expect(try store.pendingLayoutJobs().map(\.relativePath) == ["a.pptx"])
        }
    }

    @Test func requestLayoutIgnoresPDF() throws {
        try withStore { _, store in
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "x")], status: .ok)
            try store.upsert(file("d.png"), pages: [PageText(pageIndex: 0, text: "y")], status: .ok)
            try store.requestLayout(relativePath: "c.pdf")
            try store.requestLayout(relativePath: "d.png")
            #expect(try store.pendingLayoutJobs().isEmpty)
            try store.batch { db in
                let rows = try db.query("SELECT 1 FROM documents WHERE needs_layout = 1", [])
                #expect(rows.isEmpty)
            }
        }
    }
}
