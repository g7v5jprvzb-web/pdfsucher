// ScannedPage.swift — 1.2.3 tile cache
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Fast tile drawing for scanned pages (spec 1.2.3).
///
/// A scanned page is usually one big JPEG (or JPEG 2000). PDFKit decodes it at full size for every tile (about
/// 0.1–0.25 s for a magazine page); ImageIO can decode a JPEG directly at a fraction of its size,
/// which is several times faster and looks the same at tile size.
///
/// Only pages whose content is exactly one plain JPEG or JPEG 2000 image (plus invisible OCR text, marked
/// content and colour settings) take this path. Anything else that could paint, clip or blend —
/// paths, visible text, shadings, forms, inline images, graphics-state dictionaries, masks, CMYK,
/// decode arrays — makes `plan` return nil, and the page is drawn by PDFKit as before.
enum ScannedPage {
    struct Plan {
        let jpeg: Data
        /// Maps the image's unit square into default user space (the `cm` operators before `Do`).
        let transform: CGAffineTransform
        let pixelWidth: Int, pixelHeight: Int
    }

    /// Draws `page` like `page.draw(with: .cropBox, to:)` if it is a plain scan. `ctx` must already be
    /// set up as for that call. Returns false (drawing nothing) for any other page.
    static func draw(_ page: PDFPage, in ctx: CGContext) -> Bool {
        // PDFKit draws annotations with the page; this path would not.
        guard page.annotations.isEmpty, let cgPage = page.pageRef, let plan = plan(cgPage) else { return false }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        page.transform(ctx, for: .cropBox)
        ctx.clip(to: page.bounds(for: .cropBox))
        ctx.concatenate(plan.transform)
        // Pixels the image covers on the tile: decode at that size, not at the scan's.
        let device = ctx.userSpaceToDeviceSpaceTransform
        let across = hypot(device.a, device.b), down = hypot(device.c, device.d)
        let needed = Int((max(across, down)).rounded(.up)) + 2
        guard needed > 0,
              let image = decode(plan.jpeg, maxPixel: min(needed, max(plan.pixelWidth, plan.pixelHeight))) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }

    static func decode(_ jpeg: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,     // a PDF ignores EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The single JPEG of a plain scanned page, or nil.
    static func plan(_ page: CGPDFPage) -> Plan? {
        let state = ScanState(page: page)
        let table = operatorTable()
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        let scanned = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        guard scanned, !state.complex, let found = state.image else { return nil }
        return found
    }

    // MARK: - Content stream scan

    private final class ScanState {
        let page: CGPDFPage
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var textRenderMode = 0
        var complex = false
        var image: Plan?

        init(page: CGPDFPage) { self.page = page }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    /// Operators that may paint, clip or change blending: any of them means "not a plain scan".
    private static let complexOperators = [
        "b", "B", "b*", "B*", "f", "F", "f*", "s", "S", "sh", "BI", "ID", "EI", "d0", "d1",
        "m", "l", "c", "v", "y", "h", "re", "W", "W*", "n", "gs",
    ]

    private static func operatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        for name in complexOperators {
            CGPDFOperatorTableSetCallback(table, name) { _, info in ScannedPage.state(info).complex = true }
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = ScannedPage.state(info)
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = ScannedPage.state(info)
            if let top = s.stack.popLast() { s.ctm = top } else { s.complex = true }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = ScannedPage.state(info)
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &v[i]) else { s.complex = true; return }
            }
            // PDF: CTM' = M × CTM.
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { ScannedPage.state(info).textRenderMode = mode } else { ScannedPage.state(info).complex = true }
        }
        // Text shows only count when it is visible (OCR layers use mode 3, invisible).
        for name in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                let s = ScannedPage.state(info)
                if s.textRenderMode != 3 { s.complex = true }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = ScannedPage.state(info)
            var name: UnsafePointer<CChar>?
            guard s.image == nil, CGPDFScannerPopName(scanner, &name), let name,
                  let plan = ScannedPage.imagePlan(named: name, page: s.page, ctm: s.ctm) else { s.complex = true; return }
            s.image = plan
        }
        return table
    }

    /// A plain 8-bit RGB or gray JPEG or JPEG 2000 image XObject, without masks or decode arrays.
    private static func imagePlan(named name: UnsafePointer<CChar>, page: CGPDFPage, ctm: CGAffineTransform) -> Plan? {
        guard let pageDict = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
              CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var subtype: UnsafePointer<CChar>?, filter: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image",
              CGPDFDictionaryGetName(dict, "Filter", &filter), let filter,
              let expected = ["DCTDecode": CGPDFDataFormat.jpegEncoded, "JPXDecode": .JPEG2000][String(cString: filter)] else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width), CGPDFDictionaryGetInteger(dict, "Height", &height),
              width > 0, height > 0,
              !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bits) || bits == 8 else { return nil }
        var object: CGPDFObjectRef?
        for key in ["SMask", "Mask", "Decode", "ImageMask", "SMaskInData", "Alternates", "OC"] {
            if CGPDFDictionaryGetObject(dict, key, &object) {
                // `/ImageMask false` and `/SMaskInData 0` are harmless; anything else is not.
                var flag: CGPDFBoolean = 0, number: CGPDFInteger = 0
                if key == "ImageMask", CGPDFDictionaryGetBoolean(dict, key, &flag), flag == 0 { continue }
                if key == "SMaskInData", CGPDFDictionaryGetInteger(dict, key, &number), number == 0 { continue }
                return nil
            }
        }
        guard isRGBOrGray(dict) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == expected else { return nil }
        return Plan(jpeg: data as Data, transform: ctm, pixelWidth: width, pixelHeight: height)
    }

    /// DeviceRGB, DeviceGray, or an ICC profile with 1 or 3 components (CMYK JPEGs decode differently).
    private static func isRGBOrGray(_ dict: CGPDFDictionaryRef) -> Bool {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name {
            return ["DeviceRGB", "DeviceGray"].contains(String(cString: name))
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let array, CGPDFArrayGetCount(array) == 2,
              CGPDFArrayGetName(array, 0, &name), let name, String(cString: name) == "ICCBased" else { return false }
        var profile: CGPDFStreamRef?, components: CGPDFInteger = 0
        guard CGPDFArrayGetStream(array, 1, &profile), let profile, let profileDict = CGPDFStreamGetDictionary(profile),
              CGPDFDictionaryGetInteger(profileDict, "N", &components) else { return false }
        return components == 1 || components == 3
    }
}
