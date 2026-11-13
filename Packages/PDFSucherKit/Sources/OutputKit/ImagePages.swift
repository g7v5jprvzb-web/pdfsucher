// ImagePages.swift — OCR 1.2, package O2 (spec §6, §12)
import CoreGraphics
import Foundation
import IndexKit
import ImageIO
import PDFKit

/// Image files as pages of a merged or printed PDF.
public enum ImagePages {
    /// Image extensions PDFSucher indexes (spec 1.2 §2), lower-cased: `SupportedSourceTypes` (1.2.1).
    public static var extensions: Set<String> { SupportedSourceTypes.imageExtensions }

    /// A4 in points and the 10 mm margin (spec §6).
    static let a4 = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 28.35
    /// Longest embedded image side: A4's long side at 300 dpi; more only makes the PDF bigger.
    static let maxPixel = 3508

    /// Whether `url` names an image file (by extension, case-insensitive) rather than a PDF.
    public static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Whether `url` is an image `makePage` can use: like `makePage` it decodes the primary image
    /// (as a small preview, so it stays cheap), not just the header.
    public static func isReadable(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                              options as CFDictionary) else { return false }
        return image.width > 0 && image.height > 0
    }

    /// A one-page PDF page showing the image upright (EXIF orientation applied): A4, landscape if the
    /// upright image is wider than tall (square → portrait), image scaled to fit inside a 10 mm margin
    /// and centred (small images are scaled up). At most 300 dpi are embedded. PNGs and images with
    /// transparency stay lossless; other photos (JPEG, HEIC, DNG, …) are embedded as JPEG.
    /// Throws `OutputError.cannotOpen` if the file is missing or not a readable image.
    public static func makePage(from url: URL) throws -> PDFPage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            outputLog.error("Cannot read image \(url.path, privacy: .public)")
            throw OutputError.cannotOpen(url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        var limit = maxPixel
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if let properties,
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) > 0 {
            limit = min(limit, max(width, height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              upright.width > 0, upright.height > 0 else {
            outputLog.error("Cannot decode image \(url.path, privacy: .public)")
            throw OutputError.cannotOpen(url)
        }
        // JPEG has no alpha: images with transparency stay lossless, so transparent areas show the page.
        // Ask the file, not the decoded image: ImageIO decodes every HEIC with an alpha channel.
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let lossless = (CGImageSourceGetType(source) as String?) == "public.png" || hasAlpha
        let image = lossless ? upright : (jpeg(upright) ?? upright)
        guard let page = render(image) else {
            outputLog.error("Cannot build a page for \(url.path, privacy: .public)")
            throw OutputError.cannotOpen(url)
        }
        return page
    }

    /// `image` re-encoded as JPEG, so the PDF context embeds it as DCT data instead of raw pixels.
    private static func jpeg(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func render(_ image: CGImage) -> PDFPage? {
        let landscape = image.width > image.height
        var mediaBox = CGRect(origin: .zero, size: landscape ? CGSize(width: a4.height, height: a4.width) : a4)
        let space = mediaBox.insetBy(dx: margin, dy: margin)
        let scale = min(space.width / CGFloat(image.width), space.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: space.midX - size.width / 2, y: space.midY - size.height / 2,
                            width: size.width, height: size.height)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
