// DrawingRenderer.swift — Task 6 (OOXMLKit)
// Draws ShapeModel / PictureModel / GroupModel with Core Graphics.
//
// Coordinate convention: the context's CTM must map points with the origin at the top left and y pointing
// down (the caller flips once per page: translate(0, height), scale(1, −1), plus any zoom). Models are in
// that space; each draw call saves and restores the graphics state. Bad values never trap: unusable
// transforms, missing images and empty gradients simply draw nothing.
import CoreGraphics
import Foundation

public struct DrawingRenderer: Sendable {
    public let images: ImageDecoder
    public let fonts: FontResolver

    public init(images: ImageDecoder, fonts: FontResolver) {
        self.images = images
        self.fonts = fonts
    }

    // MARK: entry points

    /// `groupFill` and `mirroredByGroups` are what the enclosing groups pass down (see `drawGroup`).
    public func draw(_ element: DrawingElement, in ctx: CGContext, groupFill: Fill = .none,
                     mirroredByGroups: Bool = false,
                     text: (ShapeModel, CGContext, CGRect) -> Void = { _, _, _ in }) {
        switch element {
        case .shape(let s):
            drawShape(s, in: ctx, groupFill: groupFill, mirroredByGroups: mirroredByGroups) { text(s, $0, $1) }
        case .picture(let p): drawPicture(p, in: ctx)
        case .group(let g):
            drawGroup(g, in: ctx, groupFill: groupFill, mirroredByGroups: mirroredByGroups, text: text)
        }
    }

    /// Fill, then line (with arrowheads), both under the shadow; then `text` is called with the context
    /// transformed into shape space (origin = shape top-left, rotation applied, never mirrored: flipV turns
    /// the text by 180°) and the text rectangle. `groupFill` replaces a `.group` fill.
    /// `mirroredByGroups`: the enclosing groups put an odd number of mirrors into the CTM; the text pass then
    /// mirrors back horizontally about the text rectangle's centre, so a group flipH leaves text upright and
    /// a group flipV turns it by 180° (as a shape's own flipV does).
    public func drawShape(_ s: ShapeModel, in ctx: CGContext, groupFill: Fill = .none,
                          mirroredByGroups: Bool = false,
                          text: (CGContext, CGRect) -> Void = { _, _ in }) {
        let t = s.transform
        guard Self.finite(t) else { return }
        let fill = s.fill == .group ? groupFill : s.fill
        let geo = s.geometryPaths()
        ctx.saveGState()
        // A zero-size shape draws no fill/line but still gets its text (text boxes may have no extent).
        if Self.usable(t) {
            withShadow(s.shadow, in: ctx, active: fill != .none || s.line != nil) {
                ctx.concatenate(t.affine)
                let bounds = CGRect(origin: .zero, size: t.extent)
                for gp in geo.paths where gp.fill != .none && fill != .none {
                    drawFill(Self.modulated(fill, gp.fill), path: gp.path, bounds: bounds, in: ctx)
                }
                if let line = s.line { drawLine(line, paths: geo.paths, in: ctx) }
            }
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.concatenate(t.textAffine)
        let textRect = geo.textRect ?? CGRect(origin: .zero, size: t.extent)
        if mirroredByGroups {
            ctx.translateBy(x: textRect.midX, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.translateBy(x: -textRect.midX, y: 0)
        }
        text(ctx, textRect)
        ctx.restoreGState()
    }

    /// The image clipped to the geometry (crop, fillRect insets and alphaModFix applied), then the line.
    /// An unresolvable or undecodable image draws nothing (the line is still drawn).
    /// `lineOutside` (PowerPoint): the outline is drawn entirely outside the picture's geometry (stroked at twice
    /// the width, clipped to the outside; dash lengths kept), so it never covers the image. false: centred.
    public func drawPicture(_ p: PictureModel, in ctx: CGContext, lineOutside: Bool = false) {
        let t = p.transform
        guard Self.usable(t) else { return }
        let geo = GeometryBuilder.paths(p.geometry ?? .preset("rect", adjust: [:]), size: t.extent)
        let bounds = CGRect(origin: .zero, size: t.extent)
        let image = p.image.flatMap { ref in
            decodedImage(ref, drawnIn: Self.imageRect(ref: ref, stretch: p.stretch, bounds: bounds), in: ctx).map { (ref, $0) }
        }
        ctx.saveGState()
        withShadow(p.shadow, in: ctx, active: image != nil || p.line != nil) {
            ctx.concatenate(t.affine)
            if let (ref, decoded) = image {
                let clip = CGMutablePath()
                for gp in geo.paths where gp.fill != .none { clip.addPath(gp.path) }
                drawImage(decoded, ref: ref, stretch: p.stretch, clip: clip, bounds: bounds, in: ctx)
            }
            if let line = p.line {
                if lineOutside, line.width > 0, geo.paths.contains(where: { $0.fill != .none }) {
                    var outer = line
                    outer.width = line.width * 2
                    outer.dash = line.dash?.map { $0 / 2 }
                    let pad = line.width * 4 + 1
                    let outside = CGMutablePath()
                    outside.addRect(bounds.insetBy(dx: -pad, dy: -pad))
                    for gp in geo.paths where gp.fill != .none { outside.addPath(gp.path) }
                    ctx.saveGState()
                    ctx.addPath(outside)
                    ctx.clip(using: .evenOdd)
                    drawLine(outer, paths: geo.paths, in: ctx)
                    ctx.restoreGState()
                } else {
                    drawLine(line, paths: geo.paths, in: ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    /// Children in the group's child space; `.group` fills of children resolve to the group's fill (or, if
    /// that is `.group` too, to `groupFill` from the enclosing group). Mirror parity is accumulated through
    /// nested groups (a group with exactly one of flipH/flipV mirrors) so children's text is never mirrored.
    /// Group scaling (chExt ≠ ext) moves and sizes the children's boxes but never stretches them: each child is
    /// drawn with its box scaled (`GroupScale`), so line widths, arrowheads, geometry and text keep their sizes;
    /// the text callback gets the scaled shape.
    public func drawGroup(_ g: GroupModel, in ctx: CGContext, groupFill: Fill = .none,
                          mirroredByGroups: Bool = false,
                          text: (ShapeModel, CGContext, CGRect) -> Void = { _, _, _ in }) {
        drawGroup(g, chain: .identity, in: ctx, groupFill: groupFill, mirroredByGroups: mirroredByGroups, text: text)
    }

    /// `chain`: the enclosing groups' child → parent transforms (identity outside any group), not in the CTM.
    private func drawGroup(_ g: GroupModel, chain: CGAffineTransform, in ctx: CGContext, groupFill: Fill,
                           mirroredByGroups: Bool, text: (ShapeModel, CGContext, CGRect) -> Void) {
        let m = g.transform.childToParent.concatenating(chain)
        guard Self.finite(m), let split = GroupScale(m) else { return }
        let inherited = g.fill == .group ? groupFill : g.fill
        let mirrored = mirroredByGroups != (g.transform.flipH != g.transform.flipV)
        for child in g.children {
            switch child {
            case .group(let inner):
                drawGroup(inner, chain: m, in: ctx, groupFill: inherited, mirroredByGroups: mirrored, text: text)
            case .shape(var s):
                s.transform = split.scaled(s.transform)
                ctx.saveGState()
                ctx.concatenate(split.rest)
                drawShape(s, in: ctx, groupFill: inherited, mirroredByGroups: mirrored) { text(s, $0, $1) }
                ctx.restoreGState()
            case .picture(var p):
                p.transform = split.scaled(p.transform)
                ctx.saveGState()
                ctx.concatenate(split.rest)
                drawPicture(p, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: transform helpers

    /// Finite, in range (±1e8 pt) and not negative.
    static func finite(_ t: Transform2D) -> Bool {
        let vals = [t.offset.x, t.offset.y, t.extent.width, t.extent.height]
        return vals.allSatisfy { $0.isFinite && abs($0) <= 1e8 } && t.rotation.isFinite
            && t.extent.width >= 0 && t.extent.height >= 0
    }

    /// `finite` and with some extent (a line may have zero width or height, not both).
    static func usable(_ t: Transform2D) -> Bool {
        finite(t) && (t.extent.width > 0 || t.extent.height > 0)
    }

    static func finite(_ m: CGAffineTransform) -> Bool {
        [m.a, m.b, m.c, m.d, m.tx, m.ty].allSatisfy(\.isFinite)
    }

    // MARK: shadow

    /// Runs `body` inside a transparency layer that casts `shadow` (so fill and line cast one shadow).
    /// CG shadow offsets and blur are in base space and ignore the CTM, so the y-down page offset is
    /// mapped through the current CTM (which includes the caller's flip and zoom); the blur is scaled by the
    /// CTM's scale. This assumes base space = the space of `ctx.ctm` (true for bitmap and PDF contexts).
    private func withShadow(_ shadow: Shadow?, in ctx: CGContext, active: Bool, _ body: () -> Void) {
        guard active, let shadow, shadow.color.a > 0 else { body(); return }
        let m = ctx.ctm
        let o = shadow.offset
        let dev = CGSize(width: o.width * m.a + o.height * m.c, height: o.width * m.b + o.height * m.d)
        let scale = sqrt(abs(m.a * m.d - m.b * m.c))
        guard dev.width.isFinite, dev.height.isFinite, scale.isFinite else { body(); return }
        ctx.setShadow(offset: dev, blur: shadow.blur * scale, color: Self.cgColor(shadow.color))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
    }

    // MARK: fill

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    /// `a:path@fill` lighten/darken variants applied to a solid fill (other fills are kept).
    static func modulated(_ fill: Fill, _ mode: PathFillMode) -> Fill {
        guard case .solid(let c) = fill else { return fill }
        func scale(_ f: Double) -> Fill { .solid(RGBA(r: c.r * f, g: c.g * f, b: c.b * f, a: c.a)) }
        func tint(_ f: Double) -> Fill {
            .solid(RGBA(r: 1 - (1 - c.r) * f, g: 1 - (1 - c.g) * f, b: 1 - (1 - c.b) * f, a: c.a))
        }
        switch mode {
        case .norm, .none: return fill
        case .darken: return scale(0.6)
        case .darkenLess: return scale(0.8)
        case .lighten: return tint(0.6)
        case .lightenLess: return tint(0.8)
        }
    }

    /// Fills `path` (shape space) with `fill`; `bounds` is the shape box that gradients and images span.
    func drawFill(_ fill: Fill, path: CGPath, bounds: CGRect, in ctx: CGContext) {
        switch fill {
        case .none, .group:
            return
        case .solid(let c):
            ctx.addPath(path)
            ctx.setFillColor(Self.cgColor(c))
            ctx.fillPath()
        case .pattern(let fg, let bg, let preset):
            let k = FillResolver.patternCoverage(preset)
            let mix = RGBA(r: fg.r * k + bg.r * (1 - k), g: fg.g * k + bg.g * (1 - k),
                           b: fg.b * k + bg.b * (1 - k), a: fg.a * k + bg.a * (1 - k))
            drawFill(.solid(mix), path: path, bounds: bounds, in: ctx)
        case .gradient(let g):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            drawGradient(g, bounds: bounds, in: ctx)
            ctx.restoreGState()
        case .picture(let ref, let stretch, _):
            guard let decoded = decodedImage(ref, drawnIn: Self.imageRect(ref: ref, stretch: stretch, bounds: bounds),
                                             in: ctx) else { return }
            drawImage(decoded, ref: ref, stretch: stretch, clip: path, bounds: bounds, in: ctx)
        }
    }

    func drawGradient(_ g: Gradient, bounds: CGRect, in ctx: CGContext) {
        guard !g.stops.isEmpty, bounds.width > 0 || bounds.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let stops = g.stops.count == 1 ? [g.stops[0], GradientStop(position: 1, color: g.stops[0].color)] : g.stops
        var comps: [CGFloat] = []
        for s in stops { comps += [CGFloat(s.color.r), CGFloat(s.color.g), CGFloat(s.color.b), CGFloat(s.color.a)] }
        let locs = stops.map { CGFloat($0.position) }
        guard let grad = CGGradient(colorSpace: space, colorComponents: comps, locations: locs, count: locs.count)
        else { return }
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        if let kind = g.path {
            // Path gradients (circle; rect and shape approximated as circle): first stop at the focus
            // (centre of fillToRect), last stop at the farthest corner.
            let focusRect = (g.fillToRect ?? SrcRect(l: 0.5, t: 0.5, r: 0.5, b: 0.5)).inset(bounds)
            let c = CGPoint(x: focusRect.midX, y: focusRect.midY)
            let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                           CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            var radius = corners.map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 0
            if kind != .circle { radius = max(abs(c.x - bounds.minX), abs(bounds.maxX - c.x),
                                              abs(c.y - bounds.minY), abs(bounds.maxY - c.y)) }
            guard radius > 0, radius.isFinite else { return }
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: opts)
            return
        }

        // Linear: the gradient axis runs through the centre at `angle` (clockwise, y down) and spans the
        // projection of the box onto it. scaled: computed in a unit square stretched to the box.
        let a = (g.angle ?? 0) * .pi / 180
        let dir = CGPoint(x: cos(a), y: sin(a))
        var w = bounds.width, h = bounds.height
        ctx.saveGState()
        ctx.translateBy(x: bounds.minX, y: bounds.minY)
        if g.scaled, w > 0, h > 0 {
            ctx.scaleBy(x: w, y: h)
            w = 1; h = 1
        }
        let half = (w * abs(dir.x) + h * abs(dir.y)) / 2
        let c = CGPoint(x: w / 2, y: h / 2)
        let start = CGPoint(x: c.x - dir.x * half, y: c.y - dir.y * half)
        let end = CGPoint(x: c.x + dir.x * half, y: c.y + dir.y * half)
        if half > 0 {
            ctx.drawLinearGradient(grad, start: start, end: end, options: opts)
        }
        ctx.restoreGState()
    }

    // MARK: images

    /// Draws `decoded` into `bounds` (shape space) inset by `stretch`, cropped by `ref.srcRect` (the visible
    /// source region maps onto the target rect; negative values pad), clipped to `clip`.
    /// The rect the whole image is mapped onto: the target (bounds inset by `stretch`) extended by the crop, so
    /// that the visible source region lands on the target. nil if empty or not finite.
    static func imageRect(ref: ImageRef, stretch: SrcRect?, bounds: CGRect) -> CGRect? {
        let target = stretch?.inset(bounds) ?? bounds
        let crop = ref.srcRect ?? SrcRect()
        let visW = 1 - crop.l - crop.r, visH = 1 - crop.t - crop.b
        guard target.width > 0, target.height > 0, visW > 0, visH > 0 else { return nil }
        let full = CGRect(x: target.minX - crop.l / visW * target.width,
                          y: target.minY - crop.t / visH * target.height,
                          width: target.width / visW, height: target.height / visH)
        guard [full.minX, full.minY, full.width, full.height].allSatisfy({ $0.isFinite }) else { return nil }
        return full
    }

    /// The image for `ref`, decoded only as large as drawing it onto `rect` (user space; the crop-extended rect, so
    /// a crop raises the need by 1/(1−l−r) and 1/(1−t−b)) needs in a bitmap context: the device pixels per axis
    /// (CTM column lengths × rect), which the decoder turns into a long side that serves both axes and rounds up to
    /// a power of two. Other contexts (PDF, printing, layers) get the full image, so saved and printed slides keep
    /// the original resolution.
    func decodedImage(_ ref: ImageRef, drawnIn rect: CGRect?, in ctx: CGContext) -> DecodedImage? {
        guard ctx.width > 0, let rect else { return images.image(ref) }
        let m = ctx.ctm
        let px = CGSize(width: (rect.width * hypot(m.a, m.b)).rounded(.up),
                        height: (rect.height * hypot(m.c, m.d)).rounded(.up))
        guard px.width.isFinite, px.height.isFinite, px.width > 0, px.height > 0 else { return images.image(ref) }
        return images.image(ref, pixelSize: px)
    }

    func drawImage(_ decoded: DecodedImage, ref: ImageRef, stretch: SrcRect?, clip: CGPath, bounds: CGRect,
                   in ctx: CGContext) {
        guard let full = Self.imageRect(ref: ref, stretch: stretch, bounds: bounds), !clip.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        if let a = ref.alphaModFix { ctx.setAlpha(CGFloat(min(max(a, 0), 1))) }
        switch decoded {
        case .bitmap(let img):
            ctx.interpolationQuality = .high
            // CG draws images bottom-up in user space; under the y-down CTM flip them locally.
            ctx.translateBy(x: full.minX, y: full.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: full.size))
        case .vector(let m) where !ref.effects.isEmpty:
            // Recolour effects work on pixels: the metafile is rasterized at the device resolution of `full`
            // (bitmap contexts; 2 px/pt elsewhere, at most 4096 px a side), recoloured and drawn as a bitmap.
            // Sizes are clamped in floating point before Int conversion: a hostile crop makes `full` huge.
            guard full.width.isFinite, full.height.isFinite, full.width > 0, full.height > 0 else { break }
            let sx = ctx.width > 0 ? hypot(ctx.ctm.a, ctx.ctm.b) : 2, sy = ctx.width > 0 ? hypot(ctx.ctm.c, ctx.ctm.d) : 2
            let fw = (full.width * sx).rounded(.up), fh = (full.height * sy).rounded(.up)
            guard fw.isFinite, fh.isFinite else { break }
            let pw = Int(min(max(fw, 1), 4096)), ph = Int(min(max(fh, 1), 4096))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let bmp = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { break }
            bmp.translateBy(x: 0, y: CGFloat(ph))
            bmp.scaleBy(x: CGFloat(pw) / full.width, y: -CGFloat(ph) / full.height)
            m.draw(in: bmp, rect: CGRect(origin: .zero, size: full.size))
            guard let raster = bmp.makeImage(), let img = BlipEffect.apply(ref.effects, to: raster) else { break }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: full.minX, y: full.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: full.size))
        case .vector(let m):
            // The metafile's frame maps onto the (crop-extended) rect; it draws y-down itself. With
            // alphaModFix the overlapping vector parts are composited as one layer.
            if ref.alphaModFix != nil { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            m.draw(in: ctx, rect: full)
            if ref.alphaModFix != nil { ctx.endTransparencyLayer() }
        }
        ctx.restoreGState()
    }

    // MARK: lines

    func drawLine(_ line: Line, paths: [GeometryPath], in ctx: CGContext) {
        let stroked = paths.filter(\.stroke)
        guard !stroked.isEmpty, let color = Self.lineColor(line.fill) else { return }
        let w = max(line.width, 0)
        // Heads are sized from at least 2 pt so thin connectors get visible heads (guess, see decisions).
        let arrowSize = max(w, ArrowGeometry.minimumSizingWidth)

        // Arrowheads go on the first open sub-path; it is shortened so the line does not poke through.
        var firstOpen: (pathIndex: Int, sub: ArrowGeometry.SubPath)?
        if line.headEnd != nil || line.tailEnd != nil {
            outer: for (i, gp) in stroked.enumerated() {
                for sub in ArrowGeometry.subpaths(gp.path) where !sub.closed && sub.points.count >= 2 {
                    firstOpen = (i, sub); break outer
                }
            }
        }

        ctx.saveGState()
        ctx.setLineWidth(w)
        ctx.setLineCap(line.cap)
        ctx.setLineJoin(line.join)
        ctx.setMiterLimit(line.miterLimit)
        if let dash = line.dash, !dash.isEmpty, w > 0 {
            ctx.setLineDash(phase: 0, lengths: dash.map { max($0 * w, 0.01) })
        }
        for (i, gp) in stroked.enumerated() {
            var path = gp.path
            if let fo = firstOpen, fo.pathIndex == i {
                path = ArrowGeometry.shortened(gp.path, sub: fo.sub,
                                               head: line.headEnd.map { ArrowGeometry.setback($0, size: arrowSize, lineWidth: w) } ?? 0,
                                               tail: line.tailEnd.map { ArrowGeometry.setback($0, size: arrowSize, lineWidth: w) } ?? 0)
            }
            stroke(path, fill: line.fill, color: color, in: ctx)
        }
        ctx.restoreGState()

        guard let fo = firstOpen else { return }
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        if let head = line.headEnd, let (tip, from) = fo.sub.start {
            ArrowGeometry.draw(head, tip: tip, from: from, size: arrowSize, lineWidth: w, color: color, in: ctx)
        }
        if let tail = line.tailEnd, let (tip, from) = fo.sub.end {
            ArrowGeometry.draw(tail, tip: tip, from: from, size: arrowSize, lineWidth: w, color: color, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Strokes with a solid color, or — for gradient/picture line fills — clips to the stroke outline and
    /// fills that.
    private func stroke(_ path: CGPath, fill: Fill, color: RGBA, in ctx: CGContext) {
        switch fill {
        case .gradient, .picture:
            ctx.saveGState()
            ctx.addPath(path)
            ctx.replacePathWithStrokedPath()
            let outline = ctx.path ?? path
            let box = outline.boundingBoxOfPath
            drawFill(fill, path: outline, bounds: box, in: ctx)
            ctx.restoreGState()
        default:
            ctx.addPath(path)
            ctx.setStrokeColor(Self.cgColor(color))
            ctx.strokePath()
        }
    }

    /// A representative solid color of a line fill (arrowheads, plain strokes); nil = invisible.
    static func lineColor(_ fill: Fill) -> RGBA? {
        switch fill {
        case .solid(let c): return c
        case .gradient(let g): return g.stops.first?.color
        case .pattern(let fg, _, _): return fg
        case .picture: return RGBA(r: 0, g: 0, b: 0)
        case .none, .group: return nil
        }
    }
}

/// Arrowhead geometry (shape space).
enum ArrowGeometry {
    struct SubPath {
        var points: [CGPoint]   // all on-curve and control points in order
        var closed: Bool
        /// Tip at the start and the point the line arrives from (first distinct point after it).
        var start: (CGPoint, CGPoint)? {
            guard let tip = points.first, let from = points.dropFirst().first(where: { $0 != tip }) else { return nil }
            return (tip, from)
        }
        var end: (CGPoint, CGPoint)? {
            guard let tip = points.last, let from = points.dropLast().last(where: { $0 != tip }) else { return nil }
            return (tip, from)
        }
        /// Index of this sub-path's moveTo among the path's elements.
        var elementStart: Int
    }

    static func subpaths(_ path: CGPath) -> [SubPath] {
        var out: [SubPath] = []
        var current: SubPath?
        var index = 0
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                if let c = current { out.append(c) }
                current = SubPath(points: [e.points[0]], closed: false, elementStart: index)
            case .addLineToPoint:
                current?.points.append(e.points[0])
            case .addQuadCurveToPoint:
                current?.points += [e.points[0], e.points[1]]
            case .addCurveToPoint:
                current?.points += [e.points[0], e.points[1], e.points[2]]
            case .closeSubpath:
                current?.closed = true
            @unknown default:
                break
            }
            index += 1
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Line width from which head sizes are computed at least (thin lines would get invisible heads).
    static let minimumSizingWidth: CGFloat = 2

    /// How far the line end is pulled back from the tip. `size` = the width heads are sized from.
    static func setback(_ a: ArrowEnd, size: CGFloat, lineWidth: CGFloat) -> CGFloat {
        let len = a.length.factor * size
        switch a.kind {
        case .triangle: return len * 0.9
        case .stealth: return len * 0.5
        case .arrow: return lineWidth / 2
        case .diamond, .oval: return 0
        }
    }

    /// `path` with the start of `sub` moved `head` and its end moved `tail` towards the neighbouring point
    /// (never past it). Only the end points move; control points stay where they are.
    static func shortened(_ path: CGPath, sub: SubPath, head: CGFloat, tail: CGFloat) -> CGPath {
        guard head > 0 || tail > 0 else { return path }
        func pulled(_ tip: CGPoint, toward p: CGPoint, by d: CGFloat) -> CGPoint {
            let dx = p.x - tip.x, dy = p.y - tip.y
            let len = hypot(dx, dy)
            guard len > 0 else { return tip }
            let k = min(d, len * 0.95) / len
            return CGPoint(x: tip.x + dx * k, y: tip.y + dy * k)
        }
        var pts = sub.points
        if head > 0, let (tip, from) = sub.start { pts[0] = pulled(tip, toward: from, by: head) }
        if tail > 0, let (tip, from) = sub.end { pts[pts.count - 1] = pulled(tip, toward: from, by: tail) }

        let out = CGMutablePath()
        var index = 0
        var k = 0   // index into pts while inside `sub`
        let subEnd = sub.elementStart   // elements of `sub` follow its moveTo
        var inSub = false
        path.applyWithBlock { el in
            let e = el.pointee
            if index == subEnd { inSub = true }
            else if inSub, e.type == .moveToPoint { inSub = false }
            func p(_ i: Int) -> CGPoint {
                guard inSub, k < pts.count else { return e.points[i] }
                defer { k += 1 }
                return pts[k]
            }
            switch e.type {
            case .moveToPoint: out.move(to: p(0))
            case .addLineToPoint: out.addLine(to: p(0))
            case .addQuadCurveToPoint:
                let c = p(0); out.addQuadCurve(to: p(1), control: c)
            case .addCurveToPoint:
                let c1 = p(0), c2 = p(1); out.addCurve(to: p(2), control1: c1, control2: c2)
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
            index += 1
        }
        return out
    }

    /// Draws the head with its tip at `tip`, the line arriving from `from`. Sized from `size` (factor ×
    /// size); the open `arrow` is stroked with the line width (hairline 0 → 0.75 pt).
    static func draw(_ a: ArrowEnd, tip: CGPoint, from: CGPoint, size w: CGFloat, lineWidth: CGFloat,
                     color: RGBA, in ctx: CGContext) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = hypot(dx, dy)
        guard len > 0, len.isFinite else { return }
        let d = CGPoint(x: dx / len, y: dy / len)          // pointing out of the line
        let n = CGPoint(x: -d.y, y: d.x)
        let L = a.length.factor * w, W = a.width.factor * w
        func at(_ back: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - d.x * back + n.x * side, y: tip.y - d.y * back + n.y * side)
        }
        let cg = DrawingRenderer.cgColor(color)
        ctx.setFillColor(cg)
        ctx.setStrokeColor(cg)
        let p = CGMutablePath()
        switch a.kind {
        case .triangle:
            p.addLines(between: [tip, at(L, W / 2), at(L, -W / 2)]); p.closeSubpath()
        case .stealth:
            p.addLines(between: [tip, at(L, W / 2), at(L / 2, 0), at(L, -W / 2)]); p.closeSubpath()
        case .diamond:
            p.addLines(between: [at(-L / 2, 0), at(0, W / 2), at(L / 2, 0), at(0, -W / 2)]); p.closeSubpath()
        case .oval:
            let t = CGAffineTransform(a: d.x, b: d.y, c: n.x, d: n.y, tx: tip.x, ty: tip.y)
            p.addEllipse(in: CGRect(x: -L / 2, y: -W / 2, width: L, height: W), transform: t)
        case .arrow:
            p.addLines(between: [at(L, W / 2), tip, at(L, -W / 2)])
            ctx.addPath(p)
            ctx.setLineWidth(lineWidth > 0 ? lineWidth : LineResolver.defaultWidth)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
            return
        }
        ctx.addPath(p)
        ctx.fillPath()
    }
}
