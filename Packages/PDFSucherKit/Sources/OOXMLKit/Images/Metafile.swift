// Metafile.swift — Task 13 (OOXMLKit)
// Shared pieces of the EMF/WMF players: the public `Metafile` wrapper, format detection (incl. gzip'd
// EMZ/WMZ), the device-independent record list both parsers produce, and a bounds-checked byte reader.
// Playback lives in MetafileRenderer.swift, DIB decoding in MetafileDIB.swift.
import Compression
import CoreGraphics
import Foundation

public enum MetafileError: Error, Equatable {
    /// Not an EMF/WMF (wrong record type, signature or header size).
    case invalidHeader
    /// The data ends inside the header.
    case truncated
}

/// A parsed vector image (EMF or WMF). Immutable; `draw` replays the records.
public enum Metafile: Sendable {
    case emf(EMFDocument)
    case wmf(WMFDocument)

    /// Frame in 0.01 mm (EMF `rclFrame`; WMF placeable bbox or window, see WMFDocument).
    public var bounds: CGRect {
        switch self {
        case .emf(let d): return d.bounds
        case .wmf(let d): return d.bounds
        }
    }

    /// Maps the metafile's frame onto `rect` in the caller's y-down CTM (clipped to `rect`).
    public func draw(in ctx: CGContext, rect: CGRect) {
        switch self {
        case .emf(let d): d.draw(in: ctx, rect: rect)
        case .wmf(let d): d.draw(in: ctx, rect: rect)
        }
    }

    /// Rough memory cost for the image cache.
    var cost: Int {
        switch self {
        case .emf(let d): return d.program.cost
        case .wmf(let d): return d.program.cost
        }
    }

    /// EMF (record type 1 with " EMF" at offset 40), WMF (placeable key or a standard header) or either of
    /// them gzip-compressed (EMZ/WMZ). nil for anything else or an unparsable header.
    static func decode(_ data: Data) -> Metafile? {
        if isGzip(data) {
            guard let inner = gunzip(data), !isGzip(inner) else { return nil }
            return decode(inner)
        }
        if EMFDocument.looksLikeEMF(data) { return (try? EMFDocument(data: data)).map(Metafile.emf) }
        if WMFDocument.looksLikeWMF(data) { return (try? WMFDocument(data: data)).map(Metafile.wmf) }
        return nil
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Largest inflated EMZ/WMZ accepted (bounds memory; decompression bombs stop here).
    static let maxInflatedSize = 64 * 1024 * 1024

    /// Output buffer for inflating `compressed` bytes whose gzip trailer claims `isize`: never more than
    /// deflate's maximum ratio allows (×1100 + 1 KB, as ZipArchive) nor `maxInflatedSize`, so a forged
    /// ISIZE cannot make a tiny file allocate much.
    static func inflateCapacity(compressed: Int, isize: Int) -> Int {
        min(max(isize, 64), compressed * 1100 + 1024, maxInflatedSize)
    }

    /// gzip (RFC 1952, deflate, one member): header fields skipped, raw deflate inflated with the
    /// Compression framework into a buffer sized by `inflateCapacity` (output beyond it is truncated).
    static func gunzip(_ data: Data) -> Data? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= 18, let base = b.baseAddress, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
            let flags = b[3]
            var p = 10
            if flags & 0x04 != 0 {                       // FEXTRA
                guard p + 2 <= b.count else { return nil }
                p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
            }
            for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT (zero-terminated)
                while p < b.count, b[p] != 0 { p += 1 }
                p += 1
            }
            if flags & 0x02 != 0 { p += 2 }              // FHCRC
            let end = b.count - 8
            guard p < end else { return nil }
            let isize = Int(b[end + 4]) | Int(b[end + 5]) << 8 | Int(b[end + 6]) << 16 | Int(b[end + 7]) << 24
            let capacity = inflateCapacity(compressed: end - p, isize: isize)
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, base + p, end - p, nil, COMPRESSION_ZLIB)
            }
            guard n > 0 else { return nil }
            out.count = n
            return out
        }
    }
}

// MARK: - Record list (shared by EMF and WMF)

/// A GDI pen. `width` in logical units (0 = cosmetic, one device pixel).
struct GDIPen: Sendable {
    var style: UInt32 = 0          // PS_* incl. end cap / join / type bits
    var width: Double = 0
    var color: RGBA? = RGBA(r: 0, g: 0, b: 0)   // nil = PS_NULL or BS_NULL
    var dashes: [Double] = []      // PS_USERSTYLE entries (logical units)
    var cosmetic: Bool { style & 0xF_0000 == 0 || width == 0 }
    var kind: UInt32 { style & 0xF }
}

/// A GDI brush. Pattern brushes are approximated by their average color; `darkFraction` is the share of
/// dark pixels (used by the PATINVERT mask idiom, see MetafileRenderer).
struct GDIBrush: Sendable {
    enum Kind: Sendable { case solid, null, hatched, pattern }
    var kind: Kind
    var color: RGBA
    var darkFraction: Double = 1
}

struct GDIFont: Sendable {
    var height: Double = 0         // logical; < 0 = character height, > 0 = cell height, 0 = default
    var escapement: Double = 0     // tenths of a degree, counter-clockwise
    var weight: Int = 400
    var italic = false
    var charset: UInt8 = 0
    var face = ""
}

enum GDIObject: Sendable {
    case pen(GDIPen)
    case brush(GDIBrush)
    case font(GDIFont)
    case other                     // palette, region, … (takes a WMF slot, selecting it does nothing)
}

struct GDIText: Sendable {
    var reference: CGPoint
    var text: [UInt16]             // UTF-16 (WMF/ANSI text is decoded at parse time)
    var options: UInt32 = 0        // ETO_*
    var rect: CGRect?              // logical; for ETO_OPAQUE / ETO_CLIPPED
    var dx: [Double]?              // per UTF-16 unit, logical
}

struct GDIBitmap: Sendable {
    var dest: CGRect               // logical; width/height may be negative (mirrored)
    var image: CGImage             // already cropped to the source rect, top row first
    var rop: UInt32
    /// 1-bit bitmaps: luminance as a clip mask (white = paint), cropped like `image`.
    var mask: CGImage?
    /// AlphaBlend: constant alpha 0…1 and whether the per-pixel alpha is used.
    var blend: (constant: Double, perPixel: Bool)?
}

enum PolyKind: Sendable { case polygon, polyline, polyBezier, polyBezierTo, polylineTo, polyPolygon, polyPolyline }

/// One drawing instruction, device independent. Coordinates are logical (page) units except where noted.
enum GDIRecord: Sendable {
    case setMapMode(UInt32)
    case setWindowOrg(CGPoint), setWindowExt(CGSize), setViewportOrg(CGPoint), setViewportExt(CGSize)
    case offsetWindowOrg(CGPoint), offsetViewportOrg(CGPoint)
    case scaleWindowExt(Double, Double, Double, Double)    // xNum, xDenom, yNum, yDenom
    case scaleViewportExt(Double, Double, Double, Double)
    case setWorldTransform(CGAffineTransform)
    case modifyWorldTransform(CGAffineTransform, UInt32)
    case saveDC, restoreDC(Int32)
    case createObject(UInt32, GDIObject), selectObject(UInt32), deleteObject(UInt32)
    case setPolyFillMode(UInt32), setBkMode(UInt32), setTextAlign(UInt32), setROP2(UInt32)
    case setTextColor(RGBA), setBkColor(RGBA), setMiterLimit(Double)
    case moveTo(CGPoint), lineTo(CGPoint)
    case poly(PolyKind, [CGPoint], counts: [Int])
    case rectangle(CGRect), ellipse(CGRect), roundRect(CGRect, CGSize)
    case beginPath, endPath, closeFigure, abortPath, fillPath, strokePath, strokeAndFillPath
    case selectClipPath(UInt32)
    case intersectClipRect(CGRect), excludeClipRect(CGRect)
    case selectClipRegion(UInt32, [CGRect])                 // RGN_* mode, rects in DEVICE units
    case setMetaRgn
    case text(GDIText)
    case bitmap(GDIBitmap)
    case patBlt(CGRect, UInt32)                             // raster op without a source bitmap
    /// PDF embedded in an EMR_COMMENT_MULTIFORMATS comment: page 1 drawn into the rect (DEVICE units).
    case embeddedPDF(CGRect, Data)
}

/// The parsed, immutable record list plus what playback needs to place it.
struct GDIProgram: Sendable {
    var records: [GDIRecord] = []
    /// Number of records read from the file (including skipped ones).
    var recordCount = 0
    /// Record types that are not understood (type → count). Deliberately ignored types are not listed.
    var unknownRecordTypes: [UInt32: Int] = [:]
    var cost = 0
    /// Pixels the remaining bitmaps may still decode (DIBDecoder.documentPixelBudget at start).
    var pixelBudget = DIBDecoder.documentPixelBudget

    /// Records read per file at most; parsing stops there (bounds the record list on hostile input).
    static let maxRecords = 2_000_000

    /// Whether any record paints: shapes outside a path bracket, path fills/strokes, text, bitmaps, …
    /// (geometry inside BEGINPATH … ENDPATH only builds a path, e.g. a clip path).
    var hasDrawing: Bool {
        var bracket = false
        for r in records {
            switch r {
            case .beginPath: bracket = true
            case .endPath, .abortPath: bracket = false
            case .poly, .rectangle, .ellipse, .roundRect, .lineTo: if !bracket { return true }
            case .fillPath, .strokePath, .strokeAndFillPath, .text, .bitmap, .patBlt, .embeddedPDF: return true
            default: break
            }
        }
        return false
    }

    mutating func unknown(_ type: UInt32) { unknownRecordTypes[type, default: 0] += 1 }
}

// MARK: - helpers

/// COLORREF 0x00BBGGRR.
func gdiColor(_ v: UInt32) -> RGBA {
    RGBA(r: Double(v & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double((v >> 16) & 0xFF) / 255)
}

/// Bounds-checked little-endian reads over a byte array; out-of-range reads return 0 (callers check sizes
/// first, this only guarantees that nothing traps on bad input).
struct ByteReader {
    let b: [UInt8]

    func u8(_ o: Int) -> UInt8 { o >= 0 && o < b.count ? b[o] : 0 }
    func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }
    func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
    func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
    func f32(_ o: Int) -> Double { Double(Float(bitPattern: u32(o))) }
    /// `count` bytes from `o` if they are all inside `limit` (and the data).
    func range(_ o: Int, _ count: Int, within limit: Range<Int>) -> Range<Int>? {
        guard count >= 0, o >= limit.lowerBound, o <= limit.upperBound, count <= limit.upperBound - o,
              o + count <= b.count else { return nil }
        return o..<(o + count)
    }
}

/// ANSI text (WMF, EMR_EXTTEXTOUTA) → UTF-16. Symbol charset keeps the byte values (FontResolver maps
/// them); everything else is read as Windows-1252, falling back to Latin-1.
func decodeANSI(_ bytes: ArraySlice<UInt8>, charset: UInt8) -> [UInt16] {
    if charset != 2, let s = String(bytes: bytes, encoding: .windowsCP1252) { return Array(s.utf16) }
    return bytes.map { UInt16($0) }
}
