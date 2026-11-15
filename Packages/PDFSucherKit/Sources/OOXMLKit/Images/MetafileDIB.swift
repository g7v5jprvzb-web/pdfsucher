// MetafileDIB.swift — Task 13 (OOXMLKit)
// Device-independent bitmaps as embedded in EMF/WMF records: BITMAPCOREHEADER / BITMAPINFOHEADER (and the
// V4/V5 extensions), BI_RGB 1/4/8/16/24/32 bit with palette, BI_BITFIELDS 16/32, BI_JPEG/BI_PNG via ImageIO,
// bottom-up and top-down. RLE compression is not supported (→ nil).
import CoreGraphics
import Foundation
import ImageIO

struct DecodedDIB {
    var image: CGImage
    var width: Int
    var height: Int
    var bitCount: Int
    /// The DIB stores its bottom row first (source rectangles of StretchDIBits count from the bottom then).
    var bottomUp: Bool
    /// Premultiplied RGBA, top row first (nil for JPEG/PNG payloads).
    var pixels: [UInt8]?
}

enum DIBDecoder {
    /// Largest bitmap decoded (pixels); larger ones are skipped.
    static let maxPixels = 40_000_000
    /// Pixels decoded per metafile in total (bounds memory on hostile input; later bitmaps are skipped).
    static let documentPixelBudget = 100_000_000

    /// Splits a packed DIB (header, masks, palette, then pixels — WMF and pattern brushes) into the
    /// BITMAPINFO range and the pixel range.
    static func packed(_ r: ByteReader, _ range: Range<Int>) -> (info: Range<Int>, bits: Range<Int>)? {
        let o = range.lowerBound
        guard range.count >= 12 else { return nil }
        let hs = Int(r.u32(o))
        let bpp: Int, comp: UInt32, clrUsed: Int
        if hs == 12 {
            bpp = Int(r.u16(o + 10)); comp = 0; clrUsed = 0
        } else {
            guard hs >= 40, hs <= range.count else { return nil }
            bpp = Int(r.u16(o + 14)); comp = r.u32(o + 16); clrUsed = Int(r.u32(o + 32))
        }
        var infoSize = hs
        if hs == 40, comp == 3 { infoSize += 12 }
        if hs == 40, comp == 6 { infoSize += 16 }
        if bpp <= 8 {
            let n = clrUsed > 0 ? min(clrUsed, 1 << max(bpp, 1)) : 1 << max(bpp, 1)
            infoSize += n * (hs == 12 ? 3 : 4)
        } else if clrUsed > 0, clrUsed <= 256 {
            infoSize += clrUsed * 4
        }
        guard infoSize <= range.count else { return nil }
        return (o..<(o + infoSize), (o + infoSize)..<range.upperBound)
    }

    /// Decodes the bitmap described by `info` (BITMAPINFO) with pixels in `bits`.
    /// `usage` 1 = DIB_PAL_COLORS (palette indices into a logical palette we do not track → gray ramp).
    /// `alpha`: use the fourth byte of 32-bit BI_RGB pixels as (premultiplied) alpha; otherwise opaque.
    /// `budget`: pixels the document may still decode; the bitmap's pixels are subtracted. Uncompressed
    /// pixel data must be complete (stride × height bytes), so the allocation is proportional to the input.
    static func decode(_ r: ByteReader, info: Range<Int>, bits: Range<Int>, usage: UInt32 = 0,
                       alpha: Bool = false, budget: inout Int) -> DecodedDIB? {
        let o = info.lowerBound
        guard info.count >= 12 else { return nil }
        let hs = Int(r.u32(o))
        var w: Int, h: Int, bpp: Int, comp: UInt32 = 0, clrUsed = 0
        if hs == 12 {
            w = Int(r.u16(o + 4)); h = Int(r.i16(o + 6)); bpp = Int(r.u16(o + 10))
        } else {
            guard hs >= 40, hs <= info.count else { return nil }
            w = Int(r.i32(o + 4)); h = Int(r.i32(o + 8)); bpp = Int(r.u16(o + 14))
            comp = r.u32(o + 16); clrUsed = Int(r.u32(o + 32))
        }
        let bottomUp = h > 0
        h = abs(h)
        guard w > 0, h > 0, w <= 65535, h <= 65535, w * h <= maxPixels, w * h <= budget else { return nil }

        if comp == 4 || comp == 5 {   // BI_JPEG / BI_PNG
            let payload = Data(r.b[bits])
            guard let img = ImageDecoder.decodeBitmap(payload), img.width * img.height <= budget else { return nil }
            budget -= img.width * img.height
            return DecodedDIB(image: img, width: img.width, height: img.height, bitCount: 24, bottomUp: false,
                              pixels: nil)
        }
        guard [1, 4, 8, 16, 24, 32].contains(bpp), comp == 0 || comp == 3 || comp == 6 else { return nil }

        // Channel masks (16/32 bit).
        var masks: [UInt32] = bpp == 16 ? [0x7C00, 0x03E0, 0x001F, 0] : [0xFF_0000, 0xFF00, 0xFF, 0]
        if comp == 3 || comp == 6 {
            let at = hs >= 52 ? o + 40 : o + hs
            for i in 0..<(comp == 6 || hs >= 56 ? 4 : 3) where at + 4 * i + 4 <= info.upperBound {
                masks[i] = r.u32(at + 4 * i)
            }
        }
        // Palette.
        var palette: [(UInt8, UInt8, UInt8)] = []
        if bpp <= 8 {
            let n = clrUsed > 0 ? min(clrUsed, 1 << bpp) : 1 << bpp
            let entry = hs == 12 ? 3 : 4
            let start = o + hs
            for i in 0..<n {
                if usage == 1 {
                    let v = UInt8(truncatingIfNeeded: i * 255 / max(n - 1, 1))
                    palette.append((v, v, v))
                } else if start + i * entry + 3 <= info.upperBound {
                    let p = start + i * entry
                    palette.append((r.u8(p + 2), r.u8(p + 1), r.u8(p)))
                } else {
                    palette.append((0, 0, 0))
                }
            }
            // Some writers omit the 1-bit palette: black/white.
            if bpp == 1, palette.count == 2, start + 8 > info.upperBound { palette = [(0, 0, 0), (255, 255, 255)] }
        }

        let stride = ((w * bpp + 31) / 32) * 4
        guard bits.count >= stride * h else { return nil }
        let rows = h
        budget -= w * h
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let useAlpha = alpha && bpp == 32 && comp == 0
        // Palette as flat RGB triples, padded to 256 entries (out-of-range indices → black).
        var pal = [UInt8](repeating: 0, count: 256 * 3)
        for (i, c) in palette.prefix(256).enumerated() { pal[3 * i] = c.0; pal[3 * i + 1] = c.1; pal[3 * i + 2] = c.2 }
        let shifts = masks.map { m -> (shift: UInt32, max: UInt32) in
            guard m != 0 else { return (0, 0) }
            let s = m.trailingZeroBitCount
            return (UInt32(s), m >> UInt32(s))
        }
        let bitfields = bpp == 16 || comp != 0
        r.b.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rows {
                    let s0 = bits.lowerBound + row * stride
                    var d = (bottomUp ? h - 1 - row : row) * w * 4
                    switch bpp {
                    case 1, 4, 8:
                        let mask = UInt8((1 << bpp) - 1)
                        for x in 0..<w {
                            let bit = x * bpp
                            let idx = Int((src[s0 + bit >> 3] >> UInt8(8 - bpp - bit & 7)) & mask) * 3
                            dst[d] = pal[idx]; dst[d + 1] = pal[idx + 1]; dst[d + 2] = pal[idx + 2]; dst[d + 3] = 255
                            d += 4
                        }
                    case 24:
                        var p = s0
                        for _ in 0..<w {
                            dst[d] = src[p + 2]; dst[d + 1] = src[p + 1]; dst[d + 2] = src[p]; dst[d + 3] = 255
                            p += 3; d += 4
                        }
                    case 32 where !bitfields:
                        var p = s0
                        for _ in 0..<w {
                            let a: UInt8 = useAlpha ? src[p + 3] : 255
                            dst[d] = min(src[p + 2], a); dst[d + 1] = min(src[p + 1], a); dst[d + 2] = min(src[p], a)
                            dst[d + 3] = a
                            p += 4; d += 4
                        }
                    default:   // 16-bit, or 32-bit BI_BITFIELDS
                        let size = bpp / 8
                        var p = s0
                        for _ in 0..<w {
                            var v = UInt32(src[p]) | UInt32(src[p + 1]) << 8
                            if size == 4 { v |= UInt32(src[p + 2]) << 16 | UInt32(src[p + 3]) << 24 }
                            for c in 0..<3 {
                                // UInt64: a full-width mask (max 2^32 − 1) × 255 overflows UInt32.
                                let (sh, mx) = shifts[c]
                                dst[d + c] = mx > 0 ? UInt8(UInt64((v >> sh) & mx) * 255 / UInt64(mx)) : 0
                            }
                            dst[d + 3] = 255
                            p += size; d += 4
                        }
                    }
                }
            }
        }
        guard let img = makeImage(out, width: w, height: h) else { return nil }
        return DecodedDIB(image: img, width: w, height: h, bitCount: bpp, bottomUp: bottomUp, pixels: out)
    }

    static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A DeviceGray image of the pixels' luminance (white = 1), used as a clip mask.
    static func luminanceMask(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            gray[i] = UInt8((Int(rgba[4 * i]) + Int(rgba[4 * i + 1]) + Int(rgba[4 * i + 2])) / 3)
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Average color and share of dark pixels (luminance < 50 %) — pattern brushes are drawn as solid fills.
    static func brushStats(_ dib: DecodedDIB) -> (color: RGBA, dark: Double) {
        guard let px = dib.pixels, !px.isEmpty else { return (RGBA(r: 0.5, g: 0.5, b: 0.5), 0.5) }
        var r = 0.0, g = 0.0, b = 0.0, dark = 0.0
        let n = px.count / 4
        for i in 0..<n {
            let cr = Double(px[4 * i]), cg = Double(px[4 * i + 1]), cb = Double(px[4 * i + 2])
            r += cr; g += cg; b += cb
            if (cr + cg + cb) / 3 < 128 { dark += 1 }
        }
        let k = 255.0 * Double(n)
        return (RGBA(r: r / k, g: g / k, b: b / k), dark / Double(n))
    }

    /// A bitmap record's image and (for 1-bit DIBs) mask, both cropped to `src` (pixels, top-left origin).
    static func parts(_ dib: DecodedDIB, src: CGRect) -> (image: CGImage, mask: CGImage?) {
        var mask: CGImage?
        if dib.bitCount == 1, let px = dib.pixels, let m = luminanceMask(px, width: dib.width, height: dib.height) {
            mask = crop(m, src)
        }
        return (crop(dib.image, src), mask)
    }

    /// `img` cropped to `src` (pixels, top-left origin); the whole image when `src` covers it or is unusable.
    static func crop(_ img: CGImage, _ src: CGRect) -> CGImage {
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let s = src.standardized.intersection(full).integral
        guard !s.isNull, s.width >= 1, s.height >= 1, s != full else { return img }
        return img.cropping(to: s) ?? img
    }
}
