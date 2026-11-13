import Foundation
import Testing
import TestSupport
@testable import OutputKit

/// Chris (Task 5.6): pages whose file is gone, unreadable or shorter now can be found and unticked.
@Suite("Unavailable pages")
struct UnavailablePagesTests {
    @Test func findsMissingFilesAndPages() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("gut.pdf")
        try PDFFixtures.makePDF(at: good, pages: ["Eins", "Zwei"])
        let gone = dir.appendingPathComponent("weg.pdf")
        let notPDF = dir.appendingPathComponent("kaputt.pdf")
        try Data("kein PDF".utf8).write(to: notPDF)
        let refs = [PageRef(url: good, pageIndex: 0), PageRef(url: good, pageIndex: 1), PageRef(url: good, pageIndex: 5),
                    PageRef(url: gone, pageIndex: 0), PageRef(url: notPDF, pageIndex: 0)]
        #expect(Merger.unavailable(refs) == [PageRef(url: good, pageIndex: 5), PageRef(url: gone, pageIndex: 0),
                                             PageRef(url: notPDF, pageIndex: 0)])
        #expect(Merger.unavailable(Array(refs.prefix(2))).isEmpty)
    }

    @Test func selectionRemovesGivenPages() {
        let a = PageRef(url: URL(fileURLWithPath: "/a.pdf"), pageIndex: 0)
        let b = PageRef(url: URL(fileURLWithPath: "/b.pdf"), pageIndex: 1)
        var selection = PageSelection()
        selection.toggle(a); selection.toggle(b)
        selection.remove([b, PageRef(url: URL(fileURLWithPath: "/c.pdf"), pageIndex: 0)])
        #expect(selection.count == 1)
        #expect(selection.contains(a))
    }
}
