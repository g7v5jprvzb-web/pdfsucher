import CoreGraphics
import Foundation
import ImageIO
import TestSupport
import UniformTypeIdentifiers
@testable import OOXMLKit

/// Namespace declarations for XML snippets in drawing tests.
let drawingNS = """
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
"""

func xml(_ s: String) throws -> OOXMLNode { try OOXMLNode.parse(Data(s.utf8)) }

/// A 200×100 RGBA canvas (sRGB, premultiplied) whose CTM maps points with origin top-left, y down —
/// the convention DrawingRenderer expects.
final class Canvas {
    let width = 200, height = 100
    let ctx: CGContext

    init() {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("no bitmap context") }
        c.translateBy(x: 0, y: 100)
        c.scaleBy(x: 1, y: -1)
        ctx = c
    }

    /// Premultiplied RGBA bytes of the pixel at (x, y), y measured from the top.
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let base = ctx.data else { return (0, 0, 0, 0) }
        let p = base.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    func isClear(_ x: Int, _ y: Int) -> Bool { pixel(x, y).a == 0 }

    func matches(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, a: Int = 255, tol: Int = 12) -> Bool {
        let p = pixel(x, y)
        return abs(p.r - r) <= tol && abs(p.g - g) <= tol && abs(p.b - b) <= tol && abs(p.a - a) <= tol
    }

    var allClear: Bool {
        for y in 0..<height { for x in 0..<width where !isClear(x, y) { return false } }
        return true
    }
}

/// Encodes a w×h image whose left half is `left` and right half `right` (RGB bytes) as `type`.
/// `vertical`: `left` is the top half and `right` the bottom half instead.
func testImage(width: Int = 20, height: Int = 10, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8),
               type: UTType = .png, vertical: Bool = false) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: CGFloat(left.0) / 255, green: CGFloat(left.1) / 255,
                             blue: CGFloat(left.2) / 255, alpha: 1))
    // Bitmap contexts are y-up: the top half is y ≥ height/2.
    let first = vertical ? CGRect(x: 0, y: height / 2, width: width, height: height - height / 2)
                         : CGRect(x: 0, y: 0, width: width / 2, height: height)
    let second = vertical ? CGRect(x: 0, y: 0, width: width, height: height / 2)
                          : CGRect(x: width / 2, y: 0, width: width - width / 2, height: height)
    ctx.fill(first)
    ctx.setFillColor(CGColor(srgbRed: CGFloat(right.0) / 255, green: CGFloat(right.1) / 255,
                             blue: CGFloat(right.2) / 255, alpha: 1))
    ctx.fill(second)
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func makePackage(_ build: (inout OOXMLBuilder) -> Void) throws -> OPCPackage {
    var b = OOXMLBuilder()
    build(&b)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("drw-\(UUID().uuidString).zip")
    try b.build().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return OPCPackage(zip: try ZipArchive(url: url))
}

/// Relationship file content for `ppt/slides/slide1.xml` with (Id, Target) pairs.
func slideRels(_ rels: [(String, String)]) -> String {
    let items = rels.map {
        "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\($0.1)\"/>"
    }.joined()
    return "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(items)</Relationships>"
}

func emptyPackage() throws -> OPCPackage {
    try makePackage { $0.add("x.xml", "<x/>") }
}

func renderer(_ pkg: OPCPackage) -> DrawingRenderer {
    DrawingRenderer(images: ImageDecoder(package: pkg), fonts: FontResolver(theme: nil))
}

let plainColors = ColorContext(theme: .fallback)

/// `a:xfrm` in points (converted to EMU).
func xfrmXML(_ x: Double, _ y: Double, _ w: Double, _ h: Double, extra: String = "", attrs: String = "") -> String {
    let e = { (v: Double) in String(Int((v * 12700).rounded())) }
    return "<a:xfrm \(attrs)><a:off x=\"\(e(x))\" y=\"\(e(y))\"/><a:ext cx=\"\(e(w))\" cy=\"\(e(h))\"/>\(extra)</a:xfrm>"
}
