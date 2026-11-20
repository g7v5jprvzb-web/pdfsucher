// VisionOCRSource.swift — 1.2 OCR (O1): the OCRSource the app uses.
import CoreGraphics
import Foundation
import IndexKit
import PDFKit

/// Recognizes scan pages and image files with `OCRRecognizer` (spec 1.2 §3):
/// - PDF page: rendered with `PDFPageRenderer` at 300 dpi (at most 6,000 px), rotation applied,
///   so word boxes refer to the page as displayed.
/// - Image: `ImageLoader` (full resolution up to 6,000 px on the long side, EXIF orientation
///   applied, DNG via Core Image RAW); boxes refer to the upright image.
/// A file or page that cannot be decoded throws `OCRSourceError.unreadable`. A file that cannot
/// be reached (missing, no permission, share gone) throws `VisionOCRSourceError.unavailable`,
/// and Vision errors are passed on: the Indexer retries both next run (spec 1.2 §8). Every call opens the file anew, so calls are
/// independent and may run concurrently.
public enum VisionOCRSourceError: Error, Equatable {
    /// The file is missing or not readable right now (not damaged): retried next run.
    case unavailable(URL)
}

public struct VisionOCRSource: OCRSource {
    public static let scanDPI: CGFloat = 300
    #if os(iOS)
    /// iPad: smaller limit to keep memory low (two recognitions run at once; 4000² RGBA ≈ 64 MB each).
    /// A4 at 300 dpi (2480 × 3508) and 12-MP photos (4032 × 3024) still fit (almost) unscaled.
    public static let maxPixel = 4000
    #else
    public static let maxPixel = 6000
    #endif

    private let recognizer: OCRRecognizer

    public init(recognizer: OCRRecognizer = .init()) {
        self.recognizer = recognizer
    }

    public func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult {
        // Decoders return nil for a missing file just like for a damaged one; tell them apart first.
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw VisionOCRSourceError.unavailable(url) }
        return try autoreleasepool {
            let image: CGImage
            switch kind {
            case .image:
                image = try ImageLoader.cgImage(contentsOf: url, maxPixel: Self.maxPixel)
            case .word, .powerpoint:
                throw OCRSourceError.unreadable(url) // Office documents are never recognised
            case .pdf:
                guard let document = PDFDocument(url: url) else { throw OCRSourceError.unreadable(url) }
                if document.isLocked, !document.unlock(withPassword: "") { throw OCRSourceError.unreadable(url) }
                guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex),
                      let rendered = PDFPageRenderer.render(page, dpi: Self.scanDPI, maxPixel: Self.maxPixel) else {
                    throw OCRSourceError.unreadable(url)
                }
                image = rendered
            }
            let (text, words) = try recognizer.recognize(image)
            return OCRResult(text: text, words: words)
        }
    }
}
