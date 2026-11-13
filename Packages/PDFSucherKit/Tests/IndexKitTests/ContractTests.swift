import Testing
import Foundation
import IndexKit // deliberately not @testable: proves the public inits (R6) are visible cross-module

@Suite("IndexKit public contract")
struct IndexKitContractTests {
    @Test func publicInitsAreVisible() {
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let date = Date(timeIntervalSince1970: 0)
        _ = PageText(pageIndex: 0, text: "x")
        _ = ScannedFile(relativePath: "a.pdf", url: url, fileSize: 1, modifiedAt: date)
        _ = StoredDocument(id: 1, relativePath: "a.pdf", fileSize: 1, modifiedAt: date, pageCount: 1, status: .ok)
        _ = RawPageMatch(docId: 1, pageIndex: 0, bm25: 0, text: "x")
        _ = IndexProgress(done: 0, total: 1, currentFile: nil)
    }

    @Test func ocrContractTypes() {
        let word = OCRWord(range: NSRange(location: 2, length: 5), box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))
        #expect(word.range == NSRange(location: 2, length: 5))
        #expect(word.box.minY == 0.2)
        #expect(DocumentKind.pdf.rawValue == "pdf" && DocumentKind.image.rawValue == "image")
        #expect(IndexProgress(done: 0, total: 1, currentFile: nil).phase == .text)
        #expect(IndexProgress(done: 1, total: 3, currentFile: "a.png", phase: .ocr).phase == .ocr)
    }

    @Test func indexReadingOCRWordsDefaultsToEmpty() throws {
        struct Minimal: IndexReading {
            func documents() throws -> [StoredDocument] { [] }
            func match(_ ftsQuery: String, in table: FTSTable) throws -> [RawPageMatch] { [] }
            func allPages() throws -> [RawPageMatch] { [] }
        }
        let reader: any IndexReading = Minimal()
        #expect(try reader.ocrWords(docId: 1, pageIndex: 0).isEmpty)
    }

    @Test func indexReportInits() {
        #expect(IndexReport() == IndexReport(added: 0, updated: 0, removed: 0, unchanged: 0, failed: [], noText: []))
        var report = IndexReport(added: 1, failed: ["x.pdf"])
        report.removed += 1
        #expect(report.added == 1 && report.removed == 1 && report.failed == ["x.pdf"] && report.noText.isEmpty)
    }

    @Test func documentStatusRawValues() {
        #expect(DocumentStatus.ok.rawValue == "ok")
        #expect(DocumentStatus.error.rawValue == "error")
        #expect(DocumentStatus.noText.rawValue == "no_text")
        #expect(DocumentStatus(rawValue: "no_text") == .noText)
    }

    @Test func textSourceIsImplementableCrossModule() throws {
        struct Fake: TextSource {
            func pages(of url: URL) throws -> [PageText] { [PageText(pageIndex: 0, text: url.lastPathComponent)] }
        }
        let source: any TextSource = Fake()
        #expect(try source.pages(of: URL(fileURLWithPath: "/tmp/a.pdf")) == [PageText(pageIndex: 0, text: "a.pdf")])
    }
}
