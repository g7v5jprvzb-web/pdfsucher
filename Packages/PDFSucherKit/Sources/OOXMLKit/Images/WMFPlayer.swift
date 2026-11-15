// WMFPlayer.swift — Task 13 (OOXMLKit)
// Parses a Windows Metafile (MS-WMF, optionally with the "placeable" Aldus header) into the shared GDI record
// list; playback is MetafileRenderer's. WMF object slots are assigned here (a new object takes the lowest
// free index; DELETEOBJECT frees it), so the record list carries explicit indices like EMF.
// The device space is the placeable bbox in logical units (else the first window org/ext); the window maps
// onto it whatever the map mode (decision: map modes are not used for WMF except ISOTROPIC).
import CoreGraphics
import Foundation

public struct WMFDocument: Sendable {
    /// The frame in 0.01 mm: placeable bbox / units per inch; without placeable header the first
    /// SETWINDOWORG/SETWINDOWEXT taken as 96-dpi pixels.
    public let bounds: CGRect

    let program: GDIProgram
    /// bbox in logical units = the device space mapped onto the target rect.
    let deviceFrame: CGRect
    let unitsPerInch: Double

    var recordCount: Int { program.recordCount }
    var unknownRecordTypes: [UInt32: Int] { program.unknownRecordTypes }
    var hasDrawing: Bool { program.hasDrawing }

    static func looksLikeWMF(_ data: Data) -> Bool {
        let r = ByteReader(b: [UInt8](data.prefix(22)))
        if r.u32(0) == 0x9AC6_CDD7 { return data.count >= 40 }
        return data.count >= 18 && (r.u16(0) == 1 || r.u16(0) == 2) && r.u16(2) == 9
            && (r.u16(4) == 0x100 || r.u16(4) == 0x300)
    }

    public init(data: Data) throws {
        try self.init(data: data, pixelBudget: DIBDecoder.documentPixelBudget, maxRecords: GDIProgram.maxRecords)
    }

    /// `pixelBudget`: bitmap pixels decoded at most; `maxRecords`: records read at most (tests lower them).
    init(data: Data, pixelBudget: Int = DIBDecoder.documentPixelBudget,
         maxRecords: Int = GDIProgram.maxRecords) throws {
        let r = ByteReader(b: [UInt8](data))
        var start = 0
        var frame: CGRect?
        var inch = 96.0
        if r.u32(0) == 0x9AC6_CDD7 {
            guard r.b.count >= 22 + 18 else { throw MetafileError.truncated }
            let l = Double(r.i16(6)), t = Double(r.i16(8)), rr = Double(r.i16(10)), b = Double(r.i16(12))
            let units = Double(r.u16(14))
            inch = units > 0 ? units : 1440
            frame = CGRect(x: min(l, rr), y: min(t, b), width: abs(rr - l), height: abs(b - t))
            start = 22
        }
        guard r.b.count >= start + 18 else { throw MetafileError.truncated }
        let type = r.u16(start), headerWords = Int(r.u16(start + 2))
        guard type == 1 || type == 2, headerWords == 9 else { throw MetafileError.invalidHeader }

        var parser = WMFParser(r: r)
        parser.program.pixelBudget = pixelBudget
        parser.run(maxRecords: maxRecords, from: start + 18)
        program = parser.program
        unitsPerInch = inch
        if frame == nil || frame?.width == 0 || frame?.height == 0 {
            if let org = parser.firstWindowOrg, let ext = parser.firstWindowExt {
                frame = CGRect(x: org.x + min(ext.width, 0), y: org.y + min(ext.height, 0),
                               width: abs(ext.width), height: abs(ext.height))
            }
        }
        let dev = frame ?? .zero
        deviceFrame = dev
        let k = 2540 / inch
        bounds = CGRect(x: dev.minX * k, y: dev.minY * k, width: dev.width * k, height: dev.height * k)
    }

    public func draw(in ctx: CGContext, rect: CGRect) {
        guard deviceFrame.width > 0, deviceFrame.height > 0 else { return }
        let ppmm = unitsPerInch / 25.4
        MetafileRenderer.play(program, in: ctx, rect: rect, deviceFrame: deviceFrame,
                              pixelsPerMM: CGSize(width: ppmm, height: ppmm), hairline: max(unitsPerInch / 96, 0),
                              initial: .wmf(deviceFrame))
    }
}

private struct WMFParser {
    let r: ByteReader
    var program = GDIProgram()
    var slots: [Bool] = []
    var fontCharsets: [Int: UInt8] = [:]
    var charset: UInt8 = 0
    var firstWindowOrg: CGPoint?
    var firstWindowExt: CGSize?

    /// Understood, no effect: ESCAPE, SETRELABS, SETSTRETCHBLTMODE, SETTEXTCHAREXTRA, SETTEXTJUSTIFICATION,
    /// SETMAPPERFLAGS, SELECTPALETTE, REALIZEPALETTE, SETPALENTRIES, RESIZEPALETTE, ANIMATEPALETTE,
    /// SELECTCLIPREGION, OFFSETCLIPRGN, SETLAYOUT.
    static let ignored: Set<UInt16> = [0x626, 0x105, 0x107, 0x108, 0x20A, 0x231, 0x234, 0x035, 0x037, 0x139,
                                       0x436, 0x12C, 0x220, 0x149]

    init(r: ByteReader) { self.r = r }

    mutating func run(maxRecords: Int, from start: Int) {
        program.recordCount = 1
        var off = start
        while off + 6 <= r.b.count, program.recordCount < maxRecords {
            let words = Int(r.u32(off)), fn = r.u16(off + 4)
            guard words >= 3, words <= (r.b.count - off) / 2 else { break }
            program.recordCount += 1
            if fn == 0 { break }   // EOF
            record(fn, off..<(off + 2 * words))
            off += 2 * words
        }
        // `+=`: the bitmaps were counted while parsing (see EMFPlayer.run).
        program.cost += program.records.count * 64 + r.b.count
    }

    private mutating func add(_ rec: GDIRecord) { program.records.append(rec) }

    private mutating func create(_ obj: GDIObject) -> Int {
        let i = slots.firstIndex(of: false) ?? slots.count
        if i == slots.count { slots.append(true) } else { slots[i] = true }
        add(.createObject(UInt32(i), obj))
        return i
    }

    private func s(_ o: Int) -> Double { Double(r.i16(o)) }
    /// (y, x) pair as stored by most WMF records.
    private func yx(_ o: Int) -> CGPoint { CGPoint(x: s(o + 2), y: s(o)) }
    /// bottom, right, top, left.
    private func brtl(_ o: Int) -> CGRect {
        let b = s(o), rr = s(o + 2), t = s(o + 4), l = s(o + 6)
        return CGRect(x: l, y: t, width: rr - l, height: b - t)
    }

    private mutating func record(_ fn: UInt16, _ rec: Range<Int>) {
        let p = rec.lowerBound + 6
        let n = rec.upperBound - p       // parameter bytes
        func need(_ bytes: Int) -> Bool { n >= bytes }
        switch fn {
        case 0x20B:
            guard need(4) else { return }
            let o = yx(p)
            if firstWindowOrg == nil { firstWindowOrg = o }
            add(.setWindowOrg(o))
        case 0x20C:
            guard need(4) else { return }
            let e = yx(p)
            if firstWindowExt == nil { firstWindowExt = CGSize(width: e.x, height: e.y) }
            add(.setWindowExt(CGSize(width: e.x, height: e.y)))
        case 0x20D: if need(4) { add(.setViewportOrg(yx(p))) }
        case 0x20E: if need(4) { let e = yx(p); add(.setViewportExt(CGSize(width: e.x, height: e.y))) }
        case 0x20F: if need(4) { add(.offsetWindowOrg(yx(p))) }
        case 0x211: if need(4) { add(.offsetViewportOrg(yx(p))) }
        case 0x410, 0x412:
            guard need(8) else { return }
            let v = (s(p + 6), s(p + 4), s(p + 2), s(p))   // xNum, xDenom, yNum, yDenom
            add(fn == 0x410 ? .scaleWindowExt(v.0, v.1, v.2, v.3) : .scaleViewportExt(v.0, v.1, v.2, v.3))
        case 0x103: if need(2) { add(.setMapMode(UInt32(r.u16(p)))) }
        case 0x102: if need(2) { add(.setBkMode(UInt32(r.u16(p)))) }
        case 0x104: if need(2) { add(.setROP2(UInt32(r.u16(p)))) }
        case 0x106: if need(2) { add(.setPolyFillMode(UInt32(r.u16(p)))) }
        case 0x12E: if need(2) { add(.setTextAlign(UInt32(r.u16(p)))) }
        case 0x209: if need(4) { add(.setTextColor(gdiColor(r.u32(p)))) }
        case 0x201: if need(4) { add(.setBkColor(gdiColor(r.u32(p)))) }
        case 0x01E: add(.saveDC)
        case 0x127: if need(2) { add(.restoreDC(Int32(r.i16(p)))) }
        case 0x12D:
            guard need(2) else { return }
            let i = Int(r.u16(p))
            if let cs = fontCharsets[i] { charset = cs }
            add(.selectObject(UInt32(i)))
        case 0x1F0:
            guard need(2) else { return }
            let i = Int(r.u16(p))
            if i < slots.count { slots[i] = false }
            fontCharsets[i] = nil
            add(.deleteObject(UInt32(i)))
        case 0x2FA:                                         // CREATEPENINDIRECT
            guard need(10) else { return }
            var style = UInt32(r.u16(p))
            let width = s(p + 2)
            if width > 0 { style |= 0x1_0000 }               // WMF widths are logical: geometric
            var pen = GDIPen(style: style, width: max(width, 0), color: gdiColor(r.u32(p + 6)))
            if style & 0xF == 5 { pen.color = nil }
            _ = create(.pen(pen))
        case 0x2FC:                                         // CREATEBRUSHINDIRECT
            guard need(8) else { return }
            let style = UInt32(r.u16(p)), color = r.u32(p + 2)
            _ = create(.brush(style == 0 || style == 1 || style == 2
                ? GDIBrush(kind: style == 0 ? .solid : style == 1 ? .null : .hatched, color: gdiColor(color))
                : GDIBrush(kind: .pattern, color: RGBA(r: 0.5, g: 0.5, b: 0.5), darkFraction: 0.5)))
        case 0x2FB: font(p, n)
        case 0x142:                                         // DIBCREATEPATTERNBRUSH
            var brush = GDIBrush(kind: .pattern, color: RGBA(r: 0.5, g: 0.5, b: 0.5), darkFraction: 0.5)
            if need(4), r.u16(p) != 3, let packed = DIBDecoder.packed(r, (p + 4)..<rec.upperBound),
               let dib = DIBDecoder.decode(r, info: packed.info, bits: packed.bits, usage: UInt32(r.u16(p + 2)),
                                            budget: &program.pixelBudget) {
                let st = DIBDecoder.brushStats(dib)
                brush.color = st.color; brush.darkFraction = st.dark
            }
            _ = create(.brush(brush))
        case 0x0F7, 0x6FF: _ = create(.other)               // CREATEPALETTE, CREATEREGION
        case 0x1F9: _ = create(.brush(GDIBrush(kind: .pattern, color: RGBA(r: 0.5, g: 0.5, b: 0.5), darkFraction: 0.5)))
        case 0x214: if need(4) { add(.moveTo(yx(p))) }
        case 0x213: if need(4) { add(.lineTo(yx(p))) }
        case 0x324, 0x325:
            guard need(2) else { return }
            let count = Int(r.i16(p))
            guard let pts = points(p + 2, count, rec) else { return }
            add(.poly(fn == 0x324 ? .polygon : .polyline, pts, counts: [count]))
        case 0x538:                                         // POLYPOLYGON
            guard need(2) else { return }
            let nPolys = Int(r.u16(p))
            guard nPolys <= (n - 2) / 2 else { return }
            let counts = (0..<nPolys).map { Int(r.u16(p + 2 + 2 * $0)) }
            let total = counts.reduce(0, +)
            guard let pts = points(p + 2 + 2 * nPolys, total, rec) else { return }
            add(.poly(.polyPolygon, pts, counts: counts))
        case 0x41B: if need(8) { add(.rectangle(brtl(p))) }
        case 0x418: if need(8) { add(.ellipse(brtl(p))) }
        case 0x61C:
            guard need(12) else { return }
            add(.roundRect(brtl(p + 4), CGSize(width: s(p + 2), height: s(p))))
        case 0x416: if need(8) { add(.intersectClipRect(brtl(p))) }
        case 0x415: if need(8) { add(.excludeClipRect(brtl(p))) }
        case 0x521: textOut(p, rec)
        case 0xA32: extTextOut(p, rec)
        case 0x61D:                                         // PATBLT
            guard need(12) else { return }
            add(.patBlt(CGRect(x: s(p + 10), y: s(p + 8), width: s(p + 6), height: s(p + 4)), r.u32(p)))
        case 0xF43: stretchDIB(p, rec)
        case 0xB41, 0x940: dibBlt(fn, p, rec)
        default:
            if !Self.ignored.contains(fn) { program.unknown(UInt32(fn)) }
        }
    }

    private func points(_ at: Int, _ count: Int, _ rec: Range<Int>) -> [CGPoint]? {
        guard count >= 0, r.range(at, count * 4, within: rec) != nil else { return nil }
        return (0..<count).map { CGPoint(x: s(at + 4 * $0), y: s(at + 4 * $0 + 2)) }
    }

    private mutating func font(_ p: Int, _ n: Int) {
        guard n >= 18 else { _ = create(.font(GDIFont())); return }
        var f = GDIFont()
        f.height = s(p)
        f.escapement = s(p + 4)
        f.weight = Int(r.i16(p + 8))
        f.italic = r.u8(p + 10) != 0
        f.charset = r.u8(p + 13)
        var name: [UInt8] = []
        for i in 0..<min(32, n - 18) {
            let c = r.u8(p + 18 + i)
            if c == 0 { break }
            name.append(c)
        }
        f.face = String(decoding: decodeANSI(name[...], charset: 0), as: UTF16.self)
        let slot = create(.font(f))
        fontCharsets[slot] = f.charset
    }

    private mutating func textOut(_ p: Int, _ rec: Range<Int>) {
        let count = Int(r.i16(p))
        guard count >= 0, let str = r.range(p + 2, count, within: rec) else { return }
        let after = p + 2 + (count + 1) / 2 * 2
        guard after + 4 <= rec.upperBound else { return }
        add(.text(GDIText(reference: yx(after), text: decodeANSI(r.b[str], charset: charset))))
    }

    private mutating func extTextOut(_ p: Int, _ rec: Range<Int>) {
        guard rec.upperBound - p >= 8 else { return }
        let ref = yx(p)
        let count = Int(r.i16(p + 4)), opts = UInt32(r.u16(p + 6))
        var at = p + 8
        var rect: CGRect?
        if opts & 0x6 != 0 {
            guard at + 8 <= rec.upperBound else { return }
            let l = s(at), t = s(at + 2), rr = s(at + 4), b = s(at + 6)
            rect = CGRect(x: l, y: t, width: rr - l, height: b - t)
            at += 8
        }
        guard count >= 0, let str = r.range(at, count, within: rec) else { return }
        var run = GDIText(reference: ref, text: decodeANSI(r.b[str], charset: charset), options: opts, rect: rect)
        let dxAt = at + (count + 1) / 2 * 2
        if let dx = r.range(dxAt, count * 2, within: rec), run.text.count == count {
            run.dx = (0..<count).map { s(dx.lowerBound + 2 * $0) }
        }
        add(.text(run))
    }

    private mutating func stretchDIB(_ p: Int, _ rec: Range<Int>) {
        guard rec.upperBound - p >= 22, let packed = DIBDecoder.packed(r, (p + 22)..<rec.upperBound),
              let dib = DIBDecoder.decode(r, info: packed.info, bits: packed.bits, usage: UInt32(r.u16(p + 4)),
                                            budget: &program.pixelBudget)
        else { return }
        let srcH = s(p + 6), srcW = s(p + 8), ySrc = s(p + 10), xSrc = s(p + 12)
        let top = dib.bottomUp ? Double(dib.height) - ySrc - srcH : ySrc
        let parts = DIBDecoder.parts(dib, src: CGRect(x: xSrc, y: top, width: srcW, height: srcH))
        let dest = CGRect(x: s(p + 20), y: s(p + 18), width: s(p + 16), height: s(p + 14))
        add(.bitmap(GDIBitmap(dest: dest, image: parts.image, rop: r.u32(p), mask: parts.mask)))
        program.cost += dib.width * dib.height * 4
    }

    /// DIBSTRETCHBLT (0xB41) / DIBBITBLT (0x940); the variants without bitmap are pattern operations.
    private mutating func dibBlt(_ fn: UInt16, _ p: Int, _ rec: Range<Int>) {
        let words = rec.count / 2
        let stretch = fn == 0xB41
        let rop = r.u32(p)
        if words == Int(fn >> 8) + 3 {
            let d = stretch ? p + 14 : p + 10
            guard d + 8 <= rec.upperBound else { return }
            add(.patBlt(CGRect(x: s(d + 6), y: s(d + 4), width: s(d + 2), height: s(d)), rop))
            return
        }
        let dibAt = stretch ? p + 20 : p + 16
        guard dibAt < rec.upperBound, let packed = DIBDecoder.packed(r, dibAt..<rec.upperBound),
              let dib = DIBDecoder.decode(r, info: packed.info, bits: packed.bits,
                                            budget: &program.pixelBudget) else { return }
        let dest: CGRect, src: CGRect
        if stretch {
            src = CGRect(x: s(p + 10), y: s(p + 8), width: s(p + 6), height: s(p + 4))
            dest = CGRect(x: s(p + 18), y: s(p + 16), width: s(p + 14), height: s(p + 12))
        } else {
            let w = s(p + 10), h = s(p + 8)
            src = CGRect(x: s(p + 6), y: s(p + 4), width: w, height: h)
            dest = CGRect(x: s(p + 14), y: s(p + 12), width: w, height: h)
        }
        let parts = DIBDecoder.parts(dib, src: src)
        add(.bitmap(GDIBitmap(dest: dest, image: parts.image, rop: rop, mask: parts.mask)))
        program.cost += dib.width * dib.height * 4
    }
}
