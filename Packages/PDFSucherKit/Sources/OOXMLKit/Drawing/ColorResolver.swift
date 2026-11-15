// ColorResolver.swift — Task 3 (OOXMLKit)
// Resolves DrawingML color elements (srgbClr, schemeClr, sysClr, prstClr, hslClr, scrgbClr) with modifiers.
import Foundation

/// Maps the scheme names used in documents (bg1, tx1, bg2, tx2, accent1…6, hlink, folHlink) to theme slots
/// (dk1, lt1, dk2, lt2, accent1…6, hlink, folHlink).
///
/// - `ColorMap()` is the default (no `p:clrMap`): bg1→lt1, tx1→dk1, bg2→lt2, tx2→dk2, everything else identity.
/// - `init(xml:)` takes a `p:clrMap` (attributes bg1 tx1 bg2 tx2 accent1…6 hlink folHlink), or a `p:clrMapOvr`
///   (uses its `a:overrideClrMapping`; `a:masterClrMapping` gives the default map). Missing attributes keep the default.
/// - `init?(override:)` is for slide/layout `p:clrMapOvr`: returns nil for `a:masterClrMapping` (or nothing usable),
///   meaning "inherit": the caller keeps the master's map. Typical chain: `ColorMap(override: slideOvr) ?? layoutMap ?? masterMap`.
public struct ColorMap: Sendable, Equatable {
    public var mapping: [String: String]

    static let slotNames = ["bg1", "tx1", "bg2", "tx2", "accent1", "accent2", "accent3", "accent4",
                            "accent5", "accent6", "hlink", "folHlink"]

    static let defaultMapping: [String: String] = [
        "bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2",
        "accent1": "accent1", "accent2": "accent2", "accent3": "accent3", "accent4": "accent4",
        "accent5": "accent5", "accent6": "accent6", "hlink": "hlink", "folHlink": "folHlink",
    ]

    public init() { mapping = Self.defaultMapping }
    public init(mapping: [String: String]) { self.mapping = mapping }

    public init(xml: OOXMLNode?) {
        self.init()
        guard let xml else { return }
        if let map = Self.mapElement(xml) { apply(map) }
    }

    public init?(override: OOXMLNode) {
        guard let map = Self.mapElement(override), map.name != "masterClrMapping" else { return nil }
        self.init()
        apply(map)
    }

    private static func mapElement(_ n: OOXMLNode) -> OOXMLNode? {
        switch n.name {
        case "clrMap", "overrideClrMapping", "masterClrMapping": return n
        case "clrMapOvr": return n.child("overrideClrMapping") ?? n.child("masterClrMapping")
        default: return nil
        }
    }

    private mutating func apply(_ n: OOXMLNode) {
        for k in Self.slotNames { if let v = n.attr(k), !v.isEmpty { mapping[k] = v } }
    }

    /// Theme slot for a scheme name; unmapped names (dk1, lt1, …) are returned unchanged.
    public func map(_ scheme: String) -> String { mapping[scheme] ?? scheme }
}

public struct ColorContext: Sendable {
    public var theme: Theme
    public var map: ColorMap
    /// Replacement for `schemeClr val="phClr"` (the placeholder color of the referencing style).
    public var placeholderColor: RGBA?
    public init(theme: Theme, map: ColorMap = ColorMap(), placeholderColor: RGBA? = nil) {
        self.theme = theme; self.map = map; self.placeholderColor = placeholderColor
    }
}

public enum ColorResolver {
    public struct Resolution: Sendable, Equatable {
        public var color: RGBA
        /// True if `phClr` was used but `ColorContext.placeholderColor` was nil (black was substituted).
        public var placeholderMissing: Bool
    }

    /// `colorParent` is the element that holds the color (a:solidFill, a:fgClr, a:gs, …); its first child
    /// is resolved. Returns nil for no child, an unknown kind, an unknown scheme/preset name or bad values.
    public static func resolve(_ colorParent: OOXMLNode, in ctx: ColorContext) -> RGBA? {
        resolveDetailed(colorParent, in: ctx)?.color
    }

    public static func resolveDetailed(_ colorParent: OOXMLNode, in ctx: ColorContext) -> Resolution? {
        guard let el = colorParent.children.first else { return nil }
        var missing = false
        let base: RGBA?
        switch el.name {
        case "srgbClr":
            base = el.attr("val").flatMap { RGBA(hex: $0) }
        case "schemeClr":
            guard let v = el.attr("val") else { return nil }
            if v == "phClr" {
                if let p = ctx.placeholderColor { base = p } else { base = RGBA(r: 0, g: 0, b: 0); missing = true }
            } else {
                base = ctx.theme.colors[ctx.map.map(v)]
            }
        case "sysClr":
            if let hex = el.attr("lastClr"), let c = RGBA(hex: hex) { base = c }
            else { base = el.attr("val").flatMap { systemColors[$0] } }
        case "prstClr":
            base = el.attr("val").flatMap { presetColors[$0] }
        case "hslClr":
            guard let h = Double(el.attr("hue") ?? ""), let s = Units.parsePercentage(el.attr("sat")),
                  let l = Units.parsePercentage(el.attr("lum")) else { return nil }
            let (r, g, b) = hslToRGB(h: Units.degrees(fromAngle: h), s: clamp01(s), l: clamp01(l))
            base = RGBA(r: r, g: g, b: b)
        case "scrgbClr":
            guard let r = Units.parsePercentage(el.attr("r")), let g = Units.parsePercentage(el.attr("g")),
                  let b = Units.parsePercentage(el.attr("b")) else { return nil }
            base = RGBA(r: linearToSRGB(clamp01(r)), g: linearToSRGB(clamp01(g)), b: linearToSRGB(clamp01(b)))
        default:
            return nil
        }
        guard var color = base else { return nil }
        for m in el.children { apply(m, to: &color) }
        return Resolution(color: color, placeholderMissing: missing)
    }

    // MARK: modifiers

    /// Applied in document order. Formulas follow LibreOffice (oox/source/drawingml/color.cxx), whose
    /// results match PowerPoint's color picker for lumMod/lumOff (HSL) and tint/shade (linear RGB):
    /// - lumMod/lumOff/satMod/satOff/hueMod/hueOff/comp: HSL (comp = hue + 180°).
    /// - tint v: c' = 1 − (1 − c)·v and shade v: c' = c·v, per channel in linear RGB.
    /// - red/green/blue (+Mod/Off), gamma/invGamma: linear RGB; inv: sRGB 1 − c; gray: BT.601 luma of sRGB.
    /// - alpha sets, alphaMod multiplies, alphaOff adds. Unknown modifiers are ignored.
    private static func apply(_ m: OOXMLNode, to c: inout RGBA) {
        let v = Units.parsePercentage(m.attr("val"))
        switch m.name {
        case "alpha": if let v { c.a = clamp01(v) }
        case "alphaMod": if let v { c.a = clamp01(c.a * v) }
        case "alphaOff": if let v { c.a = clamp01(c.a + v) }
        case "lumMod": if let v { modifyHSL(&c) { $0.l = clamp01($0.l * v) } }
        case "lumOff": if let v { modifyHSL(&c) { $0.l = clamp01($0.l + v) } }
        case "satMod": if let v { modifyHSL(&c) { $0.s = clamp01($0.s * v) } }
        case "satOff": if let v { modifyHSL(&c) { $0.s = clamp01($0.s + v) } }
        case "hueMod": if let v { modifyHSL(&c) { $0.h = wrapHue($0.h * v) } }
        case "hueOff":
            if let raw = Double(m.attr("val") ?? "") {
                let d = Units.degrees(fromAngle: raw)
                modifyHSL(&c) { $0.h = wrapHue($0.h + d) }
            }
        case "comp": modifyHSL(&c) { $0.h = wrapHue($0.h + 180) }
        case "inv": c.r = 1 - c.r; c.g = 1 - c.g; c.b = 1 - c.b
        case "gray":
            let y = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
            c.r = y; c.g = y; c.b = y
        case "tint": if let v { modifyLinear(&c) { 1 - (1 - $0) * clamp01(v) } }
        case "shade": if let v { modifyLinear(&c) { $0 * clamp01(v) } }
        case "gamma":
            c.r = sRGBToLinear(c.r); c.g = sRGBToLinear(c.g); c.b = sRGBToLinear(c.b)
        case "invGamma":
            c.r = linearToSRGB(c.r); c.g = linearToSRGB(c.g); c.b = linearToSRGB(c.b)
        case "red": if let v { channel(&c, 0) { _ in clamp01(v) } }
        case "green": if let v { channel(&c, 1) { _ in clamp01(v) } }
        case "blue": if let v { channel(&c, 2) { _ in clamp01(v) } }
        case "redMod": if let v { channel(&c, 0) { $0 * v } }
        case "greenMod": if let v { channel(&c, 1) { $0 * v } }
        case "blueMod": if let v { channel(&c, 2) { $0 * v } }
        case "redOff": if let v { channel(&c, 0) { $0 + v } }
        case "greenOff": if let v { channel(&c, 1) { $0 + v } }
        case "blueOff": if let v { channel(&c, 2) { $0 + v } }
        default: break
        }
    }

    private static func modifyHSL(_ c: inout RGBA, _ f: (inout (h: Double, s: Double, l: Double)) -> Void) {
        var hsl = rgbToHSL(r: c.r, g: c.g, b: c.b)
        f(&hsl)
        let (r, g, b) = hslToRGB(h: hsl.h, s: hsl.s, l: hsl.l)
        c.r = r; c.g = g; c.b = b
    }

    private static func modifyLinear(_ c: inout RGBA, _ f: (Double) -> Double) {
        c.r = linearToSRGB(clamp01(f(sRGBToLinear(c.r))))
        c.g = linearToSRGB(clamp01(f(sRGBToLinear(c.g))))
        c.b = linearToSRGB(clamp01(f(sRGBToLinear(c.b))))
    }

    private static func channel(_ c: inout RGBA, _ i: Int, _ f: (Double) -> Double) {
        var lin = [sRGBToLinear(c.r), sRGBToLinear(c.g), sRGBToLinear(c.b)]
        lin[i] = clamp01(f(lin[i]))
        c.r = linearToSRGB(lin[0]); c.g = linearToSRGB(lin[1]); c.b = linearToSRGB(lin[2])
    }

    // MARK: color math

    static func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
    static func wrapHue(_ h: Double) -> Double {
        guard h.isFinite else { return 0 }
        let r = h.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    static func sRGBToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        if d == 0 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hh = wrapHue(h) / 360
        func comp(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (comp(hh + 1.0 / 3), comp(hh), comp(hh - 1.0 / 3))
    }

    // MARK: named colors

    static let systemColors: [String: RGBA] = [
        "windowText": RGBA(hex: "000000")!, "window": RGBA(hex: "FFFFFF")!,
        "menuText": RGBA(hex: "000000")!, "menu": RGBA(hex: "FFFFFF")!,
        "btnFace": RGBA(hex: "F0F0F0")!, "btnText": RGBA(hex: "000000")!,
        "highlight": RGBA(hex: "3399FF")!, "highlightText": RGBA(hex: "FFFFFF")!,
        "grayText": RGBA(hex: "808080")!, "captionText": RGBA(hex: "000000")!,
    ]

    /// Common ST_PresetColorVal names (CSS-like values; dk*/lt* follow LibreOffice). Unknown → nil.
    static let presetColors: [String: RGBA] = {
        let table: [String: String] = [
            "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
            "yellow": "FFFF00", "cyan": "00FFFF", "aqua": "00FFFF", "magenta": "FF00FF", "fuchsia": "FF00FF",
            "gray": "808080", "grey": "808080", "darkGray": "A9A9A9", "darkGrey": "A9A9A9",
            "lightGray": "D3D3D3", "lightGrey": "D3D3D3", "dkGray": "A9A9A9", "ltGray": "D3D3D3",
            "dimGray": "696969", "silver": "C0C0C0", "orange": "FFA500", "lime": "00FF00",
            "maroon": "800000", "purple": "800080", "olive": "808000", "navy": "000080", "teal": "008080",
            "brown": "A52A2A", "pink": "FFC0CB", "gold": "FFD700", "violet": "EE82EE", "indigo": "4B0082",
            "darkRed": "8B0000", "darkGreen": "006400", "darkBlue": "00008B", "darkCyan": "008B8B",
            "darkMagenta": "8B008B", "darkYellow": "808000",
            "dkRed": "8B0000", "dkGreen": "006400", "dkBlue": "00008B", "dkCyan": "008B8B",
            "dkMagenta": "8B008B", "dkYellow": "808000",
            "lightBlue": "ADD8E6", "lightGreen": "90EE90", "lightYellow": "FFFFE0", "lightCyan": "E0FFFF",
            "lightPink": "FFB6C1", "ltBlue": "ADD8E6", "ltGreen": "90EE90", "ltYellow": "FFFFE0",
            "ltCyan": "E0FFFF", "ltPink": "FFB6C1",
            "orangeRed": "FF4500", "crimson": "DC143C", "coral": "FF7F50", "tomato": "FF6347",
            "salmon": "FA8072", "khaki": "F0E68C", "beige": "F5F5DC", "ivory": "FFFFF0", "tan": "D2B48C",
            "turquoise": "40E0D0", "skyBlue": "87CEEB", "royalBlue": "4169E1", "steelBlue": "4682B4",
            "forestGreen": "228B22", "limeGreen": "32CD32", "seaGreen": "2E8B57", "chocolate": "D2691E",
            "sienna": "A0522D", "plum": "DDA0DD", "orchid": "DA70D6", "lavender": "E6E6FA",
        ]
        return table.reduce(into: [:]) { $0[$1.key] = RGBA(hex: $1.value) }
    }()
}
