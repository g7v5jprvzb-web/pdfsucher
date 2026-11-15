// FillLineResolver.swift — Task 6 (OOXMLKit)
// XML → Fill / Line / Shadow. Explicit spPr values win; otherwise the `p:style` references (fillRef, lnRef,
// effectRef) pick a theme format-scheme entry whose `phClr` is the reference's own color child.
import CoreGraphics
import Foundation

public enum FillResolver {
    static let fillNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    /// Fill of a shape: the explicit fill in `spPr`, else `style`'s `a:fillRef`, else `.none`.
    /// `style` is the `p:style` (or `wps:style`) element. `part` resolves blip fills (nil → blip fill = none).
    public static func fill(_ spPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext,
                            part: PartContext? = nil) -> Fill {
        if let spPr, let f = explicitFill(spPr, colors: colors, part: part) { return f }
        if let ref = style?.child("fillRef") { return styleFill(ref, colors: colors) }
        return .none
    }

    /// The first fill child of `parent` (spPr, grpSpPr, bg:bgPr, a:tcPr …), nil if it has none.
    public static func explicitFill(_ parent: OOXMLNode, colors: ColorContext, part: PartContext? = nil) -> Fill? {
        guard let el = parent.children.first(where: { fillNames.contains($0.name) }) else { return nil }
        return fill(element: el, colors: colors, part: part)
    }

    /// One fill element (`a:solidFill`, `a:gradFill`, …). Unknown elements, unresolvable colors and gradients
    /// without stops → `.none`.
    public static func fill(element el: OOXMLNode, colors: ColorContext, part: PartContext? = nil) -> Fill {
        switch el.name {
        case "solidFill":
            return ColorResolver.resolve(el, in: colors).map(Fill.solid) ?? .none
        case "gradFill":
            return gradient(el, colors: colors)
        case "blipFill":
            guard let part, let ref = ImageRef(blipFill: el, in: part, colors: colors) else { return .none }
            let (stretch, tile) = blipMode(el)
            return .picture(ref, stretch: stretch, tile: tile)
        case "pattFill":
            let fg = el.child("fgClr").flatMap { ColorResolver.resolve($0, in: colors) } ?? RGBA(r: 0, g: 0, b: 0)
            let bg = el.child("bgClr").flatMap { ColorResolver.resolve($0, in: colors) } ?? RGBA(r: 1, g: 1, b: 1)
            return .pattern(fg: fg, bg: bg, preset: el.attr("prst") ?? "pct5")
        case "grpFill":
            return .group
        default:
            return .none
        }
    }

    /// `a:fillRef idx`: 0 = no fill, 1…999 → theme fillStyleLst[idx−1], ≥1001 → bgFillStyleLst[idx−1001].
    /// Out of range → `.none`. Theme blip fills are not resolved (their rels belong to the theme part).
    static func styleFill(_ ref: OOXMLNode, colors: ColorContext) -> Fill {
        guard let entry = styleEntry(ref, fill: colors.theme.fillStyles, bg: colors.theme.bgFillStyles) else { return .none }
        return fill(element: entry, colors: placeholderContext(ref, colors))
    }

    static func styleEntry(_ ref: OOXMLNode, fill: [OOXMLNode], bg: [OOXMLNode] = []) -> OOXMLNode? {
        guard let idx = ref.attr("idx").flatMap({ Int($0) }), idx > 0 else { return nil }
        if idx >= 1001 { return bg.indices.contains(idx - 1001) ? bg[idx - 1001] : nil }
        return fill.indices.contains(idx - 1) ? fill[idx - 1] : nil
    }

    /// `colors` with `phClr` = the reference element's own color child (unchanged if it has none).
    static func placeholderContext(_ ref: OOXMLNode, _ colors: ColorContext) -> ColorContext {
        var ctx = colors
        if let c = ColorResolver.resolve(ref, in: colors) { ctx.placeholderColor = c }
        return ctx
    }

    static func gradient(_ el: OOXMLNode, colors: ColorContext) -> Fill {
        var stops: [GradientStop] = []
        for gs in el.child("gsLst")?.children("gs") ?? [] {
            guard let c = ColorResolver.resolve(gs, in: colors) else { continue }
            let pos = Units.parsePercentage(gs.attr("pos")) ?? 0
            stops.append(GradientStop(position: min(max(pos, 0), 1), color: c))
        }
        if stops.isEmpty { return .none }
        if let path = el.child("path") {
            return .gradient(Gradient(stops: stops, path: GradientPath(rawValue: path.attr("path") ?? "") ?? .shape,
                                      fillToRect: SrcRect(xml: path.child("fillToRect"))))
        }
        let lin = el.child("lin")
        let ang = lin?.attr("ang").flatMap(Double.init).flatMap { $0.isFinite ? Units.degrees(fromAngle: $0) : nil } ?? 0
        return .gradient(Gradient(stops: stops, angle: ang, scaled: Transform2D.bool(lin?.attr("scaled"))))
    }

    /// `a:stretch/a:fillRect` insets (nil when absent or all zero) and whether `a:tile` is set.
    static func blipMode(_ blipFill: OOXMLNode) -> (SrcRect?, Bool) {
        if blipFill.child("tile") != nil { return (nil, true) }
        return (SrcRect(xml: blipFill.child("stretch")?.child("fillRect")), false)
    }

    /// Share of foreground ink of an `a:pattFill` preset (for the blend approximation).
    static func patternCoverage(_ preset: String) -> Double {
        if preset.hasPrefix("pct"), let n = Double(preset.dropFirst(3)) { return min(max(n / 100, 0), 1) }
        if preset.hasPrefix("dk") || preset.hasPrefix("wd") || preset == "solidDmnd" { return 0.5 }
        return 0.33
    }
}

public enum LineResolver {
    /// Default line width when neither spPr nor the theme gives `w` (PowerPoint's 0.75 pt).
    static let defaultWidth: CGFloat = 0.75

    static let presetDashes: [String: [CGFloat]] = [
        "dot": [1, 3], "dash": [4, 3], "lgDash": [8, 3], "dashDot": [4, 3, 1, 3],
        "lgDashDot": [8, 3, 1, 3], "lgDashDotDot": [8, 3, 1, 3, 1, 3],
        "sysDash": [3, 1], "sysDot": [1, 1], "sysDashDot": [3, 1, 1, 1], "sysDashDotDot": [3, 1, 1, 1, 1, 1],
    ]

    /// Collected `a:ln` properties; later `apply` calls override earlier ones property by property.
    struct Props {
        var width: CGFloat?
        var fill: Fill?
        var dash: [CGFloat]??
        var cap: CGLineCap?
        var join: (CGLineJoin, CGFloat)?
        var head: ArrowEnd??
        var tail: ArrowEnd??
    }

    /// The theme line style of `style`'s `a:lnRef` (phClr = its color) overlaid with `spPr`'s `a:ln`.
    /// nil when the result has no visible fill (no fill anywhere, `a:noFill`, or `lnRef idx="0"` without ln fill).
    public static func line(_ spPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext) -> Line? {
        var p = Props()
        if let ref = style?.child("lnRef"), let entry = FillResolver.styleEntry(ref, fill: colors.theme.lineStyles) {
            apply(entry, to: &p, colors: FillResolver.placeholderContext(ref, colors))
        }
        if let ln = spPr?.child("ln") { apply(ln, to: &p, colors: colors) }
        guard let fill = p.fill, fill != .none else { return nil }
        let join = p.join ?? (.round, 8)
        return Line(width: p.width ?? defaultWidth, fill: fill, dash: p.dash ?? nil, cap: p.cap ?? .butt,
                    join: join.0, miterLimit: join.1, headEnd: p.head ?? nil, tailEnd: p.tail ?? nil)
    }

    static func apply(_ ln: OOXMLNode, to p: inout Props, colors: ColorContext) {
        if let w = ln.attr("w").flatMap(Double.init), w.isFinite, w >= 0 {
            p.width = CGFloat(min(Units.points(fromEMU: w), 1000))
        }
        switch ln.attr("cap") {
        case "rnd": p.cap = .round
        case "sq": p.cap = .square
        case "flat": p.cap = .butt
        default: break
        }
        for c in ln.children {
            switch c.name {
            case "noFill", "solidFill", "gradFill", "pattFill":
                p.fill = FillResolver.fill(element: c, colors: colors)
            case "prstDash":
                let v = c.attr("val") ?? "solid"
                p.dash = .some(presetDashes[v])
            case "custDash":
                let d = c.children("ds").flatMap { ds -> [CGFloat] in
                    let on = Units.parsePercentage(ds.attr("d")) ?? 0, off = Units.parsePercentage(ds.attr("sp")) ?? 0
                    return [CGFloat(min(max(on, 0), 1000)), CGFloat(min(max(off, 0), 1000))]
                }
                p.dash = .some(d.contains { $0 > 0 } ? d : nil)
            case "round": p.join = (.round, 8)
            case "bevel": p.join = (.bevel, 8)
            case "miter":
                let lim = Units.parsePercentage(c.attr("lim")).map { CGFloat(min(max($0, 1), 100)) } ?? 8
                p.join = (.miter, lim)
            case "headEnd": p.head = .some(arrow(c))
            case "tailEnd": p.tail = .some(arrow(c))
            default: break
            }
        }
    }

    static func arrow(_ el: OOXMLNode) -> ArrowEnd? {
        guard let kind = ArrowKind(rawValue: el.attr("type") ?? "none") else { return nil }
        return ArrowEnd(kind: kind, width: ArrowSize(rawValue: el.attr("w") ?? "") ?? .med,
                        length: ArrowSize(rawValue: el.attr("len") ?? "") ?? .med)
    }
}

public enum EffectResolver {
    /// The `a:outerShdw` of `spPr`'s `a:effectLst`, or (if spPr has no effectLst/effectDag) of the theme
    /// effect style that `style`'s `a:effectRef` selects (phClr = its color). Other effects are ignored.
    public static func shadow(_ spPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext) -> Shadow? {
        if let lst = spPr?.child("effectLst") { return outerShadow(lst, colors: colors) }
        if spPr?.child("effectDag") != nil { return nil }
        guard let ref = style?.child("effectRef"),
              let entry = FillResolver.styleEntry(ref, fill: colors.theme.effectStyles),
              let lst = entry.child("effectLst") else { return nil }
        return outerShadow(lst, colors: FillResolver.placeholderContext(ref, colors))
    }

    static func outerShadow(_ lst: OOXMLNode, colors: ColorContext) -> Shadow? {
        guard let s = lst.child("outerShdw"), let color = ColorResolver.resolve(s, in: colors) else { return nil }
        func emu(_ k: String) -> CGFloat {
            guard let v = s.attr(k).flatMap(Double.init), v.isFinite, v > 0 else { return 0 }
            return CGFloat(min(Units.points(fromEMU: v), 1000))
        }
        let dir = s.attr("dir").flatMap(Double.init).flatMap { $0.isFinite ? Units.degrees(fromAngle: $0) : nil } ?? 0
        return Shadow(color: color, blur: emu("blurRad"), distance: emu("dist"), direction: dir)
    }
}
