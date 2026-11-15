import CoreGraphics
import Foundation
import IndexKit
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

private let relNS = NS.relPkg
private let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

/// A deck with `count` slides; `hidden` are 1-based slide numbers carrying show="0".
private func deckData(count: Int = 3, hidden: Set<Int> = [2],
                      sz: String = "<p:sldSz cx=\"12192000\" cy=\"6858000\"/>",
                      presentation: Bool = true) -> Data {
    var b = OOXMLBuilder()
    b.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
    b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"r1\" Type=\"\(officeDocument)\" Target=\"ppt/presentation.xml\"/></Relationships>")
    let numbers = (0..<count).map { $0 + 1 }
    let ids = numbers.map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0)\"/>" }.joined()
    if presentation {
        b.add("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(NS.p)\" xmlns:r=\"\(NS.r)\"><p:sldIdLst>\(ids)</p:sldIdLst>\(sz)</p:presentation>")
    }
    var rels = ""
    for i in numbers {
        rels += "<Relationship Id=\"rId\(i)\" Type=\"http://x/slide\" Target=\"slides/slide\(i).xml\"/>"
        b.add("ppt/slides/slide\(i).xml", "<p:sld xmlns:p=\"\(NS.p)\"\(hidden.contains(i) ? " show=\"0\"" : "")/>")
    }
    b.add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relNS)\">\(rels)</Relationships>")
    return b.build()
}

private final class TempFile {
    let url: URL
    init(_ data: Data?, ext: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString).\(ext)")
        if let data { try data.write(to: url) }
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func loadError(_ data: Data?, ext: String = "pptx") throws -> SlideKitError? {
    let f = try TempFile(data, ext: ext)
    do { _ = try SlideDeck(url: f.url); return nil } catch let e as SlideKitError { return e }
}

@Suite struct DeckLoadingTests {
    @Test func hiddenSlidesAreLeftOut() throws {
        let f = try TempFile(deckData(), ext: "pptx")
        let deck = try SlideDeck(url: f.url)
        #expect(deck.slideCount == 2)
        #expect(deck.slides.map(\.partPath) == ["ppt/slides/slide1.xml", "ppt/slides/slide3.xml"])
        #expect(deck.slides[1].partPath == "ppt/slides/slide3.xml")
        #expect(deck.slides[1].powerPointNumber == 3)
    }

    @Test func slideSizeInPoints() throws {
        let f = try TempFile(deckData(), ext: "pptx")
        #expect(try SlideDeck(url: f.url).slideSize == CGSize(width: 960, height: 540))
    }

    @Test func extensionIsCaseInsensitive() throws {
        for ext in ["PPTX", "pptm", "PpTm"] {
            let f = try TempFile(deckData(), ext: ext)
            #expect(try SlideDeck(url: f.url).slideCount == 2)
        }
    }

    @Test func noVisibleSlidesIsAnEmptyDeck() throws {
        let f = try TempFile(deckData(count: 0), ext: "pptx")
        #expect(try SlideDeck(url: f.url).slideCount == 0)
    }

    @Test func pptIsRejectedWithoutOpening() throws {
        // The files do not exist: the extension alone decides.
        for ext in ["ppt", "PPT"] {
            #expect(try loadError(nil, ext: ext) == .unsupportedFormat)
        }
    }

    @Test func otherExtensionsAreUnsupported() throws {
        for ext in ["ppsx", "potx", "key", "docx", "zip", ""] {
            #expect(try loadError(deckData(), ext: ext) == .unsupportedFormat)
        }
    }

    @Test func encryptedOOXML() throws {
        let ole = CFBBuilder.file(streams: ["EncryptionInfo", "EncryptedPackage"])
        #expect(try loadError(ole) == .encrypted)
        #expect(try loadError(ole, ext: "pptm") == .encrypted)
    }

    @Test func otherOLEFilesAreUnsupported() throws {
        #expect(try loadError(CFBBuilder.file(streams: ["PowerPoint Document", "Current User"])) == .unsupportedFormat)
        #expect(try loadError(OOXMLBuilder.oleCompoundFile()) == .unsupportedFormat)
    }

    @Test func notAZip() throws {
        #expect(try loadError(Data("hello, world".utf8)) == .notAZip)
        #expect(try loadError(Data()) == .notAZip)
    }

    @Test func missingPresentationIsMalformed() throws {
        guard case .malformed = try loadError(deckData(presentation: false)) else {
            Issue.record("expected .malformed"); return
        }
    }

    @Test func truncatedZipIsMalformed() throws {
        let data = deckData()
        guard case .malformed = try loadError(data.prefix(data.count / 2)) else {
            Issue.record("expected .malformed"); return
        }
    }

    @Test func missingFileIsMalformed() throws {
        guard case .malformed = try loadError(nil) else { Issue.record("expected .malformed"); return }
    }

    @Test func stubsAndOutOfRangeIndicesDoNotTrap() throws {
        let f = try TempFile(deckData(), ext: "pptx")
        let deck = try SlideDeck(url: f.url)
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for i in [-1, 0, 1, 2, Int.max, Int.min] {
            #expect(deck.slideText(i) == "")
            #expect(deck.wordBoxes(i).isEmpty)
            deck.draw(i, in: ctx, rect: CGRect(x: 0, y: 0, width: 8, height: 8))
            // Bare slides without layout/master still render (white).
            #expect((deck.thumbnail(i, maxPixel: 64) == nil) == !(0..<deck.slideCount).contains(i))
        }
    }

    @Test func wordBoxesAreIndexKitOCRWords() throws {
        // Spec §5: wordBoxes returns IndexKit.OCRWord (the type the index stores for OCR pages).
        let f = try TempFile(deckData(count: 1, hidden: []), ext: "pptx")
        let deck = try SlideDeck(url: f.url)
        let words: [IndexKit.OCRWord] = deck.wordBoxes(0)
        #expect(words.isEmpty)
        let w = OCRWord(range: NSRange(location: 2, length: 3), box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))
        #expect(w.range == NSRange(location: 2, length: 3))
        #expect(w.box.width == 0.3)
    }
}

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>. Opens every deck read-only.
@Suite struct DeckCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]

    @Test(.enabled(if: corpus != nil)) func openEveryDeckQuickly() throws {
        let dir = URL(fileURLWithPath: try #require(Self.corpus))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for url in files {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let clock = ContinuousClock()
            var deck: SlideDeck?
            let elapsed = try clock.measure { deck = try SlideDeck(url: url) }
            let d = try #require(deck)
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            print(String(format: "[corpus] %@: %.1f MB, %d visible slides, %.0f×%.0f pt, opened in %.1f ms",
                         url.lastPathComponent, Double(size) / 1_048_576, d.slideCount,
                         d.slideSize.width, d.slideSize.height, ms))
            #expect(d.slideCount > 0, "\(url.lastPathComponent)")
            #expect(elapsed < .seconds(1), "\(url.lastPathComponent) took \(elapsed)")
        }
    }
}
