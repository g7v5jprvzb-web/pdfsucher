import CoreGraphics
import ImageIO
import Foundation
import PDFKit
import Testing
import TestSupport
@testable import OutputKit

/// Bounding box (PDF points, origin bottom left) of everything not white on the page, rendered at 1 px/pt.
func inkBounds(of page: PDFPage) -> CGRect? {
    let box = page.bounds(for: .mediaBox)
    let width = Int(box.width.rounded(.up)), height = Int(box.height.rounded(.up))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let data = context.data else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    page.draw(with: .mediaBox, to: context)
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for row in 0..<height {
        for column in 0..<width where pixels[row * width + column] < 200 {
            minX = min(minX, column); maxX = max(maxX, column)
            // Bitmap rows run top to bottom in memory; flip to PDF's bottom-left origin.
            let y = height - 1 - row
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@Suite("ImagePages")
struct ImagePagesTests {
    let dir: URL
    let a4Long: CGFloat = 841.89, a4Short: CGFloat = 595.28, margin: CGFloat = 28.35

    init() throws { dir = try PDFFixtures.tempDirectory() }

    private func solid(_ name: String, _ w: CGFloat, _ h: CGFloat, _ format: ImageFixtures.Format = .png,
                       orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ImageFixtures.makeSolidImage(at: url, size: CGSize(width: w, height: h), format: format, exifOrientation: orientation)
        return url
    }

    private func size(_ page: PDFPage) -> CGSize { page.bounds(for: .mediaBox).size }

    @Test func recognisesImageExtensions() {
        for name in ["a.png", "b.PNG", "c.jpg", "d.JPEG", "e.heic", "f.HEIC", "g.dng", "h.Dng"] {
            #expect(ImagePages.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
        for name in ["a.pdf", "b.tiff", "c.gif", "noext", "png"] {
            #expect(!ImagePages.isImage(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    @Test func landscapeImageGivesLandscapeA4FittedToMargins() throws {
        let page = try ImagePages.makePage(from: try solid("quer.png", 1200, 800))
        #expect(abs(size(page).width - a4Long) < 0.5 && abs(size(page).height - a4Short) < 0.5)
        let ink = try #require(inkBounds(of: page))
        // Width fills the space between the margins, height follows the aspect ratio, centred.
        #expect(abs(ink.minX - margin) <= 2 && abs(ink.maxX - (a4Long - margin)) <= 2)
        let expectedHeight = (a4Long - 2 * margin) * 800 / 1200
        #expect(abs(ink.height - expectedHeight) <= 2)
        #expect(abs(ink.midY - a4Short / 2) <= 2)
    }

    @Test func portraitImageGivesPortraitA4() throws {
        let page = try ImagePages.makePage(from: try solid("hoch.jpg", 800, 1200, .jpeg))
        #expect(abs(size(page).width - a4Short) < 0.5 && abs(size(page).height - a4Long) < 0.5)
        let ink = try #require(inkBounds(of: page))
        #expect(ink.minX >= margin - 2 && ink.maxX <= a4Short - margin + 2)
        #expect(ink.minY >= margin - 2 && ink.maxY <= a4Long - margin + 2)
        #expect(abs(ink.midX - a4Short / 2) <= 2 && abs(ink.midY - a4Long / 2) <= 2)
        // 800×1200 in 538.58×785.19: the height fits, so the image touches top and bottom margin.
        #expect(abs(ink.minY - margin) <= 2 && abs(ink.maxY - (a4Long - margin)) <= 2)
    }

    @Test func squareImageGivesPortraitA4() throws {
        let page = try ImagePages.makePage(from: try solid("quadrat.heic", 500, 500, .heic))
        #expect(abs(size(page).width - a4Short) < 0.5)
        let ink = try #require(inkBounds(of: page))
        #expect(abs(ink.width - (a4Short - 2 * margin)) <= 2 && abs(ink.height - ink.width) <= 2)
    }

    @Test func tinyImageIsScaledUpToTheMargins() throws {
        let page = try ImagePages.makePage(from: try solid("klein.png", 20, 10))
        let ink = try #require(inkBounds(of: page))
        #expect(abs(ink.width - (a4Long - 2 * margin)) <= 2)
    }

    @Test func exifOrientationDecidesTheFormat() throws {
        // Stored 1200×800, orientation 6 → displayed 800×1200 → portrait page with a tall image.
        let page = try ImagePages.makePage(from: try solid("gedreht.jpg", 1200, 800, .jpeg, orientation: 6))
        #expect(abs(size(page).width - a4Short) < 0.5)
        let ink = try #require(inkBounds(of: page))
        #expect(ink.height > ink.width * 1.4)
    }

    @Test func unreadableImagesThrowCannotOpen() throws {
        let garbage = dir.appendingPathComponent("kaputt.jpg")
        try Data("kein Bild".utf8).write(to: garbage)
        #expect(throws: OutputError.cannotOpen(garbage)) { try ImagePages.makePage(from: garbage) }
        let gone = dir.appendingPathComponent("weg.png")
        #expect(throws: OutputError.cannotOpen(gone)) { try ImagePages.makePage(from: gone) }
    }

    @Test func photosAreEmbeddedAsJPEGScreenshotsLossless() throws {
        let photo = try ImagePages.makePage(from: try solid("foto.jpg", 1200, 800, .jpeg))
        let shot = try ImagePages.makePage(from: try solid("bild.png", 1200, 800, .png))
        func pdfText(_ page: PDFPage) throws -> String {
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            let data = try #require(doc.dataRepresentation())
            return String(decoding: data, as: UTF8.self)
        }
        let heic = try ImagePages.makePage(from: try solid("iphone.heic", 1200, 800, .heic))
        #expect(try pdfText(photo).contains("/DCTDecode"))
        #expect(try pdfText(heic).contains("/DCTDecode"), "opaque HEIC (iPhone photo) must be embedded as JPEG")
        #expect(try !pdfText(shot).contains("/DCTDecode"))
    }

    @Test func transparentImagesAreNotTurnedIntoJPEG() throws {
        // A HEIC with alpha: JPEG has no alpha and would paint transparent areas black.
        let url = dir.appendingPathComponent("transparent.heic")
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 150, y: 100, width: 100, height: 100))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let page = try ImagePages.makePage(from: url)
        let ink = try #require(inkBounds(of: page))
        // Only the black square is ink, not the whole (transparent) image area.
        #expect(ink.width < (a4Long - 2 * margin) / 2)
    }

    @Test func largeImagesAreLimitedTo300Dpi() throws {
        let page = try ImagePages.makePage(from: try solid("riesig.jpg", 8000, 6000, .jpeg))
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let data = try #require(doc.dataRepresentation())
        let text = String(decoding: data, as: UTF8.self)
        // The embedded image's /Width must not exceed A4's long side at 300 dpi.
        let widths = text.matches(of: /\/Width (\d+)/).compactMap { Int($0.1) }
        #expect(!widths.isEmpty)
        #expect(widths.allSatisfy { $0 <= 3508 })
    }
}
