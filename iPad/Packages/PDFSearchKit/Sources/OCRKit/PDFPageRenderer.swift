// PDFPageRenderer.swift — 1.2 OCR (O1), spec §3: scan pages at 300 dpi.
import CoreGraphics
import Foundation
import PDFKit

/// Renders a PDF page for text recognition: crop box, rotation applied (as displayed), white
/// background, `dpi` resolution, but at most `maxPixel` on the long side (a large-format page
/// would otherwise need gigabytes).
enum PDFPageRenderer {
    static func render(_ page: PDFPage, dpi: CGFloat = 300, maxPixel: Int = 6000) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let displayed = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        var scale = dpi / 72
        let long = max(displayed.width, displayed.height) * scale
        if long > CGFloat(maxPixel) { scale = CGFloat(maxPixel) / max(displayed.width, displayed.height) }
        let width = Int((displayed.width * scale).rounded()), height = Int((displayed.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / displayed.width, y: CGFloat(height) / displayed.height)
        // `draw(with:to:)` applies the crop box and the page rotation (same as PDFView).
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
