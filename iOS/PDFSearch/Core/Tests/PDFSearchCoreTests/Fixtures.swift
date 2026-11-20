import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Test files written to a fresh temporary folder.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    /// A PDF with one page per string (12 pt Helvetica, A4).
    @discardableResult
    func makePDF(_ relativePath: String, pages: [String]) throws -> URL {
        let target = file(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(target as CFURL, mediaBox: &box, nil) else { throw FixtureError.cannotCreate }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return target
    }

    /// A JPEG showing `text` in large black letters on white.
    @discardableResult
    func makeJPEG(_ relativePath: String, text: String) throws -> URL {
        let target = file(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = 1600, height = 400
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw FixtureError.cannotCreate }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 60, y: 170)
        CTLineDraw(line, context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw FixtureError.cannotCreate }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.cannotCreate }
        return target
    }

    func setModified(_ relativePath: String, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file(relativePath).path)
    }
}

enum FixtureError: Error {
    case cannotCreate
}
