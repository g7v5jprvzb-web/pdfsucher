import CoreGraphics
import Foundation
import MediaKit
import TestSupport
import Testing

@Suite("ImageThumbnails")
struct ImageThumbnailsTests {
    let dir: URL
    init() throws { dir = try PDFFixtures.tempDirectory() }

    private func file(_ name: String, _ size: CGSize, _ format: ImageFixtures.Format, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ImageFixtures.makeImage(at: url, text: "Prüfung", size: size, format: format, exifOrientation: orientation)
        return url
    }

    @Test(arguments: [("a.png", ImageFixtures.Format.png), ("b.JPG", .jpeg), ("c.heic", .heic)])
    func scalesDownKeepingAspect(name: String, format: ImageFixtures.Format) throws {
        let url = try file(name, CGSize(width: 1200, height: 800), format)
        let thumb = try #require(ImageThumbnails.thumbnail(for: url, maxPixel: 300))
        #expect(thumb.width == 300)
        #expect(thumb.height == 200)
    }

    @Test func neverScalesUp() throws {
        let url = try file("small.png", CGSize(width: 120, height: 80), .png)
        let thumb = try #require(ImageThumbnails.thumbnail(for: url, maxPixel: 5000))
        #expect(thumb.width == 120)
        #expect(thumb.height == 80)
    }

    @Test func appliesExifOrientation() throws {
        // Orientation 6: stored landscape, displayed rotated 90° → portrait.
        let url = try file("rotated.jpg", CGSize(width: 1200, height: 800), .jpeg, orientation: 6)
        let thumb = try #require(ImageThumbnails.thumbnail(for: url, maxPixel: 300))
        #expect(thumb.width == 200)
        #expect(thumb.height == 300)
    }

    @Test func smallEmbeddedPreviewIsNotUsedForLargerTiles() throws {
        let url = dir.appendingPathComponent("kamera.jpg")
        try ImageFixtures.makeImage(at: url, text: "Prüfung", size: CGSize(width: 1200, height: 800), format: .jpeg,
                                    embedThumbnail: true)
        let thumb = try #require(ImageThumbnails.thumbnail(for: url, maxPixel: 600))
        #expect(thumb.width == 600)
        #expect(thumb.height == 400)
    }

    @Test func embeddedPreviewWithOrientation() throws {
        let url = dir.appendingPathComponent("kamera6.jpg")
        try ImageFixtures.makeImage(at: url, text: "Prüfung", size: CGSize(width: 1200, height: 800), format: .jpeg,
                                    exifOrientation: 6, embedThumbnail: true)
        let thumb = try #require(ImageThumbnails.thumbnail(for: url, maxPixel: 90))
        #expect(thumb.width == 60)
        #expect(thumb.height == 90)
    }

    @Test func unreadableFilesGiveNil() throws {
        let garbage = dir.appendingPathComponent("kaputt.jpg")
        try Data("kein Bild".utf8).write(to: garbage)
        #expect(ImageThumbnails.thumbnail(for: garbage, maxPixel: 300) == nil)
        #expect(ImageThumbnails.thumbnail(for: dir.appendingPathComponent("weg.png"), maxPixel: 300) == nil)
    }

    @Test func nonPositiveMaxPixelGivesNil() throws {
        let url = try file("a.png", CGSize(width: 120, height: 80), .png)
        #expect(ImageThumbnails.thumbnail(for: url, maxPixel: 0) == nil)
        #expect(ImageThumbnails.thumbnail(for: url, maxPixel: -5) == nil)
    }
}
