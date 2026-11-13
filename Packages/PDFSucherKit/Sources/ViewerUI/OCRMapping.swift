// OCRMapping.swift — 1.2 Task 4 (spec 1.2 §5): where recognized words are on the page.
import CoreGraphics
import Foundation
import IndexKit
import MediaKit
import OutputKit
import PDFKit
import SearchKit

/// Normalized word boxes (0…1, origin top left of the page as displayed, decisions „1.2 OCR-Index“:
/// crop box and /Rotate applied) into drawing coordinates.
public enum OCRMapping {
    /// The box in PDF page space (the unrotated coordinates of `page.bounds(for: .cropBox)`), for a page
    /// with `rotation` (a multiple of 90, clockwise as PDF /Rotate).
    public static func pageRect(_ box: CGRect, cropBox crop: CGRect, rotation: Int) -> CGRect {
        let quarter = ((rotation % 360) + 360) % 360
        let shown = ZoomMath.rotatedSize(crop.size, rotation: quarter)
        // Displayed rectangle, origin top left.
        let x = box.minX * shown.width, y = box.minY * shown.height
        let w = box.width * shown.width, h = box.height * shown.height
        let (w0, h0) = (crop.width, crop.height)
        switch quarter {
        case 90:  return CGRect(x: crop.minX + y, y: crop.minY + x, width: h, height: w)
        case 180: return CGRect(x: crop.minX + w0 - x - w, y: crop.minY + y, width: w, height: h)
        case 270: return CGRect(x: crop.minX + w0 - y - h, y: crop.minY + h0 - x - w, width: h, height: w)
        default:  return CGRect(x: crop.minX + x, y: crop.maxY - y - h, width: w, height: h)
        }
    }

    /// The box in image space with the origin bottom left (an upright image of `imageSize`).
    public static func imageRect(_ box: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: box.minX * imageSize.width, y: (1 - box.maxY) * imageSize.height,
               width: box.width * imageSize.width, height: box.height * imageSize.height)
    }
}

/// Match rectangles of an OCR page: the matcher's ranges on the stored text → word slices
/// (`HighlightBoxes`) → page space. They then go through `HighlightGeometry` like text matches.
public enum OCRHighlights {
    /// OCR text that can be marked: a page recognized without words (OCR found nothing, the short text
    /// layer stays) is marked through its text layer instead (review of 1.2 Task 4).
    public static func usable(_ ocr: OCRPageText?) -> OCRPageText? {
        guard let ocr, !ocr.words.isEmpty else { return nil }
        return ocr
    }

    public static func normalizedBoxes(_ ocr: OCRPageText, highlightRanges: HighlightRanges) -> [CGRect] {
        let text = ocr.text
        let ranges = highlightRanges(text).compactMap { r -> NSRange? in
            guard r.upperBound <= text.endIndex else { return nil }
            return NSRange(r, in: text)
        }
        return HighlightBoxes.rects(for: ranges, in: ocr.words)
    }

    public static func pageRects(_ ocr: OCRPageText, highlightRanges: HighlightRanges, page: PDFPage) -> [CGRect] {
        let crop = page.bounds(for: .cropBox)
        return normalizedBoxes(ocr, highlightRanges: highlightRanges)
            .map { OCRMapping.pageRect($0, cropBox: crop, rotation: page.rotation) }
    }
}

/// The OCR text of the page the large preview shows, tagged with that page: while the view already shows
/// the next page, the previous page's words must not be drawn on it.
struct DetailOCR: Equatable {
    let ref: PageRef
    let text: OCRPageText

    func text(for page: PageRef?) -> OCRPageText? { page == ref ? text : nil }
}
