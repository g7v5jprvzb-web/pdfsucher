// ImageLoader.swift — 1.2 OCR (O1), spec §3: images for recognition.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IndexKit

/// Loads an image file for text recognition: full resolution, but at most `maxPixel` on the
/// long side (larger images are scaled down, spec 1.2 §3), upright according to the EXIF
/// orientation. DNG files are developed with Core Image's RAW processing (`CIRAWFilter`).
/// Throws `OCRSourceError.unreadable` for anything that is not a decodable image.
enum ImageLoader {
    static func cgImage(contentsOf url: URL, maxPixel: Int) throws -> CGImage {
        let image: CGImage? = url.pathExtension.lowercased() == "dng"
            ? raw(url, maxPixel: maxPixel)
            : decoded(url, maxPixel: maxPixel)
        guard let image else { throw OCRSourceError.unreadable(url) }
        return image
    }

    private static func decoded(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              case let index = CGImageSourceGetPrimaryImageIndex(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // The thumbnail API decodes, applies the orientation and scales in one step; with the
        // long side as limit it returns the full resolution.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func raw(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let long = max(native.width, native.height)
        guard long > 0 else { return nil }
        if long > CGFloat(maxPixel) { filter.scaleFactor = Float(CGFloat(maxPixel) / long) }
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        return rawContext.createCGImage(output, from: extent)
    }

    /// Shared (thread-safe; creating one per image would set up Metal each time).
    private static let rawContext = CIContext(options: [.useSoftwareRenderer: false])
}
