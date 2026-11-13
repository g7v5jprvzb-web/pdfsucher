import Testing
import Foundation
import PDFKit
import TestSupport

@Suite("PDF fixtures")
struct FixtureTests {
    @Test func fixtureRoundTrip() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Hallo Welt", "Vertragsende 2024"])
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 2)
        let page0 = try #require(doc.page(at: 0)?.string)
        let page1 = try #require(doc.page(at: 1)?.string)
        #expect(page0.contains("Hallo Welt"))
        #expect(page1.contains("Vertragsende"))
    }

    @Test func tempDirectoryIsUniqueAndExists() throws {
        let a = try PDFFixtures.tempDirectory()
        let b = try PDFFixtures.tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a != b)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir) && isDir.boolValue)
    }
}
