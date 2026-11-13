import CoreGraphics
import Foundation
import IndexKit
@testable import OCRKit
import PDFKit
import Testing
import TestSupport
import UniformTypeIdentifiers

@Suite("VisionOCRSource")
struct VisionOCRSourceTests {
    let source = VisionOCRSource()
    let lines = ["Prüfungsergebnis vom Montag", "Rechnung über 120 Euro"]

    private func withDir(_ body: (URL) throws -> Void) throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test(arguments: [("png", UTType.png), ("jpg", UTType.jpeg), ("HEIC", UTType.heic)])
    func recognizesImageFile(ext: String, type: UTType) throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("bild.\(ext)")
            try OCRFixtures.write(try OCRFixtures.textImage(lines).image, to: url, type: type)
            let result = try source.recognize(pageIndex: 0, of: url, kind: .image)
            #expect(result.text.contains("Prüfungsergebnis"), "\(result.text)")
            #expect(!result.words.isEmpty)
        }
    }

    @Test func recognizesScanPDFPage() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("scan.pdf")
            let page = try OCRFixtures.textImage(lines, size: CGSize(width: 1240, height: 1754), fontSize: 48).image
            let blank = try OCRFixtures.textImage([], size: CGSize(width: 1240, height: 1754)).image
            try OCRFixtures.makeScanPDF(at: url, images: [blank, page])
            let result = try source.recognize(pageIndex: 1, of: url, kind: .pdf)
            #expect(result.text.contains("Rechnung über 120 Euro"), "\(result.text)")
            #expect(try source.recognize(pageIndex: 0, of: url, kind: .pdf).text.isEmpty)
        }
    }

    @Test func rotatedScanPageIsUpright() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("quer.pdf")
            let (upright, rects) = try OCRFixtures.textImage(lines, size: CGSize(width: 1754, height: 1240), fontSize: 64)
            // Stored sideways, shown upright through /Rotate 270 (as scanners often do).
            try OCRFixtures.makeScanPDF(at: url, images: [try OCRFixtures.rotatedClockwise(upright)])
            let document = try #require(PDFDocument(url: url))
            document.page(at: 0)?.rotation = 270
            try #require(document.write(to: url))
            let result = try source.recognize(pageIndex: 0, of: url, kind: .pdf)
            #expect(result.text.contains("Prüfungsergebnis"), "\(result.text)")
            let ns = result.text as NSString
            let word = try #require(result.words.first { ns.substring(with: $0.range) == "Prüfungsergebnis" })
            let expected = try #require(rects["Prüfungsergebnis"])
            // Boxes refer to the page as displayed (rotation applied).
            #expect(abs(word.box.midX - expected.midX) < 0.1 && abs(word.box.midY - expected.midY) < 0.05, "\(word.box) vs \(expected)")
        }
    }

    @Test func scanPageRenderedAt300dpi() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("a4.pdf")
            try OCRFixtures.makeScanPDF(at: url, images: [try OCRFixtures.textImage(["x"]).image])
            let page = try #require(PDFDocument(url: url)?.page(at: 0))
            let image = try #require(PDFPageRenderer.render(page))
            #expect(image.width == 2479 || image.width == 2480)
            #expect(image.height == 3508 || image.height == 3509)
        }
    }

    @Test func hugePageIsCappedAt6000Pixels() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("a0.pdf")
            var box = CGRect(x: 0, y: 0, width: 2384, height: 3370) // A0
            let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            let page = try #require(PDFDocument(url: url)?.page(at: 0))
            let image = try #require(PDFPageRenderer.render(page))
            #expect(max(image.width, image.height) == 6000)
        }
    }

    @Test func largeImageIsDownscaled() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("gross.png")
            try OCRFixtures.write(try OCRFixtures.textImage(["breit"], size: CGSize(width: 8000, height: 2000)).image, to: url, type: .png)
            let image = try ImageLoader.cgImage(contentsOf: url, maxPixel: 6000)
            #expect(image.width == 6000 && image.height == 1500)
        }
    }

    @Test func smallImageKeepsFullResolution() throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("klein.jpg")
            try OCRFixtures.write(try OCRFixtures.textImage(["klein"], size: CGSize(width: 1200, height: 800)).image, to: url, type: .jpeg)
            let image = try ImageLoader.cgImage(contentsOf: url, maxPixel: 6000)
            #expect(image.width == 1200 && image.height == 800)
        }
    }

    @Test(arguments: ["kaputt.png", "kaputt.dng", "kaputt.heic", "leer.jpg"])
    func corruptImageIsUnreadable(name: String) throws {
        try withDir { dir in
            let url = dir.appendingPathComponent(name)
            try Data(name.hasPrefix("leer") ? [] : Array("not an image at all".utf8)).write(to: url)
            #expect(throws: OCRSourceError.unreadable(url)) { try source.recognize(pageIndex: 0, of: url, kind: .image) }
        }
    }

    /// An unreachable file (deleted meanwhile, unmounted share, no permission) is not „damaged“:
    /// the error must not be `.unreadable`, so the Indexer retries it next run (spec §8).
    @Test(arguments: [("fehlt.png", DocumentKind.image), ("fehlt.pdf", .pdf), ("gesperrt.png", .image)])
    func unreachableFileIsNotUnreadable(name: String, kind: DocumentKind) throws {
        try withDir { dir in
            let url = dir.appendingPathComponent(name)
            if name.hasPrefix("gesperrt") {
                try OCRFixtures.write(try OCRFixtures.textImage(["x"]).image, to: url, type: .png)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            do {
                _ = try source.recognize(pageIndex: 0, of: url, kind: kind)
                Issue.record("expected an error")
            } catch let error as OCRSourceError {
                Issue.record("unreachable file reported as \(error)")
            } catch {}
        }
    }

    @Test func missingPageIsUnreadable() throws {
        try withDir { dir in
            let pdf = dir.appendingPathComponent("eins.pdf")
            try OCRFixtures.makeScanPDF(at: pdf, images: [try OCRFixtures.textImage(["x"]).image])
            #expect(throws: OCRSourceError.unreadable(pdf)) { try source.recognize(pageIndex: 5, of: pdf, kind: .pdf) }
        }
    }

    /// Photos from cameras are stored sideways with an EXIF orientation. Word boxes must refer to
    /// the upright image as viewers (and ImageThumbnails / PDFPage(image:)) show it.
    @Test(arguments: [UTType.jpeg, UTType.heic])
    func exifOrientationIsApplied(type: UTType) throws {
        try withDir { dir in
            let url = dir.appendingPathComponent("hochkant.\(type.preferredFilenameExtension ?? "img")")
            let (upright, rects) = try OCRFixtures.textImage(lines, size: CGSize(width: 1600, height: 1000), fontSize: 64)
            // Stored turned clockwise; orientation 8 tells viewers to turn it back.
            try OCRFixtures.write(try OCRFixtures.rotatedClockwise(upright), to: url, type: type, orientation: 8)
            let loaded = try ImageLoader.cgImage(contentsOf: url, maxPixel: 6000)
            #expect(loaded.width == 1600 && loaded.height == 1000)
            let result = try source.recognize(pageIndex: 0, of: url, kind: .image)
            let ns = result.text as NSString
            let word = try #require(result.words.first { ns.substring(with: $0.range) == "Prüfungsergebnis" }, "\(result.text)")
            let expected = try #require(rects["Prüfungsergebnis"])
            #expect(abs(word.box.midX - expected.midX) < 0.1 && abs(word.box.midY - expected.midY) < 0.03, "\(word.box) vs \(expected)")
            #expect(word.box.width > word.box.height) // horizontal word, not a sideways one
        }
    }
}
