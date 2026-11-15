// PreviewGeometry.swift — 1.3.4 Vorschau-Puffer
import AppKit
import Foundation
import PDFKit

/// Where and how large the large preview's PDFView shows a page, without a PDFView (pure, spec 1.3.4): the
/// stand-in picture is drawn there, so the change to the PDFView does not jump. Mirrors `PDFPageView.apply`.
enum PreviewGeometry {
    /// Pages with images of this many pixels together are slow in PDFKit: a ScanSnap 1-bit scan (~35 MP) ~280 ms per
    /// draw, a 2474 × 3503 JPEG scan (8.7 MP) blocked `go(to:)` 256 ms (measured 1.3.4).
    static let heavyPixels = 4_000_000

    /// The page's crop box as shown, rotation applied.
    static func pageSize(_ page: PDFPage) -> CGSize {
        ZoomMath.rotatedSize(page.bounds(for: .cropBox).size, rotation: page.rotation)
    }

    /// The scale the PDFView would show `page` at in a view of `view` points (see `PDFPageView.apply` and `limit`).
    @MainActor static func scale(mode: PreviewZoom.Mode, fractions: [Int], reference: CGFloat?, beyondWidth: Bool,
                      page: CGSize, view: CGSize) -> CGFloat {
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let fill = (reference ?? view.width) - scroller
        let limit = beyondWidth ? CGFloat(PreviewZoom.steps[PreviewZoom.steps.count - 1]) / 100
            : PreviewWidthMath.maxScale(page: page, referenceWidth: fill)
        let scale: CGFloat
        if reference != nil {
            scale = PreviewWidthMath.scale(mode, fractions: fractions, page: page, reference: CGSize(width: fill, height: view.height))
        } else {
            switch mode {
            case .fitPage:
                scale = PreviewWidthMath.scale(.fitPage, fractions: fractions, page: page, reference: view)
            case .percent(let p):
                scale = CGFloat(p) / 100
            case .pageWidth(let level):
                let fraction = fractions.indices.contains(level - 1) ? fractions[level - 1] : 100
                scale = ZoomMath.pageWidthScale(fraction: fraction, viewWidth: view.width - scroller, page: page)
            }
        }
        return min(scale, limit)
    }

    /// The page's rectangle in the view (origin top left): centred when it fits, at the top when it is taller,
    /// at the left when it is wider (where the PDFView starts after `go(to:)`).
    static func frame(page: CGSize, scale: CGFloat, in view: CGSize) -> CGRect {
        let size = CGSize(width: page.width * scale, height: page.height * scale)
        return CGRect(x: size.width < view.width ? (view.width - size.width) / 2 : 0,
                      y: size.height < view.height ? (view.height - size.height) / 2 : 0,
                      width: size.width, height: size.height)
    }

    /// The part of a tile picture the page covers (not transparent), in pixels from the top left; nil when it is
    /// all transparent. A tile is the grid cell with the page drawn aspect-fit inside (1.3.4: the stand-in shows only
    /// the page, so a landscape page in a portrait cell does not shrink).
    static func contentRect(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Where to draw a whole picture of `imageSize` so that its part `content` fills `frame`.
    static func tileFrame(content: CGRect, imageSize: CGSize, into frame: CGRect) -> CGRect {
        let sx = frame.width / max(content.width, 1), sy = frame.height / max(content.height, 1)
        return CGRect(x: frame.minX - content.minX * sx, y: frame.minY - content.minY * sy,
                      width: imageSize.width * sx, height: imageSize.height * sy)
    }

    /// Whether the page's images (also inside forms, one level down) have `heavyPixels` or more together.
    /// Reads only dictionaries, decodes nothing.
    static func isHeavy(_ page: CGPDFPage) -> Bool {
        guard let dict = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        return imagePixels(in: resources, depth: 0) >= heavyPixels
    }

    private static func imagePixels(in resources: CGPDFDictionaryRef, depth: Int) -> Int {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return 0 }
        final class Sum { var pixels = 0; var depth = 0 }
        let sum = Sum()
        sum.depth = depth
        CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
            let sum = Unmanaged<Sum>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dict, "Width", &width), CGPDFDictionaryGetInteger(dict, "Height", &height),
                   width > 0, height > 0 {
                    sum.pixels += width * height
                }
            case "Form" where sum.depth == 0:
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner {
                    sum.pixels += PreviewGeometry.imagePixels(in: inner, depth: 1)
                }
            default:
                break
            }
            return true
        }, Unmanaged.passUnretained(sum).toOpaque())
        return sum.pixels
    }
}
