// EMFPlayer.swift — Task 13 (OOXMLKit)
// Parses an Enhanced Metafile (MS-EMF) into the shared GDI record list at init; `draw` replays it with
// MetafileRenderer. EMF+ records (in GDICOMMENT) are skipped: dual files play their EMF part, EMF+-only
// files draw nothing (`isEMFPlusOnly`). A record with size < 8, not a multiple of 4 or running past the
// end stops parsing (what was parsed is kept); unknown records are skipped.
import CoreGraphics
import Foundation

public struct EMFDocument: Sendable {
    /// `rclFrame` in 0.01 mm.
    public let bounds: CGRect
    /// The file has EMF+ records and its EMF part draws nothing (draw() then draws nothing).
    public let isEMFPlusOnly: Bool

    let program: GDIProgram
    /// The frame in device pixels of the reference device (what is mapped onto the target rect).
    let deviceFrame: CGRect
    /// Device pixels per millimetre of the reference device.
    let pixelsPerMM: CGSize

    /// Records read (incl. header and EOF) and record types not understood (type → count).
    var recordCount: Int { program.recordCount }
    var unknownRecordTypes: [UInt32: Int] { program.unknownRecordTypes }
    var hasDrawing: Bool { program.hasDrawing }

    static func looksLikeEMF(_ data: Data) -> Bool {
        guard data.count >= 88 else { return false }
        let r = ByteReader(b: [UInt8](data.prefix(44)))
        return r.u32(0) == 1 && r.u32(40) == 0x464D_4520
    }

    public init(data: Data) throws {
        try self.init(data: data, pixelBudget: DIBDecoder.documentPixelBudget, maxRecords: GDIProgram.maxRecords)
    }

    /// `pixelBudget`: bitmap pixels decoded at most; `maxRecords`: records read at most (tests lower them).
    init(data: Data, pixelBudget: Int = DIBDecoder.documentPixelBudget,
         maxRecords: Int = GDIProgram.maxRecords) throws {
        let r = ByteReader(b: [UInt8](data))
        guard r.b.count >= 88 else {
            throw r.b.count >= 4 && r.u32(0) == 1 ? MetafileError.truncated : MetafileError.invalidHeader
        }
        let headerSize = Int(r.u32(4))
        guard r.u32(0) == 1, r.u32(40) == 0x464D_4520, headerSize >= 88, headerSize % 4 == 0 else {
            throw MetafileError.invalidHeader
        }
        guard headerSize <= r.b.count else { throw MetafileError.truncated }
        func rect(_ o: Int) -> (Double, Double, Double, Double) {
            (Double(r.i32(o)), Double(r.i32(o + 4)), Double(r.i32(o + 8)), Double(r.i32(o + 12)))
        }
        let frame = rect(24), devBounds = rect(8)
        bounds = CGRect(x: frame.0, y: frame.1, width: frame.2 - frame.0, height: frame.3 - frame.1)

        // Pixels per mm: szlDevice / szlMillimeters, or szlMicrometers (header extension 2) when present.
        let devW = Double(r.i32(72)), devH = Double(r.i32(76))
        var mmW = Double(r.i32(80)), mmH = Double(r.i32(84))
        // The header extensions exist only below the description string (which may start at offset 88).
        let offDescription = Int(r.u32(64))
        let fixedEnd = r.u32(60) > 0 && offDescription >= 88 ? min(offDescription, headerSize) : headerSize
        if fixedEnd >= 108, r.i32(100) > 0, r.i32(104) > 0 {
            mmW = Double(r.i32(100)) / 1000; mmH = Double(r.i32(104)) / 1000
        }
        var ppmm = CGSize(width: devW / mmW, height: devH / mmH)
        if !(ppmm.width.isFinite && ppmm.width > 0 && ppmm.height.isFinite && ppmm.height > 0) {
            ppmm = CGSize(width: 96 / 25.4, height: 96 / 25.4)
        }
        pixelsPerMM = ppmm
        var dev = CGRect(x: frame.0 / 100 * ppmm.width, y: frame.1 / 100 * ppmm.height,
                         width: (frame.2 - frame.0) / 100 * ppmm.width, height: (frame.3 - frame.1) / 100 * ppmm.height)
        if !(dev.width > 0 && dev.height > 0 && dev.width.isFinite && dev.height.isFinite) {
            // Unusable frame: the inclusive device bounds.
            dev = CGRect(x: devBounds.0, y: devBounds.1, width: devBounds.2 - devBounds.0 + 1,
                         height: devBounds.3 - devBounds.1 + 1)
        }
        deviceFrame = dev

        var parser = EMFParser(r: r)
        parser.program.pixelBudget = pixelBudget
        parser.run(maxRecords: maxRecords, from: headerSize)
        program = parser.program
        isEMFPlusOnly = parser.emfPlusRecords > 0 && !parser.program.hasDrawing
    }

    /// Maps the frame onto `rect` (caller's y-down CTM), clipped to `rect`.
    public func draw(in ctx: CGContext, rect: CGRect) {
        let hairline = max(1, 0.1 * Double(pixelsPerMM.width))
        MetafileRenderer.play(program, in: ctx, rect: rect, deviceFrame: deviceFrame, pixelsPerMM: pixelsPerMM,
                              hairline: hairline, initial: .emf)
    }
}

/// Reads EMF records into a GDIProgram.
private struct EMFParser {
    let r: ByteReader
    var program = GDIProgram()
    var emfPlusRecords = 0
    /// First PDF found in an EMR_COMMENT_MULTIFORMATS comment (output rect in device units, PDF bytes).
    var embeddedPDF: (CGRect, Data)?

    /// Types that are understood but intentionally have no effect here.
    static let ignored: Set<UInt32> = [
        13, // SETBRUSHORGEX
        16, // SETMAPPERFLAGS
        21, // SETSTRETCHBLTMODE
        23, // SETCOLORADJUSTMENT
        48, 49, 50, 51, 52, // palettes
        57, // SETARCDIRECTION
        65, 66, // FLATTENPATH, WIDENPATH (curves are kept as curves)
        98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, // ICM / colour spaces / OpenGL / pixel format
        115, // SETLAYOUT
        119, 120, 121, 122, // SETLINKEDUFIS, SETTEXTJUSTIFICATION, colour matching
    ]

    init(r: ByteReader) { self.r = r }

    mutating func run(maxRecords: Int, from start: Int) {
        program.recordCount = 1
        var off = start
        while off + 8 <= r.b.count, program.recordCount < maxRecords {
            let type = r.u32(off), size = Int(r.u32(off + 4))
            guard size >= 8, size % 4 == 0, size <= r.b.count - off else { break }
            program.recordCount += 1
            if type == 14 { break }   // EOF
            record(type, off..<(off + size))
            off += size
        }
        // The embedded PDF stands in for the EMF records only when those draw nothing (Office/Adobe
        // write either a full EMF rendering next to it, or just a clip path); otherwise both would draw.
        if let pdf = embeddedPDF, !program.hasDrawing {
            add(.embeddedPDF(pdf.0, pdf.1))
            program.cost += pdf.1.count
        }
        program.cost = program.records.count * 64 + r.b.count
    }

    private mutating func add(_ rec: GDIRecord) { program.records.append(rec) }

    private func point(_ o: Int) -> CGPoint { CGPoint(x: Double(r.i32(o)), y: Double(r.i32(o + 4))) }
    private func size(_ o: Int) -> CGSize { CGSize(width: Double(r.i32(o)), height: Double(r.i32(o + 4))) }
    private func rect(_ o: Int) -> CGRect {
        let l = Double(r.i32(o)), t = Double(r.i32(o + 4)), rr = Double(r.i32(o + 8)), b = Double(r.i32(o + 12))
        return CGRect(x: l, y: t, width: rr - l, height: b - t)
    }
    private func xform(_ o: Int) -> CGAffineTransform {
        CGAffineTransform(a: r.f32(o), b: r.f32(o + 4), c: r.f32(o + 8), d: r.f32(o + 12), tx: r.f32(o + 16),
                          ty: r.f32(o + 20))
    }

    private mutating func record(_ type: UInt32, _ rec: Range<Int>) {
        let o = rec.lowerBound, n = rec.count
        func need(_ bytes: Int) -> Bool { n >= bytes }
        switch type {
        case 2, 3, 4, 5, 6, 85, 86, 87, 88, 89:        // POLY* (32-bit and 16-bit points)
            let small = type >= 85
            let kind: PolyKind
            switch small ? type - 83 : type {
            case 2: kind = .polyBezier
            case 3: kind = .polygon
            case 4: kind = .polyline
            case 5: kind = .polyBezierTo
            default: kind = .polylineTo
            }
            guard need(28) else { return }
            let count = Int(r.u32(o + 24))
            guard let pts = points(o + 28, count, small: small, in: rec) else { return }
            add(.poly(kind, pts, counts: [count]))
        case 7, 8, 90, 91:                             // POLYPOLYLINE / POLYPOLYGON (32/16)
            guard need(32) else { return }
            let small = type >= 90
            let nPolys = Int(r.u32(o + 24)), total = Int(r.u32(o + 28))
            guard nPolys >= 0, nPolys <= (n - 32) / 4 else { return }
            var counts: [Int] = []
            var sum = 0
            for i in 0..<nPolys {
                let c = Int(r.u32(o + 32 + 4 * i))
                counts.append(c); sum += c
                guard sum <= total else { return }
            }
            guard sum == total, let pts = points(o + 32 + 4 * nPolys, total, small: small, in: rec) else { return }
            add(.poly(type == 7 || type == 90 ? .polyPolyline : .polyPolygon, pts, counts: counts))
        case 9: if need(16) { add(.setWindowExt(size(o + 8))) }
        case 10: if need(16) { add(.setWindowOrg(point(o + 8))) }
        case 11: if need(16) { add(.setViewportExt(size(o + 8))) }
        case 12: if need(16) { add(.setViewportOrg(point(o + 8))) }
        case 17: if need(12) { add(.setMapMode(r.u32(o + 8))) }
        case 18: if need(12) { add(.setBkMode(r.u32(o + 8))) }
        case 19: if need(12) { add(.setPolyFillMode(r.u32(o + 8))) }
        case 20: if need(12) { add(.setROP2(r.u32(o + 8))) }
        case 22: if need(12) { add(.setTextAlign(r.u32(o + 8))) }
        case 24: if need(12) { add(.setTextColor(gdiColor(r.u32(o + 8)))) }
        case 25: if need(12) { add(.setBkColor(gdiColor(r.u32(o + 8)))) }
        case 27: if need(16) { add(.moveTo(point(o + 8))) }
        case 28: add(.setMetaRgn)
        case 29: if need(24) { add(.excludeClipRect(rect(o + 8))) }
        case 30: if need(24) { add(.intersectClipRect(rect(o + 8))) }
        case 31, 32:                                   // SCALEVIEWPORTEXTEX / SCALEWINDOWEXTEX
            guard need(24) else { return }
            let v = (Double(r.i32(o + 8)), Double(r.i32(o + 12)), Double(r.i32(o + 16)), Double(r.i32(o + 20)))
            add(type == 31 ? .scaleViewportExt(v.0, v.1, v.2, v.3) : .scaleWindowExt(v.0, v.1, v.2, v.3))
        case 33: add(.saveDC)
        case 34: if need(12) { add(.restoreDC(r.i32(o + 8))) }
        case 35: if need(32) { add(.setWorldTransform(xform(o + 8))) }
        case 36: if need(36) { add(.modifyWorldTransform(xform(o + 8), r.u32(o + 32))) }
        case 37: if need(12) { add(.selectObject(r.u32(o + 8))) }
        case 38:                                       // CREATEPEN
            guard need(28) else { return }
            var style = r.u32(o + 12)
            let width = Double(r.i32(o + 16))
            if width > 0 { style |= 0x1_0000 }                // LOGPEN widths are logical: geometric
            var pen = GDIPen(style: style, width: max(width, 0), color: gdiColor(r.u32(o + 24)))
            if style & 0xF == 5 { pen.color = nil }
            add(.createObject(r.u32(o + 8), .pen(pen)))
        case 39:                                       // CREATEBRUSHINDIRECT
            guard need(24) else { return }
            add(.createObject(r.u32(o + 8), .brush(Self.brush(style: r.u32(o + 12), color: r.u32(o + 16)))))
        case 40: if need(12) { add(.deleteObject(r.u32(o + 8))) }
        case 42: if need(24) { add(.ellipse(rect(o + 8))) }
        case 43: if need(24) { add(.rectangle(rect(o + 8))) }
        case 44: if need(32) { add(.roundRect(rect(o + 8), size(o + 24))) }
        case 54: if need(16) { add(.lineTo(point(o + 8))) }
        case 58: if need(12) { add(.setMiterLimit(Double(r.u32(o + 8)))) }
        case 59: add(.beginPath)
        case 60: add(.endPath)
        case 61: add(.closeFigure)
        case 62: add(.fillPath)
        case 63: add(.strokeAndFillPath)
        case 64: add(.strokePath)
        case 67: if need(12) { add(.selectClipPath(r.u32(o + 8))) }
        case 68: add(.abortPath)
        case 70:                                       // GDICOMMENT
            if need(16), r.u32(o + 12) == 0x2B46_4D45 { emfPlusRecords += 1 }   // "EMF+"
            if need(40), embeddedPDF == nil, r.u32(o + 12) == 0x4349_4447, r.u32(o + 16) == 0x4000_0004 {
                multiFormats(rec)                                                // "GDIC" MULTIFORMATS
            }
        case 75: extSelectClipRgn(rec)
        case 76, 77, 114: blit(type, rec)
        case 81: stretchDIBits(rec)
        case 82: font(rec)
        case 83, 84: text(rec, wide: type == 84)
        case 93, 94: dibPatternBrush(rec)
        case 95: extCreatePen(rec)
        default:
            if !Self.ignored.contains(type) { program.unknown(type) }
        }
    }

    /// `count` points at `at` (16-bit pairs or 32-bit POINTL), all inside `rec`.
    private func points(_ at: Int, _ count: Int, small: Bool, in rec: Range<Int>) -> [CGPoint]? {
        let size = small ? 4 : 8
        guard count >= 0, count <= (rec.upperBound - at) / size, r.range(at, count * size, within: rec) != nil
        else { return nil }
        var pts: [CGPoint] = []
        pts.reserveCapacity(count)
        for i in 0..<count {
            let p = at + i * size
            pts.append(small ? CGPoint(x: Double(r.i16(p)), y: Double(r.i16(p + 2)))
                             : CGPoint(x: Double(r.i32(p)), y: Double(r.i32(p + 4))))
        }
        return pts
    }

    static func brush(style: UInt32, color: UInt32) -> GDIBrush {
        switch style {
        case 1: return GDIBrush(kind: .null, color: gdiColor(color))
        case 2: return GDIBrush(kind: .hatched, color: gdiColor(color))
        case 0: return GDIBrush(kind: .solid, color: gdiColor(color))
        default: return GDIBrush(kind: .pattern, color: RGBA(r: 0.5, g: 0.5, b: 0.5), darkFraction: 0.5)
        }
    }

    /// EMR_COMMENT_MULTIFORMATS: rclOutput (device units), nFormats, then EmrFormat entries (signature,
    /// version, cbData, offData relative to the comment data, i.e. the identifier field). Signatures seen:
    /// 0x50444620 (Office/Adobe) and "%PDF"; the data must start with "%PDF".
    private mutating func multiFormats(_ rec: Range<Int>) {
        let o = rec.lowerBound
        let l = Double(r.i32(o + 20)), t = Double(r.i32(o + 24)), rr = Double(r.i32(o + 28)), b = Double(r.i32(o + 32))
        let output = CGRect(x: l, y: t, width: rr - l, height: b - t).standardized
        let n = Int(r.u32(o + 36))
        guard output.width > 0, output.height > 0, n > 0, n <= (rec.count - 40) / 16 else { return }
        for i in 0..<n {
            let f = o + 40 + 16 * i
            let sig = r.u32(f)
            guard sig == 0x5044_4620 || sig == 0x4644_5025,
                  let data = r.range(o + 12 + Int(r.u32(f + 12)), Int(r.u32(f + 8)), within: rec),
                  data.count > 8, r.u32(data.lowerBound) == 0x4644_5025 else { continue }
            embeddedPDF = (output, Data(r.b[data]))
            return
        }
    }

    private mutating func extCreatePen(_ rec: Range<Int>) {
        let o = rec.lowerBound
        guard rec.count >= 52 else { return }
        let style = r.u32(o + 28), width = Double(r.u32(o + 32)), brushStyle = r.u32(o + 36)
        var pen = GDIPen(style: style, width: width, color: gdiColor(r.u32(o + 40)))
        if style & 0xF == 5 || brushStyle == 1 { pen.color = nil }
        let nStyles = Int(r.u32(o + 48))
        if style & 0xF == 7, nStyles > 0, nStyles <= 16, rec.count >= 52 + 4 * nStyles {
            pen.dashes = (0..<nStyles).map { Double(r.u32(o + 52 + 4 * $0)) }
        }
        add(.createObject(r.u32(o + 8), .pen(pen)))
    }

    private mutating func dibPatternBrush(_ rec: Range<Int>) {
        let o = rec.lowerBound
        guard rec.count >= 32 else { return }
        let ih = r.u32(o + 8), usage = r.u32(o + 12)
        var brush = GDIBrush(kind: .pattern, color: RGBA(r: 0.5, g: 0.5, b: 0.5), darkFraction: 0.5)
        if let info = r.range(o + Int(r.u32(o + 16)), Int(r.u32(o + 20)), within: rec),
           let bits = r.range(o + Int(r.u32(o + 24)), Int(r.u32(o + 28)), within: rec),
           let dib = DIBDecoder.decode(r, info: info, bits: bits, usage: usage,
                                             budget: &program.pixelBudget) {
            let stats = DIBDecoder.brushStats(dib)
            brush.color = stats.color; brush.darkFraction = stats.dark
        }
        add(.createObject(ih, .brush(brush)))
    }

    private mutating func font(_ rec: Range<Int>) {
        let o = rec.lowerBound
        guard rec.count >= 12 + 92 else { return }
        let lf = o + 12
        var f = GDIFont()
        f.height = Double(r.i32(lf))
        f.escapement = Double(r.i32(lf + 8))
        f.weight = Int(r.i32(lf + 16))
        f.italic = r.u8(lf + 20) != 0
        f.charset = r.u8(lf + 23)
        var units: [UInt16] = []
        for i in 0..<32 {
            let u = r.u16(lf + 28 + 2 * i)
            if u == 0 { break }
            units.append(u)
        }
        f.face = String(decoding: units, as: UTF16.self)
        add(.createObject(r.u32(o + 8), .font(f)))
    }

    private mutating func text(_ rec: Range<Int>, wide: Bool) {
        let o = rec.lowerBound
        guard rec.count >= 8 + 28 + 32 else { return }
        let t = o + 36                                  // EmrText
        let count = Int(r.u32(t + 8)), offString = Int(r.u32(t + 12)), options = r.u32(t + 16)
        let hasRect = options & 0x100 == 0              // ETO_NO_RECT: the rectangle field is absent
        let offDx = Int(r.u32(t + (hasRect ? 36 : 20)))
        guard count >= 0, count <= 65536,
              let str = r.range(o + offString, count * (wide ? 2 : 1), within: rec) else { return }
        var units: [UInt16]
        if wide {
            units = (0..<count).map { r.u16(str.lowerBound + 2 * $0) }
        } else {
            units = decodeANSI(r.b[str], charset: 0)
        }
        var run = GDIText(reference: point(t), text: units, options: options)
        if hasRect, rec.count >= 8 + 28 + 40 {
            let rc = rect(t + 20)
            if rc.width != 0 || rc.height != 0 { run.rect = rc }
        }
        let pdy = options & 0x2000 != 0
        let dxCount = count * (pdy ? 2 : 1)
        if offDx > 0, wide || !pdy, let dx = r.range(o + offDx, dxCount * 4, within: rec) {
            let step = pdy ? 2 : 1
            let raw = (0..<count).map { Double(r.i32(dx.lowerBound + 4 * step * $0)) }
            // ANSI text decoded to a different number of UTF-16 units: positions cannot be matched.
            if raw.count == units.count { run.dx = raw }
        }
        add(.text(run))
    }

    private mutating func extSelectClipRgn(_ rec: Range<Int>) {
        let o = rec.lowerBound
        guard rec.count >= 16 else { return }
        let cb = Int(r.u32(o + 8)), mode = r.u32(o + 12)
        guard cb >= 32, let data = r.range(o + 16, cb, within: rec) else {
            if mode == 5 { add(.selectClipRegion(5, [])) }   // RGN_COPY without data: default clip
            return
        }
        let nRects = Int(r.u32(data.lowerBound + 8))
        guard nRects >= 0, nRects <= (cb - 32) / 16 else { return }
        let rects = (0..<nRects).map { rect(data.lowerBound + 32 + 16 * $0) }
        add(.selectClipRegion(mode, rects))
    }

    /// BITBLT (76), STRETCHBLT (77), ALPHABLEND (114): source DIB optional (none = pattern operation).
    private mutating func blit(_ type: UInt32, _ rec: Range<Int>) {
        let o = rec.lowerBound
        let minSize = type == 76 ? 100 : 108
        guard rec.count >= minSize else { return }
        let dest = CGRect(x: Double(r.i32(o + 24)), y: Double(r.i32(o + 28)), width: Double(r.i32(o + 32)),
                          height: Double(r.i32(o + 36)))
        let rop = r.u32(o + 40)
        let srcOrigin = CGPoint(x: Double(r.i32(o + 44)), y: Double(r.i32(o + 48)))
        let usage = r.u32(o + 80)
        let offBmi = Int(r.u32(o + 84)), cbBmi = Int(r.u32(o + 88))
        let offBits = Int(r.u32(o + 92)), cbBits = Int(r.u32(o + 96))
        guard cbBmi > 0, let info = r.range(o + offBmi, cbBmi, within: rec),
              let bits = r.range(o + offBits, cbBits, within: rec) else {
            if type == 76 { add(.patBlt(dest, rop)) }
            return
        }
        guard let dib = DIBDecoder.decode(r, info: info, bits: bits, usage: usage,
                                          alpha: type == 114 && r.u8(o + 43) & 1 != 0,
                                          budget: &program.pixelBudget) else { return }
        var srcSize = CGSize(width: abs(dest.width), height: abs(dest.height))
        if type != 76 { srcSize = CGSize(width: Double(r.i32(o + 100)), height: Double(r.i32(o + 104))) }
        let src = CGRect(origin: srcOrigin, size: srcSize)
        let parts = DIBDecoder.parts(dib, src: src)
        var bm = GDIBitmap(dest: dest, image: parts.image, rop: rop, mask: parts.mask)
        if type == 114 {
            bm.rop = 0x00CC_0020
            bm.blend = (Double(r.u8(o + 42)) / 255, r.u8(o + 43) & 1 != 0)
        }
        add(.bitmap(bm))
        program.cost += dib.width * dib.height * 4
    }

    private mutating func stretchDIBits(_ rec: Range<Int>) {
        let o = rec.lowerBound
        guard rec.count >= 80 else { return }
        let xDest = Double(r.i32(o + 24)), yDest = Double(r.i32(o + 28))
        let xSrc = Double(r.i32(o + 32)), ySrc = Double(r.i32(o + 36))
        let cxSrc = Double(r.i32(o + 40)), cySrc = Double(r.i32(o + 44))
        let offBmi = Int(r.u32(o + 48)), cbBmi = Int(r.u32(o + 52))
        let offBits = Int(r.u32(o + 56)), cbBits = Int(r.u32(o + 60))
        let usage = r.u32(o + 64), rop = r.u32(o + 68)
        let cxDest = Double(r.i32(o + 72)), cyDest = Double(r.i32(o + 76))
        guard let info = r.range(o + offBmi, cbBmi, within: rec), let bits = r.range(o + offBits, cbBits, within: rec),
              let dib = DIBDecoder.decode(r, info: info, bits: bits, usage: usage,
                                              budget: &program.pixelBudget) else { return }
        // Source rectangles of bottom-up DIBs count from the bottom row.
        let top = dib.bottomUp ? Double(dib.height) - ySrc - cySrc : ySrc
        let parts = DIBDecoder.parts(dib, src: CGRect(x: xSrc, y: top, width: cxSrc, height: cySrc))
        add(.bitmap(GDIBitmap(dest: CGRect(x: xDest, y: yDest, width: cxDest, height: cyDest), image: parts.image,
                              rop: rop, mask: parts.mask)))
        program.cost += dib.width * dib.height * 4
    }
}
