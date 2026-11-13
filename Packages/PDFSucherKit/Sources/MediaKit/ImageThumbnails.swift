// ImageThumbnails.swift — OCR 1.2, package O2 (spec §5, §12)
import CoreGraphics
import Foundation
import ImageIO

/// Tile previews for image files (PNG, JPEG, HEIC, DNG and whatever else ImageIO reads).
public enum ImageThumbnails {
    /// The image upright (EXIF orientation applied), scaled so its longer side is at most `maxPixel`;
    /// never scaled up. An embedded preview (cameras store one in JPEG and DNG) is used when it is at
    /// least that large, which spares developing a RAW file for every tile; a smaller preview (often
    /// only 160 px) would look blurry, so then the full image is decoded (JPEG/HEIC subsampled, fast).
    /// Reads the file's primary image (HEIC may hold several). `nil` if the file is missing or not a
    /// readable image, or `maxPixel <= 0`. Thread-safe; call off the main thread.
    public static func thumbnail(for url: URL, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        var limit = maxPixel
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) > 0 {
            limit = min(limit, max(width, height))
        }
        func make(fromFullImage: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                fromFullImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
        if let preview = make(fromFullImage: false), max(preview.width, preview.height) >= limit {
            return preview
        }
        return make(fromFullImage: true)
    }
}
