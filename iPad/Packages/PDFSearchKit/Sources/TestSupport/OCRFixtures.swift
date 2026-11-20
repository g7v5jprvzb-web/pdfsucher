// OCRFixtures.swift — 1.2 OCR (O1): images with known text for recognition tests.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OCRFixturesError: Error, CustomStringConvertible {
    case cannotCreateContext
    case cannotWrite(URL)

    public var description: String {
        switch self {
        case .cannotCreateContext: "OCRFixtures: cannot create a bitmap or PDF context"
        case .cannotWrite(let url): "OCRFixtures: cannot write \(url.path)"
        }
    }
}

public enum OCRFixtures {
    /// Black Helvetica text on white, one entry of `lines` per line, starting top left with a
    /// margin of one font size. `wordRects` maps every space-separated word to its rectangle,
    /// normalized 0…1 with the origin top left (the convention of `OCRWord.box`).
    /// A word that occurs twice keeps its first rectangle.
    public static func textImage(_ lines: [String], size: CGSize = CGSize(width: 1600, height: 1000),
                                 fontSize: CGFloat = 64) throws -> (image: CGImage, wordRects: [String: CGRect]) {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OCRFixturesError.cannotCreateContext
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        var rects: [String: CGRect] = [:]
        let lineHeight = fontSize * 1.6
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let baseline = size.height - fontSize - CGFloat(index) * lineHeight - fontSize * 0.8
            let x = fontSize
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(ctLine, context)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            let ns = line as NSString
            var location = 0
            for word in line.split(separator: " ", omittingEmptySubsequences: true) {
                let range = ns.range(of: String(word), range: NSRange(location: location, length: ns.length - location))
                location = range.location + range.length
                let start = CTLineGetOffsetForStringIndex(ctLine, range.location, nil)
                let end = CTLineGetOffsetForStringIndex(ctLine, range.location + range.length, nil)
                let top = size.height - (baseline + ascent)
                let rect = CGRect(x: (x + start) / size.width, y: top / size.height,
                                  width: (end - start) / size.width, height: (ascent + descent) / size.height)
                if rects[String(word)] == nil { rects[String(word)] = rect }
            }
        }
        guard let image = context.makeImage() else { throw OCRFixturesError.cannotCreateContext }
        return (image, rects)
    }

    /// Writes `image` as PNG, JPEG, HEIC, … (any ImageIO destination type), optionally with an
    /// EXIF/TIFF orientation (1…8; e.g. 8 = viewers turn it 90° counter-clockwise to show it).
    public static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OCRFixturesError.cannotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OCRFixturesError.cannotWrite(url) }
    }

    /// A "scanned" PDF: every page only shows one of `images`, filling the page (A4 portrait,
    /// or landscape for `landscape`).
    public static func makeScanPDF(at url: URL, images: [CGImage], landscape: Bool = false) throws {
        var box = landscape ? CGRect(x: 0, y: 0, width: 842, height: 595) : CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OCRFixturesError.cannotCreateContext }
        for image in images {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// `image` rotated by 90° clockwise (so a page showing it needs /Rotate 270 to be upright).
    public static func rotatedClockwise(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OCRFixturesError.cannotCreateContext
        }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { throw OCRFixturesError.cannotCreateContext }
        return rotated
    }

    /// Page 0: `text` as a real text layer; page 1: `image` only.
    public static func makeMixedPDF(at url: URL, text: String, image: CGImage) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OCRFixturesError.cannotCreateContext }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 50, y: 780)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }
}
