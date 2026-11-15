// SlidePDFPageTests.swift — Task 12c (SlideKit tests)
// SlidePDFPage: bounds, string, live drawing, what PDFKit writes when a document holding it is saved, and
// PDFKit's own thumbnail path (shadow base space).
import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import OOXMLKit
@testable import SlideKit

/// A 960×540 pt slide with two words in a text box, a red square casting a 20 pt shadow to the right, and
/// a blue bar; a second slide with other text.
private func pageDeck() throws -> OpenedDeck {
    let shadow = "<a:effectLst><a:outerShdw blurRad=\"0\" dist=\"254000\" dir=\"0\" algn=\"tl\" rotWithShape=\"0\">"
        + "<a:srgbClr val=\"000000\"/></a:outerShdw></a:effectLst>"
    var f = PptxFixture()
    f.slides = [
        .init(shapes: X.words(2, CGRect(x: 400, y: 60, width: 500, height: 80), ["Quartalsbericht Wärmepumpe"])
              + X.sp(3, CGRect(x: 100, y: 100, width: 200, height: 200), fill: "FF0000", extra: shadow)
              + X.sp(4, CGRect(x: 400, y: 400, width: 400, height: 60), fill: "0000FF")),
        .init(shapes: X.words(2, CGRect(x: 100, y: 100, width: 600, height: 80), ["Zweite Folie Ausblick"])),
    ]
    return try f.open()
}

private let allBoxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]

@Suite struct SlidePDFPageTests {
    @Test func boundsAreTheSlideSizeForEveryBox() throws {
        let o = try pageDeck()
        let page = SlidePDFPage(deck: o.deck, index: 0)
        for box in allBoxes {
            #expect(page.bounds(for: box) == CGRect(x: 0, y: 0, width: 960, height: 540), "box \(box.rawValue)")
        }
        #expect(page.rotation == 0)
        #expect(page.slideIndex == 0)
        #expect(page.thumbnail(of: .zero, for: .mediaBox).size == .zero)
        #expect(page.thumbnail(of: NSSize(width: CGFloat.infinity, height: 10), for: .mediaBox).representations.isEmpty)
    }

    @Test func stringIsTheSlideText() throws {
        let o = try pageDeck()
        #expect(SlidePDFPage(deck: o.deck, index: 0).string == o.deck.slideText(0))
        #expect(SlidePDFPage(deck: o.deck, index: 1).string == "Zweite Folie Ausblick")
        #expect(SlidePDFPage(deck: o.deck, index: 7).string == "")
    }

    /// draw(with:to:) in page space (y up, origin at the media box origin) equals deck.draw over the bounds.
    @Test func drawWithBoxDrawsTheSlide() throws {
        let o = try pageDeck()
        let page = SlidePDFPage(deck: o.deck, index: 0)
        let viaPage = Pixels(width: 960, height: 540) { page.draw(with: .mediaBox, to: $0) }
        #expect(viaPage == o.deck.pixels(0))
        #expect(viaPage.hex(200, 200) == "FF0000")
    }

    /// thumbnail(of:for:) (PDFKit's own implementation ignores subclasses and is white; SlidePDFPage replaces it)
    /// against deck.thumbnail at the same size, incl. the shadow's position (base-space check).
    @Test func pdfKitThumbnailMatchesTheDeckThumbnail() throws {
        let o = try pageDeck()
        let page = SlidePDFPage(deck: o.deck, index: 0)
        let ns = page.thumbnail(of: NSSize(width: 480, height: 270), for: .mediaBox)
        let cg = try #require(ns.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let kit = Pixels(width: 480, height: 270) {
            $0.interpolationQuality = .high
            $0.draw(cg, in: CGRect(x: 0, y: 0, width: 480, height: 270))
        }
        let own = Pixels(image: try #require(o.deck.thumbnail(0, maxPixel: 480)))
        #expect(cg.width == 960 && cg.height == 540)
        // Red square 50…150, shadow 150…160 (20 pt → 10 px right), white beyond.
        for (x, y, want) in [(100, 100, "FF0000"), (155, 100, "000000"), (166, 100, "FFFFFF"), (300, 215, "0000FF")] {
            #expect(own.hex(x, y) == want, "deck (\(x), \(y))")
            #expect(kit.hex(x, y) == want, "PDFKit (\(x), \(y)) \(kit.hex(x, y))")
        }
        // Gross agreement: few pixels differ by more than a little (edge antialiasing only).
        var bad = 0
        for i in stride(from: 0, to: own.bytes.count, by: 4) where (0..<3).contains(where: {
            abs(Int(own.bytes[i + $0]) - Int(kit.bytes[i + $0])) > 48
        }) { bad += 1 }
        #expect(bad < 480 * 270 / 100)
    }

    /// The early test: does PDFKit write a PDFPage subclass's drawing as vector content when saving?
    @Test func savedDocumentKeepsVectorContentAndText() throws {
        let o = try pageDeck()
        let doc = PDFDocument()
        doc.insert(SlidePDFPage(deck: o.deck, index: 0), at: 0)
        doc.insert(SlidePDFPage(deck: o.deck, index: 1), at: 1)
        let data = try #require(doc.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: data))
        let text0 = reloaded.page(at: 0)?.string ?? ""
        let text1 = reloaded.page(at: 1)?.string ?? ""
        print("[12c] dataRepresentation: \(data.count) bytes, pages \(reloaded.pageCount), "
              + "page 0 text \(text0.debugDescription), page 1 text \(text1.debugDescription), "
              + "bounds \(reloaded.page(at: 0)?.bounds(for: .mediaBox) ?? .null)")
        #expect(reloaded.pageCount == 2)
        #expect(data.count > 2048)
        #expect(text0.contains("Quartalsbericht"))
        #expect(text0.contains("Wärmepumpe"))
        #expect(text1.contains("Ausblick"))
        #expect(reloaded.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 960, height: 540))
        let page = try #require(reloaded.page(at: 0))
        let px = Pixels(width: 960, height: 540) { page.draw(with: .mediaBox, to: $0) }
        // The square sits in a shadow transparency layer; CG's PDF form of that shifts sRGB red to FF2500.
        #expect(px.hex(200, 200).hasPrefix("FF") && px.bytes[(200 * 960 + 200) * 4 + 1] < 0x40)
        #expect(px.hex(310, 200) == "000000")
        #expect(px.hex(500, 430) == "0000FF")
        // Vector, not a bitmap: drawn at 4× the edges of the bar and the shadow stay sharp.
        let big = Pixels(width: 3840, height: 2160) { ctx in
            ctx.scaleBy(x: 4, y: 4)
            page.draw(with: .mediaBox, to: ctx)
        }
        #expect(big.hex(1599, 1720) == "FFFFFF")
        #expect(big.hex(1600, 1720) == "0000FF")
        #expect(big.hex(1279, 800) == "000000")
        #expect(big.hex(1280, 800) == "FFFFFF")
        let raw = String(decoding: data, as: UTF8.self)
        print("[12c] saved PDF: /Image XObjects \(raw.components(separatedBy: "/Subtype /Image").count - 1), "
              + "fonts \(raw.components(separatedBy: "/Type /Font").count - 1)")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slidekit-12c-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(doc.write(to: url))
        let written = try #require(PDFDocument(url: url))
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("[12c] write(to:): \(size) bytes, page 0 text \((written.page(at: 0)?.string ?? "").debugDescription)")
        #expect(size > 2048)
        #expect(written.page(at: 0)?.string?.contains("Quartalsbericht") == true)
    }

    /// Ligature glyphs (Calibri "tt", "ff", "fi", "fl") have no text of their own in a saved PDF ("Dritte" was
    /// read back as "Dri$e"), so search in merged PDFs missed such words. SlideKit draws without ligatures, as
    /// PowerPoint does by default.
    @Test(.enabled(if: FontResolver(theme: nil).isInstalled("Calibri")), arguments: [1200, 1800, 2800, 4400])
    func savedDocumentKeepsWordsWithLigatureCandidates(size: Int) throws {
        let words = ["Dritte", "Auflage", "offiziell", "Schifffahrt", "fluffig", "Effizienz"]
        var f = PptxFixture()
        // Calibri has the ligatures (the fixture theme's Arial has none); Office installs it on this Mac.
        let run = "<a:rPr lang=\"de-DE\" sz=\"\(size)\"><a:latin typeface=\"Calibri\"/></a:rPr>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 40, y: 40, width: 880, height: 460),
                                            body: X.body(X.para(words.joined(separator: " "), rPr: run))))]
        let o = try f.open()
        let doc = PDFDocument()
        doc.insert(SlidePDFPage(deck: o.deck, index: 0), at: 0)
        let data = try #require(doc.dataRepresentation())
        let text = try #require(PDFDocument(data: data)?.page(at: 0)?.string)
        for word in words { #expect(text.contains(word), "\(word) in \(text.debugDescription)") }
    }

    /// The merger may rotate pages: a copy keeps class, slide, text and rotation.
    @Test func copyKeepsRotation() throws {
        let o = try pageDeck()
        let page = SlidePDFPage(deck: o.deck, index: 1)
        page.rotation = 90
        let copy = try #require(page.copy() as? SlidePDFPage)
        #expect(copy !== page)
        #expect(copy.slideIndex == 1 && copy.deck.slideCount == o.deck.slideCount)
        #expect(copy.string == page.string && copy.string?.contains("Ausblick") == true)
        #expect(copy.rotation == 90)
        #expect(copy.bounds(for: .mediaBox) == page.bounds(for: .mediaBox))
    }

    /// A rotated slide page behaves like a rotated ordinary PDF page: bounds stay unrotated (PDFKit's
    /// convention), draw(with:to:) applies the rotation (as PDFPage's own drawing does and as PDFView and printing
    /// expect), the saved page carries /Rotate over unrotated content, and the thumbnail is rotated.
    @Test func rotatedPageDrawsRotatedLikeAnOrdinaryPage() throws {
        let o = try pageDeck()
        let page = SlidePDFPage(deck: o.deck, index: 0)
        page.rotation = 90
        #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 960, height: 540))
        // 90° clockwise: the slide's top edge goes to the right; slide (x, y from top) → portrait (539 − y, x).
        let live = Pixels(width: 540, height: 960) { page.draw(with: .mediaBox, to: $0) }
        #expect(live.hex(539 - 200, 200) == "FF0000")              // red square at slide (200, 200)
        #expect(live.hex(539 - 430, 500) == "0000FF")              // blue bar at slide (500, 430)
        #expect(live.hex(539 - 200, 310) == "000000")              // shadow right of the square → below it
        // Saved and reloaded: an ordinary page with /Rotate 90; PDFKit's own drawing of it matches ours.
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let data = try #require(doc.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: data))
        let saved = try #require(reloaded.page(at: 0))
        #expect(saved.rotation == 90)
        #expect(saved.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 960, height: 540))
        let kit = Pixels(width: 540, height: 960) { saved.draw(with: .mediaBox, to: $0) }
        #expect(kit.hex(539 - 200, 200).hasPrefix("FF") && kit.bytes[(200 * 540 + 339) * 4 + 1] < 0x40)
        #expect(kit.hex(539 - 430, 500) == "0000FF")
        #expect(kit.hex(539 - 200, 310) == "000000")
        #expect(saved.string?.contains("Quartalsbericht") == true)
        // Thumbnail: portrait, rotated like the page.
        let ns = page.thumbnail(of: NSSize(width: 270, height: 480), for: .mediaBox)
        let cg = try #require(ns.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 540 && cg.height == 960)
        let thumb = Pixels(image: cg)
        #expect(thumb.hex(539 - 200, 200) == "FF0000" && thumb.hex(539 - 430, 500) == "0000FF")
    }

    /// A slide page sits in an ordinary PDF document next to a PDF page (the merger case).
    @Test func mixesWithOrdinaryPages() throws {
        let o = try pageDeck()
        let plain = PDFDocument()
        plain.insert(PDFPage(), at: 0)
        let plainData = try #require(plain.dataRepresentation())
        let reloadedPlain = try #require(PDFDocument(data: plainData))
        let doc = PDFDocument()
        doc.insert(try #require(reloadedPlain.page(at: 0)), at: 0)
        doc.insert(SlidePDFPage(deck: o.deck, index: 1), at: 1)
        let outData = try #require(doc.dataRepresentation())
        let out = try #require(PDFDocument(data: outData))
        #expect(out.pageCount == 2)
        #expect(out.page(at: 1)?.string?.contains("Zweite Folie") == true)
    }
}
