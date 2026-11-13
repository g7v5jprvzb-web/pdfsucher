// ImageDocument.swift — 1.2 Task 5 (spec 1.2 §5)
import AppKit
import Foundation
import MediaKit
import PDFKit

/// An image as a one-page PDF document in memory, so tiles, the large preview, zoom and highlights work
/// exactly like PDF pages. The image is upright (EXIF orientation applied, like the OCR word boxes).
enum ImageDocument {
    static func make(_ url: URL, maxPixel: Int) -> PDFDocument? {
        image(url, maxPixel: maxPixel).flatMap(document(from:))
    }

    /// The upright image, decoded off the main actor.
    static func image(_ url: URL, maxPixel: Int) -> CGImage? {
        ImageThumbnails.thumbnail(for: url, maxPixel: maxPixel)
    }

    static func document(from cg: CGImage) -> PDFDocument? {
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        guard let page = PDFPage(image: image) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }
}
