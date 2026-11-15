// MetafileRenderer.swift — Task 13 (OOXMLKit)
// Plays a GDIProgram (parsed EMF or WMF) into a CGContext: the GDI device-context state machine (objects,
// DC stack, window/viewport mapping, world transform, paths, clipping) on top of Core Graphics.
//
// Spaces: logical (record coordinates) → world transform → page (window/viewport, map mode) → device
// (reference device pixels for EMF, bbox units for WMF) → the caller's rect. The CTM is set up once to map
// the device frame onto the rect; paths are transformed to device space when they are built (as GDI does),
// so pen widths, clip regions and region rects are device units. Text and bitmaps concatenate the
// logical→device transform locally. Everything bad (non-finite transforms, empty paths) draws nothing.
import CoreGraphics
import CoreText
import Foundation

enum InitialDC {
    case emf
    /// WMF: window and viewport both start as this frame (identity mapping onto the device space).
    case wmf(CGRect)
}

final class MetafileRenderer {
    static let fonts = FontResolver(theme: nil)

    struct DC {
        var pen = GDIPen()
        var brush = GDIBrush(kind: .solid, color: RGBA(r: 1, g: 1, b: 1))
        var font = GDIFont()
        var textColor = RGBA(r: 0, g: 0, b: 0)
        var bkColor = RGBA(r: 1, g: 1, b: 1)
        var bkMode: UInt32 = 2            // OPAQUE
        var textAlign: UInt32 = 0
        var polyFill: UInt32 = 1          // ALTERNATE
        var rop2: UInt32 = 13             // R2_COPYPEN
        var miterLimit = 10.0
        var mapMode: UInt32 = 1           // MM_TEXT
        var winOrg = CGPoint.zero, winExt = CGSize(width: 1, height: 1)
        var vpOrg = CGPoint.zero, vpExt = CGSize(width: 1, height: 1)
        var world = CGAffineTransform.identity
        var clip: CGPath?                 // device units; nil = no clipping
        var metaClip: CGPath?
        var cp = CGPoint.zero             // current position, logical
    }

    let ctx: CGContext
    let isWMF: Bool
    let pixelsPerMM: CGSize
    let hairline: CGFloat
    var dc = DC()
    var stack: [DC] = []
    var objects: [UInt32: GDIObject] = [:]
    /// The path being built (BEGINPATH … ENDPATH) or waiting to be used (device units).
    var path: CGMutablePath?
    var inBracket = false
    /// PATINVERT mask idiom: the brush color XORed onto the destination by the first PATINVERT.
    var xorColor: RGBA?
    /// SRCPAINT of a 1-bit bitmap waiting for the SRCAND that completes the transparency idiom.
    var pendingMask: (dest: CGRect, mask: CGImage)?

    private init(ctx: CGContext, isWMF: Bool, pixelsPerMM: CGSize, hairline: CGFloat) {
        self.ctx = ctx; self.isWMF = isWMF; self.pixelsPerMM = pixelsPerMM; self.hairline = hairline
    }

    static func play(_ program: GDIProgram, in ctx: CGContext, rect: CGRect, deviceFrame df: CGRect,
                     pixelsPerMM: CGSize, hairline: CGFloat, initial: InitialDC) {
        let vals = [rect.minX, rect.minY, rect.width, rect.height, df.minX, df.minY, df.width, df.height]
        guard vals.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0, df.width > 0, df.height > 0 else { return }
        let r = MetafileRenderer(ctx: ctx, isWMF: { if case .wmf = initial { return true } else { return false } }(),
                                 pixelsPerMM: pixelsPerMM, hairline: hairline)
        if case .wmf(let f) = initial {
            r.dc.winOrg = f.origin; r.dc.winExt = f.size
            r.dc.vpOrg = f.origin; r.dc.vpExt = f.size
        }
        let savedTextMatrix = ctx.textMatrix
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / df.width, y: rect.height / df.height)
        ctx.translateBy(x: -df.minX, y: -df.minY)
        for rec in program.records { r.apply(rec) }
        ctx.restoreGState()
        ctx.textMatrix = savedTextMatrix
    }

    // MARK: transforms

    var page: CGAffineTransform {
        var sx = 1.0, sy = 1.0
        var mode = dc.mapMode
        if isWMF { mode = mode == 7 ? 7 : 8 }
        switch mode {
        case 2: sx = 0.1 * pixelsPerMM.width; sy = -0.1 * pixelsPerMM.height          // LOMETRIC
        case 3: sx = 0.01 * pixelsPerMM.width; sy = -0.01 * pixelsPerMM.height        // HIMETRIC
        case 4: sx = 0.254 * pixelsPerMM.width; sy = -0.254 * pixelsPerMM.height      // LOENGLISH
        case 5: sx = 0.0254 * pixelsPerMM.width; sy = -0.0254 * pixelsPerMM.height    // HIENGLISH
        case 6: sx = 25.4 / 1440 * pixelsPerMM.width; sy = -25.4 / 1440 * pixelsPerMM.height  // TWIPS
        case 7, 8:
            sx = dc.winExt.width != 0 ? dc.vpExt.width / dc.winExt.width : 1
            sy = dc.winExt.height != 0 ? dc.vpExt.height / dc.winExt.height : 1
            if mode == 7 {
                let m = min(abs(sx), abs(sy))
                sx = sx < 0 ? -m : m; sy = sy < 0 ? -m : m
            }
        default: break
        }
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: dc.vpOrg.x - dc.winOrg.x * sx,
                                 ty: dc.vpOrg.y - dc.winOrg.y * sy)
    }

    /// Logical → device; nil when not finite or degenerate (nothing is drawn then).
    var xform: CGAffineTransform? {
        let m = dc.world.concatenating(page)
        guard [m.a, m.b, m.c, m.d, m.tx, m.ty].allSatisfy({ $0.isFinite && abs($0) < 1e12 }),
              m.a * m.d - m.b * m.c != 0 else { return nil }
        return m
    }

    static func finite(_ t: CGAffineTransform) -> Bool { [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite) }

    // MARK: records

    func apply(_ rec: GDIRecord) {
        switch rec {
        case .setMapMode(let m): dc.mapMode = m
        case .setWindowOrg(let p): dc.winOrg = p
        case .setWindowExt(let s): if s.width != 0 && s.height != 0 { dc.winExt = s }
        case .setViewportOrg(let p): dc.vpOrg = p
        case .setViewportExt(let s): if s.width != 0 && s.height != 0 { dc.vpExt = s }
        case .offsetWindowOrg(let p): dc.winOrg.x += p.x; dc.winOrg.y += p.y
        case .offsetViewportOrg(let p): dc.vpOrg.x += p.x; dc.vpOrg.y += p.y
        case .scaleWindowExt(let xn, let xd, let yn, let yd): dc.winExt = scaled(dc.winExt, xn, xd, yn, yd)
        case .scaleViewportExt(let xn, let xd, let yn, let yd): dc.vpExt = scaled(dc.vpExt, xn, xd, yn, yd)
        case .setWorldTransform(let t): if Self.finite(t) { dc.world = t }
        case .modifyWorldTransform(let t, let mode):
            guard Self.finite(t) else { return }
            switch mode {
            case 1: dc.world = .identity
            case 2: dc.world = t.concatenating(dc.world)
            case 3: dc.world = dc.world.concatenating(t)
            case 4: dc.world = t
            default: break
            }
        case .saveDC: if stack.count < 4096 { stack.append(dc) }
        case .restoreDC(let n):
            let idx = n < 0 ? stack.count + Int(n) : Int(n) - 1
            guard idx >= 0, idx < stack.count else { return }
            dc = stack[idx]
            stack.removeSubrange(idx...)
        case .createObject(let i, let o): objects[i] = o
        case .selectObject(let i): select(i)
        case .deleteObject(let i): objects[i] = nil
        case .setPolyFillMode(let m): dc.polyFill = m
        case .setBkMode(let m): dc.bkMode = m
        case .setTextAlign(let a): dc.textAlign = a
        case .setROP2(let r): dc.rop2 = r
        case .setTextColor(let c): dc.textColor = c
        case .setBkColor(let c): dc.bkColor = c
        case .setMiterLimit(let m): if m.isFinite, m >= 1 { dc.miterLimit = min(m, 1000) }
        case .moveTo(let p):
            dc.cp = p
            if inBracket, let m = xform { path?.move(to: p.applying(m)) }
        case .lineTo(let p): lineTo(p)
        case .poly(let kind, let pts, let counts): poly(kind, pts, counts)
        case .rectangle(let r): shape { $0.addRect(r.standardized, transform: $1) }
        case .ellipse(let r): shape { $0.addEllipse(in: r.standardized, transform: $1) }
        case .roundRect(let r, let corner):
            let s = r.standardized
            let cw = min(abs(corner.width) / 2, s.width / 2), ch = min(abs(corner.height) / 2, s.height / 2)
            shape { p, m in
                if cw > 0, ch > 0 { p.addRoundedRect(in: s, cornerWidth: cw, cornerHeight: ch, transform: m) }
                else { p.addRect(s, transform: m) }
            }
        case .beginPath: path = CGMutablePath(); inBracket = true
        case .endPath: inBracket = false
        case .closeFigure: if inBracket, let p = path, !p.isEmpty { p.closeSubpath() }
        case .abortPath: path = nil; inBracket = false
        case .fillPath: usePath(fill: true, stroke: false)
        case .strokePath: usePath(fill: false, stroke: true)
        case .strokeAndFillPath: usePath(fill: true, stroke: true)
        case .selectClipPath(let mode):
            inBracket = false
            if let p = path { combineClip(p, mode: mode) }
            path = nil
        case .intersectClipRect(let r):
            if let m = xform { combineClip(CGPath(rect: r.standardized, transform: [m]), mode: 1) }
        case .excludeClipRect(let r):
            if let m = xform { combineClip(CGPath(rect: r.standardized, transform: [m]), mode: 4) }
        case .selectClipRegion(let mode, let rects):
            if rects.isEmpty {
                if mode == 5 { dc.clip = nil }
            } else {
                let p = CGMutablePath()
                for r in rects { p.addRect(r.standardized) }
                combineClip(p, mode: mode)
            }
        case .setMetaRgn:
            if let c = dc.clip { dc.metaClip = dc.metaClip.map { $0.intersection(c) } ?? c }
            dc.clip = nil
        case .text(let t): drawText(t)
        case .bitmap(let b): drawBitmap(b)
        case .patBlt(let r, let rop): patBlt(r, rop: rop)
        case .embeddedPDF(let r, let data): drawPDF(data, in: r)
        }
    }

    private func scaled(_ s: CGSize, _ xn: Double, _ xd: Double, _ yn: Double, _ yd: Double) -> CGSize {
        guard xd != 0, yd != 0 else { return s }
        let n = CGSize(width: s.width * xn / xd, height: s.height * yn / yd)
        return n.width != 0 && n.height != 0 && n.width.isFinite && n.height.isFinite ? n : s
    }

    private func select(_ i: UInt32) {
        if i & 0x8000_0000 != 0 {
            selectStock(i & 0x7FFF_FFFF)
            return
        }
        switch objects[i] {
        case .pen(let p)?: dc.pen = p
        case .brush(let b)?: dc.brush = b
        case .font(let f)?: dc.font = f
        default: break
        }
    }

    private func selectStock(_ n: UInt32) {
        func gray(_ v: Double) -> GDIBrush { GDIBrush(kind: .solid, color: RGBA(r: v, g: v, b: v)) }
        switch n {
        case 0, 18: dc.brush = gray(1)
        case 1: dc.brush = gray(0.75)
        case 2: dc.brush = gray(0.5)
        case 3: dc.brush = gray(0.25)
        case 4: dc.brush = gray(0)
        case 5: dc.brush = GDIBrush(kind: .null, color: RGBA(r: 0, g: 0, b: 0))
        case 6: dc.pen = GDIPen(color: RGBA(r: 1, g: 1, b: 1))
        case 7, 19: dc.pen = GDIPen()
        case 8: dc.pen = GDIPen(style: 5, color: nil)
        case 10, 11, 16: dc.font = GDIFont(face: "Courier New")
        case 12, 13, 14, 17: dc.font = GDIFont(face: "Arial")
        default: break
        }
    }

    // MARK: geometry

    /// A closed shape: added to the open path, or filled and stroked.
    private func shape(_ build: (CGMutablePath, CGAffineTransform) -> Void) {
        guard let m = xform else { return }
        if inBracket, let p = path {
            build(p, m)
            return
        }
        let p = CGMutablePath()
        build(p, m)
        fillAndStroke(p, fill: true, stroke: true)
    }

    private func lineTo(_ to: CGPoint) {
        defer { dc.cp = to }
        guard let m = xform else { return }
        if inBracket, let p = path {
            if p.isEmpty { p.move(to: dc.cp.applying(m)) }
            p.addLine(to: to.applying(m))
            return
        }
        let p = CGMutablePath()
        p.move(to: dc.cp.applying(m))
        p.addLine(to: to.applying(m))
        fillAndStroke(p, fill: false, stroke: true)
    }

    private func poly(_ kind: PolyKind, _ pts: [CGPoint], _ counts: [Int]) {
        guard let m = xform, !pts.isEmpty else { return }
        let d = pts.map { $0.applying(m) }
        let bracket = inBracket ? path : nil
        let p = bracket ?? CGMutablePath()
        var fill = false
        switch kind {
        case .polygon, .polyPolygon, .polyline, .polyPolyline:
            let closed = kind == .polygon || kind == .polyPolygon
            fill = closed
            var at = 0
            for c in counts where c > 0 && at + c <= d.count {
                p.addLines(between: Array(d[at..<(at + c)]))
                if closed { p.closeSubpath() }
                at += c
            }
        case .polyBezier:
            p.move(to: d[0])
            addBeziers(p, d.dropFirst())
        case .polyBezierTo, .polylineTo:
            if bracket == nil || p.isEmpty { p.move(to: dc.cp.applying(m)) }
            if kind == .polylineTo { for q in d { p.addLine(to: q) } } else { addBeziers(p, d[...]) }
            dc.cp = pts[pts.count - 1]
        }
        if bracket == nil { fillAndStroke(p, fill: fill, stroke: true) }
    }

    private func addBeziers(_ p: CGMutablePath, _ pts: ArraySlice<CGPoint>) {
        var i = pts.startIndex
        while i + 2 < pts.endIndex {
            p.addCurve(to: pts[i + 2], control1: pts[i], control2: pts[i + 1])
            i += 3
        }
    }

    private func usePath(fill: Bool, stroke: Bool) {
        inBracket = false
        guard let p = path else { return }
        path = nil
        fillAndStroke(p, fill: fill, stroke: stroke)
    }

    // MARK: clipping

    private static var everything: CGPath { CGPath(rect: CGRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9), transform: nil) }

    private func combineClip(_ p: CGPath, mode: UInt32) {
        let rule: CGPathFillRule = dc.polyFill == 2 ? .winding : .evenOdd
        let region = p.normalized(using: rule)
        switch mode {
        case 1: dc.clip = dc.clip.map { $0.intersection(region) } ?? region
        case 2: dc.clip = dc.clip.map { $0.union(region) }
        case 3: dc.clip = (dc.clip ?? Self.everything).symmetricDifference(region)
        case 4: dc.clip = (dc.clip ?? Self.everything).subtracting(region)
        case 5: dc.clip = region
        default: break
        }
    }

    /// Runs `body` inside the current clip (meta region and clip region); skips it when the clip is empty.
    private func withClip(_ body: () -> Void) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for c in [dc.metaClip, dc.clip] {
            guard let c else { continue }
            if c.isEmpty || c.boundingBoxOfPath.isEmpty { return }
            ctx.addPath(c)
            ctx.clip()
        }
        body()
    }

    // MARK: fill and stroke

    /// The color a fill with the current brush paints, nil = nothing.
    private func fillColor() -> RGBA? {
        let b = dc.brush
        if let x = xorColor, dc.rop2 != 13 {
            // PATINVERT → fill → PATINVERT paints the first brush where the fill is dark (see decisions).
            let a = b.kind == .pattern ? b.darkFraction : 1 - (b.color.r + b.color.g + b.color.b) / 3
            return a > 0.01 ? RGBA(r: x.r, g: x.g, b: x.b, a: a) : nil
        }
        switch dc.rop2 {
        case 11: return nil                                  // R2_NOP
        case 1: return RGBA(r: 0, g: 0, b: 0)                // R2_BLACK
        case 16: return RGBA(r: 1, g: 1, b: 1)               // R2_WHITE
        default: break
        }
        switch b.kind {
        case .null: return nil
        case .solid, .pattern: return b.color
        case .hatched:
            let k = 0.4
            if dc.bkMode == 2 {
                let bk = dc.bkColor
                return RGBA(r: b.color.r * k + bk.r * (1 - k), g: b.color.g * k + bk.g * (1 - k),
                            b: b.color.b * k + bk.b * (1 - k))
            }
            return RGBA(r: b.color.r, g: b.color.g, b: b.color.b, a: k)
        }
    }

    private func fillAndStroke(_ p: CGPath, fill: Bool, stroke: Bool) {
        guard !p.isEmpty else { return }
        let fc = fill ? fillColor() : nil
        let strokes = stroke && setUpPenNeeded()
        guard fc != nil || strokes else { return }
        withClip {
            if let fc {
                ctx.addPath(p)
                ctx.setFillColor(DrawingRenderer.cgColor(fc))
                ctx.fillPath(using: dc.polyFill == 2 ? .winding : .evenOdd)
            }
            if strokes, setUpPen() {
                ctx.addPath(p)
                ctx.strokePath()
            }
        }
    }

    private func setUpPenNeeded() -> Bool {
        dc.rop2 != 11 && xorColor == nil && dc.pen.color != nil && dc.pen.kind != 5
    }

    /// Line width, color, caps, joins and dashes of the current pen in device units.
    private func setUpPen() -> Bool {
        guard setUpPenNeeded(), var color = dc.pen.color, let m = xform else { return false }
        if dc.rop2 == 1 { color = RGBA(r: 0, g: 0, b: 0) } else if dc.rop2 == 16 { color = RGBA(r: 1, g: 1, b: 1) }
        let pen = dc.pen
        let scale = sqrt(abs(m.a * m.d - m.b * m.c))
        // Every GDI pen is at least one device pixel wide; cosmetic pens are exactly that (≈ hairline).
        let w = max(pen.cosmetic ? hairline : pen.width * scale, hairline)
        guard w.isFinite, w < 1e7 else { return false }
        ctx.setLineWidth(w)
        ctx.setStrokeColor(DrawingRenderer.cgColor(color))
        if pen.cosmetic {
            ctx.setLineCap(.butt); ctx.setLineJoin(.miter)
        } else {
            switch pen.style & 0xF00 {
            case 0x100: ctx.setLineCap(.square)
            case 0x200: ctx.setLineCap(.butt)
            default: ctx.setLineCap(.round)
            }
            switch pen.style & 0xF000 {
            case 0x1000: ctx.setLineJoin(.bevel)
            case 0x2000: ctx.setLineJoin(.miter)
            default: ctx.setLineJoin(.round)
            }
        }
        ctx.setMiterLimit(dc.miterLimit)
        let unit = pen.cosmetic ? 3 * hairline : w
        var dashes: [CGFloat]
        switch pen.kind {
        case 1: dashes = [3, 1]
        case 2: dashes = [1, 1]
        case 3: dashes = [3, 1, 1, 1]
        case 4: dashes = [3, 1, 1, 1, 1, 1]
        case 7: dashes = pen.dashes.map { $0 * (pen.cosmetic ? hairline : scale) / unit }
        default: dashes = []
        }
        dashes = dashes.map { max($0 * unit, 0.01) }
        ctx.setLineDash(phase: 0, lengths: dashes.allSatisfy(\.isFinite) && dashes.count >= 2 ? dashes : [])
        return true
    }

    // MARK: raster operations

    private func patBlt(_ r: CGRect, rop: UInt32) {
        guard let m = xform else { return }
        let p = CGPath(rect: r.standardized, transform: [m])
        var color: RGBA?
        switch rop {
        case 0x00F0_0021: color = dc.brush.kind == .null ? nil : dc.brush.color      // PATCOPY
        case 0x0000_0042: color = RGBA(r: 0, g: 0, b: 0)                             // BLACKNESS
        case 0x00FF_0062: color = RGBA(r: 1, g: 1, b: 1)                             // WHITENESS
        case 0x005A_0049:                                                            // PATINVERT
            xorColor = xorColor == nil && dc.brush.kind != .null ? dc.brush.color : nil
            return
        default: return                                                              // DSTINVERT, NOP, …
        }
        guard let c = color else { return }
        withClip {
            ctx.addPath(p)
            ctx.setFillColor(DrawingRenderer.cgColor(c))
            ctx.fillPath()
        }
    }

    private func drawBitmap(_ b: GDIBitmap) {
        guard let m = xform, b.dest.width != 0, b.dest.height != 0 else { return }
        let devRect = b.dest.applying(m)
        var mask: CGImage?
        var multiply = false
        switch b.rop {
        case 0x00AA_0029: return                                                     // NOP
        case 0x00EE_0086 where b.mask != nil:                                        // SRCPAINT of a mask
            if let g = b.mask { pendingMask = (devRect, g) }
            return
        case 0x0088_00C6:                                                            // SRCAND
            if let pm = pendingMask, Self.close(pm.dest, devRect) { mask = pm.mask } else { multiply = true }
        default: break
        }
        pendingMask = nil
        withClip {
            ctx.concatenate(m)
            ctx.translateBy(x: b.dest.minX, y: b.dest.minY)
            ctx.scaleBy(x: b.dest.width, y: b.dest.height)
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let mask { ctx.clip(to: unit, mask: mask) }
            if multiply { ctx.setBlendMode(.multiply) }
            if let blend = b.blend { ctx.setAlpha(CGFloat(min(max(blend.constant, 0), 1))) }
            ctx.interpolationQuality = .high
            ctx.draw(b.image, in: unit)
        }
    }

    /// Page 1 of `data` stretched onto `r` (device units), upright in the y-down device space.
    private func drawPDF(_ data: Data, in r: CGRect) {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return }
        withClip {
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: r.width / box.width, y: -r.height / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        let s = a.standardized, t = b.standardized
        let tol = max(1, 0.01 * max(s.width, s.height))
        return abs(s.minX - t.minX) <= tol && abs(s.minY - t.minY) <= tol && abs(s.width - t.width) <= tol
            && abs(s.height - t.height) <= tol
    }

    // MARK: text

    private static let symbolFaces: Set<String> = ["wingdings", "wingdings 2", "wingdings 3", "symbol"]

    private func drawText(_ t: GDIText) {
        guard let m = xform, !t.text.isEmpty, t.options & 0x10 == 0 else { return }   // ETO_GLYPH_INDEX: skipped
        let f = dc.font
        let updateCP = dc.textAlign & 1 != 0
        let ref = updateCP ? dc.cp : t.reference
        let origin = ref.applying(m)
        let sx = hypot(m.a, m.b), sy = hypot(m.c, m.d)
        var size = f.height == 0 ? 12 : abs(f.height) * sy
        guard size.isFinite, size > 0.05, size < 1e5 else { return }

        var text = String(decoding: t.text, as: UTF16.self)
        var face: String? = f.face.isEmpty ? nil : f.face
        if Self.symbolFaces.contains(f.face.trimmingCharacters(in: .whitespaces).lowercased()) {
            let mapped = FontResolver.mapSymbolText(text, typeface: f.face)
            text = mapped.text; face = mapped.typeface
        }
        let bold = f.weight >= 600
        var font = Self.fonts.font(typeface: face, size: size, bold: bold, italic: f.italic)
        if f.height > 0 {   // cell height (ascent + descent) → em size
            let cell = CTFontGetAscent(font) + CTFontGetDescent(font)
            if cell > 0 {
                size = size * size / cell
                font = Self.fonts.font(typeface: face, size: size, bold: bold, italic: f.italic)
            }
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        // No standard ligatures (GDI draws none; see ParagraphSetter.noLigatures).
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true,
                     kCTLigatureAttributeName: ParagraphSetter.noLigatures] as CFDictionary
        func line(_ s: String) -> CTLine {
            CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
        }

        // Pieces with their x offset along the baseline (device units).
        var pieces: [(CTLine, CGFloat)] = []
        var width: CGFloat = 0
        let units = Array(text.utf16)
        if let dx = t.dx, dx.count == units.count {
            var x: CGFloat = 0
            var i = 0
            while i < units.count {
                let pair = UTF16.isLeadSurrogate(units[i]) && i + 1 < units.count
                let n = pair ? 2 : 1
                pieces.append((line(String(decoding: units[i..<(i + n)], as: UTF16.self)), x))
                for k in i..<(i + n) { x += dx[k] * sx }
                i += n
            }
            width = x
        } else {
            let l = line(text)
            pieces = [(l, 0)]
            width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        }
        guard width.isFinite else { return }

        let x0: CGFloat
        switch dc.textAlign & 6 {
        case 6: x0 = -width / 2      // TA_CENTER
        case 2: x0 = -width          // TA_RIGHT
        default: x0 = 0
        }
        let baseline: CGFloat
        if dc.textAlign & 24 == 24 { baseline = 0 } else if dc.textAlign & 8 != 0 { baseline = -descent } else { baseline = ascent }
        let angle = atan2(dc.world.b, dc.world.a) - f.escapement * .pi / 1800

        withClip {
            if let r = t.rect {
                let rp = CGPath(rect: r.standardized, transform: [m])
                if t.options & 0x2 != 0 {                     // ETO_OPAQUE
                    ctx.addPath(rp)
                    ctx.setFillColor(DrawingRenderer.cgColor(dc.bkColor))
                    ctx.fillPath()
                }
                if t.options & 0x4 != 0 { ctx.addPath(rp); ctx.clip() }   // ETO_CLIPPED
            }
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.rotate(by: angle)
            if dc.bkMode == 2 {
                ctx.setFillColor(DrawingRenderer.cgColor(dc.bkColor))
                ctx.fill(CGRect(x: x0, y: baseline - ascent, width: width, height: ascent + descent))
            }
            ctx.setFillColor(DrawingRenderer.cgColor(dc.textColor))
            for (l, x) in pieces {
                ctx.saveGState()
                ctx.translateBy(x: x0 + x, y: baseline)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                ctx.textPosition = .zero
                CTLineDraw(l, ctx)
                ctx.restoreGState()
            }
        }
        if updateCP, sx > 0 { dc.cp.x += width / sx }
    }
}
