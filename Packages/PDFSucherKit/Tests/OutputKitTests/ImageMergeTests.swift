import Foundation
import PDFKit
import Testing
import TestSupport
@testable import OutputKit

/// Spec 1.2 §6/§10: ticked images become their own A4 pages in the merged PDF and in print.
@Suite("Image pages in merge and print")
struct ImageMergeTests {
    let dir: URL
    let pdf: URL
    let photo: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        pdf = dir.appendingPathComponent("A.pdf")
        photo = dir.appendingPathComponent("Foto.JPG")
        try PDFFixtures.makePDF(at: pdf, pages: ["Alpha null", "Alpha eins"])
        try ImageFixtures.makeSolidImage(at: photo, size: CGSize(width: 1200, height: 800), format: .jpeg)
    }

    @Test func imageBecomesA4PageInOrder() throws {
        let doc = try Merger().makeDocument([
            PageRef(url: pdf, pageIndex: 1), PageRef(url: photo, pageIndex: 0), PageRef(url: pdf, pageIndex: 0),
        ])
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 0)?.string?.contains("Alpha eins") == true)
        #expect(doc.page(at: 2)?.string?.contains("Alpha null") == true)
        let imagePage = try #require(doc.page(at: 1))
        let size = imagePage.bounds(for: .mediaBox).size
        #expect(abs(size.width - 841.89) < 0.5 && abs(size.height - 595.28) < 0.5)
        #expect(inkBounds(of: imagePage) != nil)
    }

    @Test func writtenFileContainsTheImagePage() throws {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Merger().write([PageRef(url: photo, pageIndex: 0), PageRef(url: pdf, pageIndex: 0)], to: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(inkBounds(of: try #require(doc.page(at: 0))) != nil)
    }

    @Test func sameImageTwiceGivesTwoPages() throws {
        let ref = PageRef(url: photo, pageIndex: 0)
        #expect(try Merger().makeDocument([ref, ref]).pageCount == 2)
    }

    @Test func imagePageIndexOtherThanZeroIsOutOfRange() {
        let bad = PageRef(url: photo, pageIndex: 1)
        #expect(throws: OutputError.pageOutOfRange(bad)) { try Merger().makeDocument([bad]) }
    }

    @Test func unreadableImageCannotBeOpened() throws {
        let broken = dir.appendingPathComponent("kaputt.png")
        try Data("kein Bild".utf8).write(to: broken)
        #expect(throws: OutputError.cannotOpen(broken)) {
            try Merger().makeDocument([PageRef(url: pdf, pageIndex: 0), PageRef(url: broken, pageIndex: 0)])
        }
    }

    @Test func unavailableListsBrokenMissingAndWrongIndexImages() throws {
        let broken = dir.appendingPathComponent("kaputt.png")
        try Data("kein Bild".utf8).write(to: broken)
        let gone = dir.appendingPathComponent("weg.heic")
        let refs = [PageRef(url: photo, pageIndex: 0), PageRef(url: photo, pageIndex: 1),
                    PageRef(url: broken, pageIndex: 0), PageRef(url: gone, pageIndex: 0), PageRef(url: pdf, pageIndex: 1)]
        #expect(Merger.unavailable(refs) == [PageRef(url: photo, pageIndex: 1), PageRef(url: broken, pageIndex: 0),
                                             PageRef(url: gone, pageIndex: 0)])
    }

    @MainActor @Test func printOperationIncludesImagePages() throws {
        let operation = try Printer.printOperation(for: [PageRef(url: photo, pageIndex: 0), PageRef(url: pdf, pageIndex: 0)])
        #expect(operation.jobTitle == "Auswahl")
        let document = try PrintDocument.build([PageRef(url: pdf, pageIndex: 0), PageRef(url: photo, pageIndex: 0)]).document
        #expect(document.pageCount == 2)
    }
}

@Suite("Image availability matches merging")
struct ImageAvailabilityTests {
    /// A file whose header is fine but whose pixel data is cut off (e.g. an interrupted copy):
    /// „Fehlende Seiten entfernen“ must remove exactly what saving would fail on.
    @Test(arguments: [ImageFixtures.Format.png, .jpeg, .heic])
    func truncatedImageIsUnavailableExactlyWhenMergingFails(format: ImageFixtures.Format) throws {
        let dir = try PDFFixtures.tempDirectory()
        let full = dir.appendingPathComponent("voll.img")
        try ImageFixtures.makeImage(at: full, text: "Abgeschnitten", size: CGSize(width: 1200, height: 800), format: format)
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("halb." + (format == .png ? "png" : format == .jpeg ? "jpg" : "heic"))
        try data.prefix(data.count * 2 / 3).write(to: cut)
        let ref = PageRef(url: cut, pageIndex: 0)
        let mergeFails = (try? Merger().makeDocument([ref])) == nil
        #expect(Merger.unavailable([ref]).contains(ref) == mergeFails)
    }
}
