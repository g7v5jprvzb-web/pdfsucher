// ShapeModel.swift — Task 6 (OOXMLKit)
// Resolved, renderer-ready DrawingML values: transform, fill, line, shadow, and the shape / picture / group
// models that DrawingRenderer draws. Shared by SlideKit and WordKit. The resolvers (XML → values) live in
// FillLineResolver.swift.
//
// Coordinate convention: everything is in points, origin top left, y down. A shape's own space is
// (0, 0)…(extent.width, extent.height); `Transform2D.affine` maps it into the parent space (slide or group
// child space). Angles are in degrees, clockwise (as seen with y down).
import CoreGraphics
import Foundation

// MARK: - Transform

/// `a:xfrm` / `p:xfrm` in points.
public struct Transform2D: Sendable, Equatable {
    public var offset: CGPoint
    public var extent: CGSize
    /// Degrees clockwise about the centre.
    public var rotation: Double
    public var flipH: Bool
    public var flipV: Bool
    /// Group only (`a:chOff` / `a:chExt`): the child coordinate space that maps onto offset/extent.
    public var childOffset: CGPoint?
    public var childExtent: CGSize?

    public init(offset: CGPoint = .zero, extent: CGSize = .zero, rotation: Double = 0,
                flipH: Bool = false, flipV: Bool = false,
                childOffset: CGPoint? = nil, childExtent: CGSize? = nil) {
        self.offset = offset; self.extent = extent; self.rotation = rotation
        self.flipH = flipH; self.flipV = flipV
        self.childOffset = childOffset; self.childExtent = childExtent
    }

    /// Reads `a:xfrm` (EMU → points, rot in 60000ths of a degree). Missing or unparseable values → 0;
    /// negative extents → 0; values are clamped to ±1e8 pt.
    public init(xfrm: OOXMLNode?) {
        self.init()
        guard let xfrm else { return }
        func emu(_ n: OOXMLNode?, _ k: String) -> CGFloat? {
            guard let s = n?.attr(k), let v = Double(s), v.isFinite else { return nil }
            return CGFloat(min(max(Units.points(fromEMU: v), -Self.limit), Self.limit))
        }
        func point(_ n: OOXMLNode?) -> CGPoint { CGPoint(x: emu(n, "x") ?? 0, y: emu(n, "y") ?? 0) }
        func size(_ n: OOXMLNode?) -> CGSize {
            CGSize(width: max(0, emu(n, "cx") ?? 0), height: max(0, emu(n, "cy") ?? 0))
        }
        offset = point(xfrm.child("off"))
        extent = size(xfrm.child("ext"))
        if let r = xfrm.attr("rot").flatMap(Double.init), r.isFinite {
            rotation = Units.degrees(fromAngle: r).truncatingRemainder(dividingBy: 360)
        }
        flipH = Self.bool(xfrm.attr("flipH"))
        flipV = Self.bool(xfrm.attr("flipV"))
        if let n = xfrm.child("chOff") { childOffset = point(n) }
        if let n = xfrm.child("chExt") { childExtent = size(n) }
    }

    static let limit = 1.0e8

    static func bool(_ s: String?) -> Bool { s == "1" || s == "true" }

    public var frame: CGRect { CGRect(origin: offset, size: extent) }

    /// Shape space (0…w, 0…h) → parent space: flip and rotate about the centre, then move to `offset`.
    public var affine: CGAffineTransform {
        let cx = extent.width / 2, cy = extent.height / 2
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: flipH ? -1 : 1, y: flipV ? -1 : 1))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: offset.x + cx, y: offset.y + cy))
    }

    /// Like `affine` but without flips; with flipV the text is turned by 180° instead (PowerPoint never
    /// mirrors text).
    var textAffine: CGAffineTransform {
        var t = self
        t.flipH = false; t.flipV = false
        if flipV { t.rotation += 180 }
        return t.affine
    }

    /// Group child space → parent space: childOffset/childExtent are scaled onto the group's shape space,
    /// then `affine` applies. A missing or zero child extent maps 1:1.
    public var childToParent: CGAffineTransform {
        let co = childOffset ?? offset
        let ce = childExtent ?? extent
        let sx = ce.width > 0 ? extent.width / ce.width : 1
        let sy = ce.height > 0 ? extent.height / ce.height : 1
        return CGAffineTransform(translationX: -co.x, y: -co.y)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(affine)
    }
}

/// A chain of group transforms (child space → the space the outermost group sits in) split into a per-axis scale S
/// and the rest R, so that M = S · R (CG's row-vector order: a point is scaled first). PowerPoint applies a group's
/// scaling to its children's boxes only: line widths, arrowheads, preset geometry (corner radii) and text keep their
/// absolute sizes. So a child is drawn with its box scaled by S (`scaled`) under R, never stretched by M.
/// Exact for groups without rotation; a rotated child inside a non-uniformly scaled group is not skewed
/// (approximation, as for text).
public struct GroupScale: Sendable, Equatable {
    public let scale: CGSize
    public let rest: CGAffineTransform

    /// nil if M is not finite. An axis may collapse (scale 0, e.g. a group of horizontal lines saved with ext
    /// cy = 0): its unit column in R is then the other column turned by 90° (or the identity's when both are 0),
    /// so R stays orthonormal and finite and the children are drawn with a flat box (lines still show).
    public init?(_ m: CGAffineTransform) {
        let sx = hypot(m.a, m.b), sy = hypot(m.c, m.d)
        guard sx.isFinite, sy.isFinite, m.tx.isFinite, m.ty.isFinite else { return nil }
        scale = CGSize(width: sx, height: sy)
        var x = sx > 0 ? CGPoint(x: m.a / sx, y: m.b / sx) : nil
        var y = sy > 0 ? CGPoint(x: m.c / sy, y: m.d / sy) : nil
        if x == nil, let v = y { x = CGPoint(x: v.y, y: -v.x) }
        if y == nil, let v = x { y = CGPoint(x: -v.y, y: v.x) }
        let ux = x ?? CGPoint(x: 1, y: 0), uy = y ?? CGPoint(x: 0, y: 1)
        rest = CGAffineTransform(a: ux.x, b: ux.y, c: uy.x, d: uy.y, tx: m.tx, ty: m.ty)
    }

    /// `t` with its box scaled by S (rotation and flips unchanged): the centre is scaled by S, the extent by S in
    /// the box's visual orientation, i.e. with the two scale factors swapped for rotations of 45°…135° (mod 180°),
    /// as PowerPoint does for a shape turned upright inside a stretched group.
    public func scaled(_ t: Transform2D) -> Transform2D {
        var r = t.rotation.truncatingRemainder(dividingBy: 180)
        if r < 0 { r += 180 }
        let upright = r >= 45 && r < 135
        let ex = upright ? scale.height : scale.width, ey = upright ? scale.width : scale.height
        let centre = CGPoint(x: (t.offset.x + t.extent.width / 2) * scale.width,
                             y: (t.offset.y + t.extent.height / 2) * scale.height)
        var out = t
        out.extent = CGSize(width: t.extent.width * ex, height: t.extent.height * ey)
        out.offset = CGPoint(x: centre.x - out.extent.width / 2, y: centre.y - out.extent.height / 2)
        return out
    }
}

// MARK: - Fill

public struct GradientStop: Sendable, Equatable {
    /// 0…1.
    public var position: Double
    public var color: RGBA
    public init(position: Double, color: RGBA) { self.position = position; self.color = color }
}

/// `a:path@path` of a path gradient.
public enum GradientPath: String, Sendable, Equatable {
    case circle, rect, shape
}

public struct Gradient: Sendable, Equatable {
    /// Sorted by position.
    public var stops: [GradientStop]
    /// `a:lin ang` in degrees clockwise (0 = left → right); used when `path` is nil.
    public var angle: Double?
    /// `a:lin scaled`: the angle is applied in a unit square that is then stretched to the shape.
    public var scaled: Bool
    /// Path gradient kind; nil = linear.
    public var path: GradientPath?
    /// `a:fillToRect` of a path gradient: the focus rectangle as insets (nil = the whole shape).
    public var fillToRect: SrcRect?

    public init(stops: [GradientStop], angle: Double? = nil, scaled: Bool = false,
                path: GradientPath? = nil, fillToRect: SrcRect? = nil) {
        self.stops = stops.sorted { $0.position < $1.position }
        self.angle = angle; self.scaled = scaled; self.path = path; self.fillToRect = fillToRect
    }
}

public enum Fill: Sendable, Equatable {
    case none
    case solid(RGBA)
    case gradient(Gradient)
    /// Blip fill. `stretch` = `a:stretch/a:fillRect` insets (nil = fill the bounds); `tile` = `a:tile`
    /// (drawn stretched, see decisions).
    case picture(ImageRef, stretch: SrcRect?, tile: Bool)
    /// `a:pattFill`; drawn as a blend of fg and bg weighted by the preset's ink coverage.
    case pattern(fg: RGBA, bg: RGBA, preset: String)
    /// `a:grpFill`: the fill of the enclosing group.
    case group
}

// MARK: - Line

public enum ArrowKind: String, Sendable, Equatable {
    case triangle, stealth, diamond, oval, arrow
}

public enum ArrowSize: String, Sendable, Equatable {
    case sm, med, lg

    /// Multiple of the sizing width, max(line width, 2 pt).
    var factor: CGFloat {
        switch self {
        case .sm: return 2
        case .med: return 3
        case .lg: return 5
        }
    }
}

/// `a:headEnd` / `a:tailEnd`.
public struct ArrowEnd: Sendable, Equatable {
    public var kind: ArrowKind
    public var width: ArrowSize
    public var length: ArrowSize
    public init(kind: ArrowKind, width: ArrowSize = .med, length: ArrowSize = .med) {
        self.kind = kind; self.width = width; self.length = length
    }
}

/// Resolved `a:ln`.
public struct Line: Sendable, Equatable {
    /// Points; 0 = device hairline.
    public var width: CGFloat
    /// Usually solid; gradient/picture fills are drawn inside the stroke outline, pattern as its foreground.
    public var fill: Fill
    /// Dash/gap lengths as multiples of the width; nil = solid.
    public var dash: [CGFloat]?
    public var cap: CGLineCap
    public var join: CGLineJoin
    public var miterLimit: CGFloat
    /// At the start of the first open sub-path.
    public var headEnd: ArrowEnd?
    /// At the end of the first open sub-path.
    public var tailEnd: ArrowEnd?

    public init(width: CGFloat, fill: Fill, dash: [CGFloat]? = nil, cap: CGLineCap = .butt,
                join: CGLineJoin = .round, miterLimit: CGFloat = 8,
                headEnd: ArrowEnd? = nil, tailEnd: ArrowEnd? = nil) {
        self.width = width; self.fill = fill; self.dash = dash; self.cap = cap; self.join = join
        self.miterLimit = miterLimit; self.headEnd = headEnd; self.tailEnd = tailEnd
    }
}

// MARK: - Shadow

/// `a:outerShdw` (the only effect drawn).
public struct Shadow: Sendable, Equatable {
    public var color: RGBA
    /// Blur radius in points.
    public var blur: CGFloat
    /// Distance in points.
    public var distance: CGFloat
    /// Degrees clockwise from +x (90 = straight down).
    public var direction: Double

    public init(color: RGBA, blur: CGFloat, distance: CGFloat, direction: Double) {
        self.color = color; self.blur = blur; self.distance = distance; self.direction = direction
    }

    /// Offset in y-down page space.
    public var offset: CGSize {
        let a = direction * .pi / 180
        return CGSize(width: distance * CGFloat(cos(a)), height: distance * CGFloat(sin(a)))
    }
}

// MARK: - Models

/// A shape (`p:sp`, `p:cxnSp`, `wps:wsp`) without its text.
public struct ShapeModel: Sendable {
    public var transform: Transform2D
    /// nil = rectangle.
    public var geometry: Geometry?
    public var fill: Fill
    public var line: Line?
    public var shadow: Shadow?
    /// Free for the caller (e.g. an index into its own text bodies); passed back in group text callbacks.
    public var tag: Int?

    public init(transform: Transform2D, geometry: Geometry? = nil, fill: Fill = .none, line: Line? = nil,
                shadow: Shadow? = nil, tag: Int? = nil) {
        self.transform = transform; self.geometry = geometry; self.fill = fill
        self.line = line; self.shadow = shadow; self.tag = tag
    }

    /// Resolves `spPr` (xfrm, geometry, fill, ln, effectLst) with the `p:style` references as fallback.
    /// `part` is needed for blip fills only.
    public init(spPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext, part: PartContext? = nil) {
        self.init(transform: Transform2D(xfrm: spPr?.child("xfrm")),
                  geometry: GeometryBuilder.geometry(from: spPr),
                  fill: FillResolver.fill(spPr, style: style, colors: colors, part: part),
                  line: LineResolver.line(spPr, style: style, colors: colors),
                  shadow: EffectResolver.shadow(spPr, style: style, colors: colors))
    }

    /// Geometry paths at the shape's size, in shape space.
    public func geometryPaths() -> GeometryPaths {
        GeometryBuilder.paths(geometry ?? .preset("rect", adjust: [:]), size: transform.extent)
    }

    /// Text rectangle in shape space: the geometry's `a:rect`, else the bounds.
    public var textRect: CGRect {
        geometryPaths().textRect ?? CGRect(origin: .zero, size: transform.extent)
    }
}

/// A picture (`p:pic`, `pic:pic`).
public struct PictureModel: Sendable {
    public var transform: Transform2D
    /// Clip geometry; nil = rectangle.
    public var geometry: Geometry?
    /// nil if the blip could not be resolved: nothing is drawn (but the line is).
    public var image: ImageRef?
    /// `a:stretch/a:fillRect` insets; nil = the bounds.
    public var stretch: SrcRect?
    public var tile: Bool
    public var line: Line?
    public var shadow: Shadow?

    public init(transform: Transform2D, geometry: Geometry? = nil, image: ImageRef?, stretch: SrcRect? = nil,
                tile: Bool = false, line: Line? = nil, shadow: Shadow? = nil) {
        self.transform = transform; self.geometry = geometry; self.image = image
        self.stretch = stretch; self.tile = tile; self.line = line; self.shadow = shadow
    }

    /// `blipFill` is the picture's `p:blipFill` / `pic:blipFill`; `spPr` its shape properties.
    public init(blipFill: OOXMLNode?, spPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext, part: PartContext) {
        let (stretch, tile) = blipFill.map(FillResolver.blipMode) ?? (nil, false)
        self.init(transform: Transform2D(xfrm: spPr?.child("xfrm")),
                  geometry: GeometryBuilder.geometry(from: spPr),
                  image: blipFill.flatMap { ImageRef(blipFill: $0, in: part, colors: colors) },
                  stretch: stretch, tile: tile,
                  line: LineResolver.line(spPr, style: style, colors: colors),
                  shadow: EffectResolver.shadow(spPr, style: style, colors: colors))
    }
}

/// A group (`p:grpSp`, `wpg:wgp`).
public struct GroupModel: Sendable {
    public var transform: Transform2D
    /// The group's own fill for `grpFill` children; `.group` = inherit from the enclosing group.
    public var fill: Fill
    public var children: [DrawingElement]

    public init(transform: Transform2D, fill: Fill = .group, children: [DrawingElement]) {
        self.transform = transform; self.fill = fill; self.children = children
    }

    /// Reads `grpSpPr` (xfrm with chOff/chExt, fill). A group without a fill inherits (`.group`).
    public init(grpSpPr: OOXMLNode?, colors: ColorContext, part: PartContext? = nil, children: [DrawingElement]) {
        let explicit = grpSpPr.flatMap { FillResolver.explicitFill($0, colors: colors, part: part) }
        self.init(transform: Transform2D(xfrm: grpSpPr?.child("xfrm")), fill: explicit ?? .group, children: children)
    }
}

public indirect enum DrawingElement: Sendable {
    case shape(ShapeModel)
    case picture(PictureModel)
    case group(GroupModel)
}
