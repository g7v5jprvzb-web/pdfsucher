// ImageFixtures.swift — OCR 1.2 (spec §10: text rendered into PNG/JPEG/HEIC)
import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum ImageFixturesError: Error, CustomStringConvertible {
    case cannotRender, cannotWrite(URL)

    public var description: String {
        switch self {
        case .cannotRender: "ImageFixtures: cannot create a bitmap context"
        case .cannotWrite(let url): "ImageFixtures: cannot write \(url.path)"
        }
    }
}

public enum ImageFixtures {
    public enum Format: String, Sendable, CaseIterable {
        case png = "public.png", jpeg = "public.jpeg", heic = "public.heic"
    }

    /// Black `text` on white, `size` in pixels (stored orientation), font height a quarter of the
    /// shorter side. `exifOrientation` (1…8) is written as the file's orientation tag only; the pixels
    /// stay as drawn, as a camera stores them. `embedThumbnail` stores a small preview in the file
    /// (as cameras do in JPEG and DNG).
    public static func makeImage(at url: URL, text: String, size: CGSize, format: Format,
                                 exifOrientation: Int = 1, embedThumbnail: Bool = false) throws {
        precondition((1...8).contains(exifOrientation), "EXIF orientation is 1…8")
        let image = try render(text: text, size: size)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.rawValue as CFString, 1, nil) else {
            throw ImageFixturesError.cannotWrite(url)
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation,
                                           kCGImageDestinationEmbedThumbnail: embedThumbnail]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageFixturesError.cannotWrite(url) }
    }

    /// A uniformly mid-grey image (no white border), for checking where an image lands on a page.
    public static func makeSolidImage(at url: URL, size: CGSize, format: Format, exifOrientation: Int = 1) throws {
        precondition((1...8).contains(exifOrientation), "EXIF orientation is 1…8")
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageFixturesError.cannotRender
        }
        context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, format.rawValue as CFString, 1, nil) else {
            throw ImageFixturesError.cannotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: exifOrientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageFixturesError.cannotWrite(url) }
    }

    /// The drawn bitmap (black text on white, top-left start of the text at 10 % of the width).
    public static func render(text: String, size: CGSize) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageFixturesError.cannotRender
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, min(size.width, size.height) / 4, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: size.width * 0.1, y: size.height * 0.4)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw ImageFixturesError.cannotRender }
        return image
    }
}
