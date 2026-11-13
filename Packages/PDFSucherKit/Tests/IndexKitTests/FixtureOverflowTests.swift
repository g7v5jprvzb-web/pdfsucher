import Testing
import Foundation
import TestSupport

@Suite("PDF fixtures overflow")
struct FixtureOverflowTests {
    @Test func throwsWhenTextDoesNotFitPage() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tooLong = String(repeating: "Vertragsende ", count: 20_000)
        #expect(throws: PDFFixturesError.self) {
            try PDFFixtures.makePDF(at: dir.appendingPathComponent("x.pdf"), pages: [tooLong])
        }
    }
}
