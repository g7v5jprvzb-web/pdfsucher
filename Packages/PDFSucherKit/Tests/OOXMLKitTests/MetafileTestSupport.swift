import Compression
import CoreGraphics
import Foundation
import TestSupport
@testable import OOXMLKit

/// Little-endian byte writer for handcrafted metafile records.
final class LEBytes {
    var data = Data()
    @discardableResult func u8(_ v: UInt8) -> Self { data.append(v); return self }
    @discardableResult func u16(_ v: UInt16) -> Self {
        data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)); return self
    }
    @discardableResult func i16(_ v: Int16) -> Self { u16(UInt16(bitPattern: v)) }
    @discardableResult func u32(_ v: UInt32) -> Self {
        for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
        return self
    }
    @discardableResult func i32(_ v: Int32) -> Self { u32(UInt32(bitPattern: v)) }
    @discardableResult func f32(_ v: Float) -> Self { u32(v.bitPattern) }
    @discardableResult func bytes(_ d: Data) -> Self { data.append(d); return self }
}

/// COLORREF 0x00BBGGRR.
func colorref(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16
}

/// A packed DIB (BITMAPINFOHEADER + pixels, no palette) for 24/32-bit BI_RGB. `rows` are given top first
/// as (r, g, b) per pixel; `bottomUp` stores them bottom row first with a positive height.
func packedDIB(bpp: Int, rows: [[(UInt8, UInt8, UInt8)]], bottomUp: Bool = true) -> (header: Data, bits: Data) {
    let h = rows.count, w = rows.first?.count ?? 0
    let hdr = LEBytes()
    hdr.u32(40).i32(Int32(w)).i32(Int32(bottomUp ? h : -h)).u16(1).u16(UInt16(bpp)).u32(0).u32(0)
        .i32(0).i32(0).u32(0).u32(0)
    let stride = ((w * bpp + 31) / 32) * 4
    var bits = Data()
    for row in (bottomUp ? rows.reversed() : rows) {
        var line = Data()
        for (r, g, b) in row {
            line.append(contentsOf: [b, g, r])
            if bpp == 32 { line.append(0) }
        }
        while line.count < stride { line.append(0) }
        bits.append(line)
    }
    return (hdr.data, bits)
}

/// Builds EMF files record by record. Defaults: reference device 1000 × 1000 px on 100 × 100 mm (10 px/mm)
/// and a frame of 0…1000 (0.01 mm) = 10 mm = device pixels 0…100, so device units map 1:1 onto a
/// 100 × 100 target rect.
struct EMFBuilder {
    var frame: (Int32, Int32, Int32, Int32) = (0, 0, 1000, 1000)
    var device: (Int32, Int32) = (1000, 1000)
    var millimeters: (Int32, Int32) = (100, 100)
    var records: [Data] = []
    var addEOF = true
    var description: String?

    mutating func rec(_ type: UInt32, _ payload: (LEBytes) -> Void = { _ in }) {
        let p = LEBytes()
        payload(p)
        let r = LEBytes()
        r.u32(type).u32(UInt32(8 + p.data.count)).bytes(p.data)
        records.append(r.data)
    }

    /// A record whose size field is `size` regardless of its payload.
    mutating func rawRecord(type: UInt32, size: UInt32, payload: Data = Data()) {
        let r = LEBytes()
        r.u32(type).u32(size).bytes(payload)
        records.append(r.data)
    }

    func build() -> Data {
        var body = Data()
        for r in records { body.append(r) }
        if addEOF {
            let e = LEBytes()
            e.u32(14).u32(20).u32(0).u32(16).u32(20)
            body.append(e.data)
        }
        // Header: 108 bytes with szlMicrometers, or (with a description) 88 fixed bytes followed by the
        // UTF-16 description, as Adobe writers do — the extension fields are then absent.
        var desc = Data()
        if let d = description {
            let t = LEBytes()
            for u in d.utf16 { t.u16(u) }
            t.u16(0)
            while t.data.count % 4 != 0 { t.u8(0) }
            desc = t.data
        }
        let headerSize = description == nil ? 108 : 88 + desc.count
        let h = LEBytes()
        h.u32(1).u32(UInt32(headerSize))
        h.i32(0).i32(0).i32(99).i32(99)                                  // bounds (device px)
        h.i32(frame.0).i32(frame.1).i32(frame.2).i32(frame.3)            // frame (0.01 mm)
        h.u32(0x464D_4520).u32(0x10000).u32(UInt32(headerSize + body.count)).u32(UInt32(records.count + 2))
        h.u16(16).u16(0)
        h.u32(description.map { UInt32($0.utf16.count + 1) } ?? 0).u32(description == nil ? 0 : 88).u32(0)
        h.i32(device.0).i32(device.1).i32(millimeters.0).i32(millimeters.1)
        if description == nil {
            h.u32(0).u32(0).u32(0)
            h.i32(millimeters.0 * 1000).i32(millimeters.1 * 1000)
        } else {
            h.bytes(desc)
        }
        var out = h.data
        out.append(body)
        return out
    }

    // MARK: records

    mutating func points16(_ type: UInt32, _ pts: [(Int16, Int16)]) {
        rec(type) { p in
            p.i32(0).i32(0).i32(-1).i32(-1).u32(UInt32(pts.count))
            for (x, y) in pts { p.i16(x).i16(y) }
        }
    }
    mutating func polygon16(_ pts: [(Int16, Int16)]) { points16(86, pts) }
    mutating func polyline16(_ pts: [(Int16, Int16)]) { points16(87, pts) }
    mutating func polyBezierTo16(_ pts: [(Int16, Int16)]) { points16(88, pts) }
    mutating func polylineTo16(_ pts: [(Int16, Int16)]) { points16(89, pts) }

    mutating func moveTo(_ x: Int32, _ y: Int32) { rec(27) { $0.i32(x).i32(y) } }
    mutating func lineTo(_ x: Int32, _ y: Int32) { rec(54) { $0.i32(x).i32(y) } }
    mutating func rectangle(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        rec(43) { $0.i32(l).i32(t).i32(r).i32(b) }
    }
    mutating func ellipse(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        rec(42) { $0.i32(l).i32(t).i32(r).i32(b) }
    }
    mutating func brush(_ ih: UInt32, style: UInt32 = 0, color: UInt32) {
        rec(39) { $0.u32(ih).u32(style).u32(color).u32(0) }
    }
    mutating func pen(_ ih: UInt32, style: UInt32 = 0, width: Int32 = 1, color: UInt32) {
        rec(38) { $0.u32(ih).u32(style).i32(width).i32(0).u32(color) }
    }
    mutating func extPen(_ ih: UInt32, style: UInt32, width: UInt32, color: UInt32) {
        rec(95) { $0.u32(ih).u32(0).u32(0).u32(0).u32(0).u32(style).u32(width).u32(0).u32(color).u32(0).u32(0) }
    }
    mutating func select(_ ih: UInt32) { rec(37) { $0.u32(ih) } }
    mutating func delete(_ ih: UInt32) { rec(40) { $0.u32(ih) } }
    mutating func saveDC() { rec(33) }
    mutating func restoreDC(_ n: Int32) { rec(34) { $0.i32(n) } }
    mutating func mapMode(_ m: UInt32) { rec(17) { $0.u32(m) } }
    mutating func windowExt(_ x: Int32, _ y: Int32) { rec(9) { $0.i32(x).i32(y) } }
    mutating func windowOrg(_ x: Int32, _ y: Int32) { rec(10) { $0.i32(x).i32(y) } }
    mutating func viewportExt(_ x: Int32, _ y: Int32) { rec(11) { $0.i32(x).i32(y) } }
    mutating func viewportOrg(_ x: Int32, _ y: Int32) { rec(12) { $0.i32(x).i32(y) } }
    mutating func worldTransform(_ t: CGAffineTransform) {
        rec(35) { $0.f32(Float(t.a)).f32(Float(t.b)).f32(Float(t.c)).f32(Float(t.d)).f32(Float(t.tx)).f32(Float(t.ty)) }
    }
    mutating func beginPath() { rec(59) }
    mutating func endPath() { rec(60) }
    mutating func closeFigure() { rec(61) }
    mutating func fillPath() { rec(62) { $0.i32(0).i32(0).i32(-1).i32(-1) } }
    mutating func strokePath() { rec(64) { $0.i32(0).i32(0).i32(-1).i32(-1) } }
    mutating func selectClipPath(_ mode: UInt32) { rec(67) { $0.u32(mode) } }
    mutating func intersectClipRect(_ l: Int32, _ t: Int32, _ r: Int32, _ b: Int32) {
        rec(30) { $0.i32(l).i32(t).i32(r).i32(b) }
    }
    mutating func textColor(_ c: UInt32) { rec(24) { $0.u32(c) } }
    mutating func bkMode(_ m: UInt32) { rec(18) { $0.u32(m) } }
    mutating func textAlign(_ a: UInt32) { rec(22) { $0.u32(a) } }

    mutating func font(_ ih: UInt32, height: Int32, weight: Int32 = 400, face: String = "Helvetica",
                       escapement: Int32 = 0, charset: UInt8 = 0) {
        rec(82) { p in
            p.u32(ih).i32(height).i32(0).i32(escapement).i32(escapement).i32(weight)
            p.u8(0).u8(0).u8(0).u8(charset).u8(0).u8(0).u8(0).u8(0)
            var units = Array(face.utf16.prefix(31))
            while units.count < 32 { units.append(0) }
            for u in units { p.u16(u) }
        }
    }

    /// EXTTEXTOUTW with a reference point, no clip rect, optional dx array.
    mutating func textOut(_ x: Int32, _ y: Int32, _ s: String, dx: [Int32]? = nil, options: UInt32 = 0) {
        let units = Array(s.utf16)
        rec(84) { p in
            p.i32(0).i32(0).i32(-1).i32(-1).u32(1).f32(1).f32(1)        // bounds, GM_COMPATIBLE, scales
            let strOff: UInt32 = 8 + 28 + 40
            let strBytes = (units.count * 2 + 3) / 4 * 4
            p.i32(x).i32(y).u32(UInt32(units.count)).u32(strOff).u32(options)
            p.i32(0).i32(0).i32(0).i32(0).u32(dx == nil ? 0 : strOff + UInt32(strBytes))
            let str = LEBytes()
            for u in units { str.u16(u) }
            while str.data.count < strBytes { str.u8(0) }
            p.bytes(str.data)
            for d in dx ?? [] { p.i32(d) }
        }
    }

    /// STRETCHDIBITS of a packed DIB into the logical dest rect, SRCCOPY.
    mutating func stretchDIBits(dest: (Int32, Int32, Int32, Int32), dib: (header: Data, bits: Data),
                                width: Int32, height: Int32, rop: UInt32 = 0x00CC_0020) {
        rec(81) { p in
            let offBmi: UInt32 = 8 + 72
            p.i32(0).i32(0).i32(-1).i32(-1)
            p.i32(dest.0).i32(dest.1).i32(0).i32(0).i32(width).i32(height)
            p.u32(offBmi).u32(UInt32(dib.header.count)).u32(offBmi + UInt32(dib.header.count)).u32(UInt32(dib.bits.count))
            p.u32(0).u32(rop).i32(dest.2).i32(dest.3)
            p.bytes(dib.header).bytes(dib.bits)
        }
    }

    /// EMF+ comment ("EMF+" identifier) with arbitrary payload.
    mutating func emfPlusComment() {
        rec(70) { $0.u32(8).u32(0x2B46_4D45).u32(0x4001).u32(0) }
    }

    /// EMR_COMMENT_MULTIFORMATS ("GDIC", 0x40000004) with one PDF format drawn into `output` (device units),
    /// laid out like the Office/Adobe files: format data offset relative to the comment data.
    mutating func embeddedPDF(_ pdf: Data, output: (Int32, Int32, Int32, Int32)) {
        rec(70) { p in
            let cbData = 4 + 4 + 16 + 4 + 16 + pdf.count
            p.u32(UInt32(cbData)).u32(0x4349_4447).u32(0x4000_0004)
            p.i32(output.0).i32(output.1).i32(output.2).i32(output.3)
            p.u32(1).u32(0x5044_4620).u32(1).u32(UInt32(pdf.count)).u32(44)
            p.bytes(pdf)
            while p.data.count % 4 != 0 { p.u8(0) }
        }
    }
}

/// A one-page PDF (100 × 100 pt) whose left half is filled with `color`.
func leftHalfPDF(_ color: CGColor) -> Data {
    let out = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    guard let consumer = CGDataConsumer(data: out as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
    ctx.endPDFPage()
    ctx.closePDF()
    return out as Data
}

/// BI_BITFIELDS 32-bit DIB of one pixel with value `pixel` and the given red/green/blue masks
/// (BITMAPINFOHEADER followed by the three masks).
func bitfieldsDIB(pixel: UInt32, masks: (UInt32, UInt32, UInt32)) -> (header: Data, bits: Data) {
    let h = LEBytes()
    h.u32(40).i32(1).i32(1).u16(1).u16(32).u32(3).u32(4).i32(0).i32(0).u32(0).u32(0)
    h.u32(masks.0).u32(masks.1).u32(masks.2)
    let b = LEBytes()
    b.u32(pixel)
    return (h.data, b.data)
}

/// Builds a placeable WMF (bbox 0…1000 logical units, 1000 units per inch by default).
struct WMFBuilder {
    var bbox: (Int16, Int16, Int16, Int16) = (0, 0, 1000, 1000)
    var inch: UInt16 = 1000
    var placeable = true
    var records: [Data] = []

    mutating func rec(_ fn: UInt16, _ params: (LEBytes) -> Void = { _ in }) {
        let p = LEBytes()
        params(p)
        if p.data.count % 2 == 1 { p.u8(0) }
        let r = LEBytes()
        r.u32(UInt32(3 + p.data.count / 2)).u16(fn).bytes(p.data)
        records.append(r.data)
    }

    func build() -> Data {
        var body = Data()
        for r in records { body.append(r) }
        body.append(contentsOf: [3, 0, 0, 0, 0, 0])   // EOF
        let out = LEBytes()
        if placeable {
            let h = LEBytes()
            h.u32(0x9AC6_CDD7).u16(0).i16(bbox.0).i16(bbox.1).i16(bbox.2).i16(bbox.3).u16(inch).u32(0)
            var sum: UInt16 = 0
            for i in stride(from: 0, to: 20, by: 2) { sum ^= UInt16(h.data[i]) | UInt16(h.data[i + 1]) << 8 }
            h.u16(sum)
            out.bytes(h.data)
        }
        out.u16(1).u16(9).u16(0x300).u32(UInt32(9 + body.count / 2)).u16(8).u32(0).u16(0)
        out.bytes(body)
        return out.data
    }

    mutating func windowOrg(_ x: Int16, _ y: Int16) { rec(0x20B) { $0.i16(y).i16(x) } }
    mutating func windowExt(_ x: Int16, _ y: Int16) { rec(0x20C) { $0.i16(y).i16(x) } }
    mutating func brush(color: UInt32, style: UInt16 = 0) { rec(0x2FC) { $0.u16(style).u32(color).u16(0) } }
    mutating func pen(style: UInt16 = 0, width: Int16 = 1, color: UInt32) {
        rec(0x2FA) { $0.u16(style).i16(width).i16(0).u32(color) }
    }
    mutating func select(_ i: UInt16) { rec(0x12D) { $0.u16(i) } }
    mutating func delete(_ i: UInt16) { rec(0x1F0) { $0.u16(i) } }
    mutating func polygon(_ pts: [(Int16, Int16)]) {
        rec(0x324) { p in p.i16(Int16(pts.count)); for (x, y) in pts { p.i16(x).i16(y) } }
    }
    mutating func rectangle(_ l: Int16, _ t: Int16, _ r: Int16, _ b: Int16) {
        rec(0x41B) { $0.i16(b).i16(r).i16(t).i16(l) }
    }
}

/// gzip container around raw-deflated `data` (for EMZ/WMZ tests).
func gzip(_ data: Data) -> Data {
    let cap = data.count + 1024
    var dst = [UInt8](repeating: 0, count: cap)
    let n = data.withUnsafeBytes { src in
        compression_encode_buffer(&dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
                                  COMPRESSION_ZLIB)
    }
    let out = LEBytes()
    out.u8(0x1F).u8(0x8B).u8(8).u8(0).u32(0).u8(0).u8(3)
    out.bytes(Data(dst.prefix(n)))
    out.u32(OOXMLBuilder.crc32(data)).u32(UInt32(data.count))
    return out.data
}

/// Renders an EMF into the left 100 × 100 square of a fresh Canvas.
func render(_ emf: EMFBuilder) throws -> Canvas {
    let doc = try EMFDocument(data: emf.build())
    let c = Canvas()
    doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
    return c
}

/// True if any pixel in the region is not transparent.
func hasInk(_ c: Canvas, _ r: CGRect) -> Bool {
    for y in Int(r.minY)..<Int(r.maxY) {
        for x in Int(r.minX)..<Int(r.maxX) where !c.isClear(x, y) { return true }
    }
    return false
}
