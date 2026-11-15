// Theme.swift — Task 3 (OOXMLKit)
// DrawingML theme (a:theme): color scheme, font scheme, format scheme lists.
import Foundation

/// Non-premultiplied sRGB color, components 0…1.
public struct RGBA: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    /// "RRGGBB" (optional leading "#"); nil if not exactly six hex digits.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                  b: Double(v & 0xFF) / 255, a: 1)
    }
}

public struct Theme: Sendable {
    /// Keys: dk1 lt1 dk2 lt2 accent1…accent6 hlink folHlink.
    public var colors: [String: RGBA]
    public var majorLatin: String
    public var minorLatin: String
    public var majorEA: String
    public var minorEA: String
    /// Per-script font overrides (`a:font script="Jpan" typeface="…"`) of majorFont / minorFont.
    public var majorScripts: [String: String]
    public var minorScripts: [String: String]
    public var fillStyles: [OOXMLNode]
    public var bgFillStyles: [OOXMLNode]
    public var lineStyles: [OOXMLNode]
    public var effectStyles: [OOXMLNode]

    public init(colors: [String: RGBA], majorLatin: String, minorLatin: String,
                majorEA: String = "", minorEA: String = "",
                majorScripts: [String: String] = [:], minorScripts: [String: String] = [:],
                fillStyles: [OOXMLNode] = [], bgFillStyles: [OOXMLNode] = [],
                lineStyles: [OOXMLNode] = [], effectStyles: [OOXMLNode] = []) {
        self.colors = colors
        self.majorLatin = majorLatin; self.minorLatin = minorLatin
        self.majorEA = majorEA; self.minorEA = minorEA
        self.majorScripts = majorScripts; self.minorScripts = minorScripts
        self.fillStyles = fillStyles; self.bgFillStyles = bgFillStyles
        self.lineStyles = lineStyles; self.effectStyles = effectStyles
    }

    /// Office 2013–2022 default theme; used for missing theme parts and for missing entries of a broken one.
    public static let fallback = Theme(
        colors: [
            "dk1": RGBA(hex: "000000")!, "lt1": RGBA(hex: "FFFFFF")!,
            "dk2": RGBA(hex: "44546A")!, "lt2": RGBA(hex: "E7E6E6")!,
            "accent1": RGBA(hex: "4472C4")!, "accent2": RGBA(hex: "ED7D31")!,
            "accent3": RGBA(hex: "A5A5A5")!, "accent4": RGBA(hex: "FFC000")!,
            "accent5": RGBA(hex: "5B9BD5")!, "accent6": RGBA(hex: "70AD47")!,
            "hlink": RGBA(hex: "0563C1")!, "folHlink": RGBA(hex: "954F72")!,
        ],
        majorLatin: "Calibri Light", minorLatin: "Calibri")

    static let colorKeys = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4",
                            "accent5", "accent6", "hlink", "folHlink"]

    /// `xml` is the `a:theme` root. Anything missing or malformed falls back to `Theme.fallback`.
    public init(xml: OOXMLNode) {
        var t = Theme.fallback
        let elements = xml.child("themeElements")
        if let scheme = elements?.child("clrScheme") {
            for key in Theme.colorKeys {
                if let c = scheme.child(key).flatMap(Theme.baseColor) { t.colors[key] = c }
            }
        }
        if let fonts = elements?.child("fontScheme") {
            if let major = fonts.child("majorFont") {
                if let v = major.child("latin")?.attr("typeface") { t.majorLatin = v }
                if let v = major.child("ea")?.attr("typeface") { t.majorEA = v }
                t.majorScripts = Theme.scripts(major)
            }
            if let minor = fonts.child("minorFont") {
                if let v = minor.child("latin")?.attr("typeface") { t.minorLatin = v }
                if let v = minor.child("ea")?.attr("typeface") { t.minorEA = v }
                t.minorScripts = Theme.scripts(minor)
            }
        }
        if let fmt = elements?.child("fmtScheme") {
            t.fillStyles = fmt.child("fillStyleLst")?.children ?? []
            t.bgFillStyles = fmt.child("bgFillStyleLst")?.children ?? []
            t.lineStyles = fmt.child("lnStyleLst")?.children ?? []
            t.effectStyles = fmt.child("effectStyleLst")?.children ?? []
        }
        self = t
    }

    /// Color of a clrScheme entry: srgbClr val, or sysClr lastClr (falling back to the system color name).
    private static func baseColor(_ entry: OOXMLNode) -> RGBA? {
        guard let c = entry.children.first else { return nil }
        switch c.name {
        case "srgbClr": return c.attr("val").flatMap { RGBA(hex: $0) }
        case "sysClr":
            if let hex = c.attr("lastClr"), let v = RGBA(hex: hex) { return v }
            return c.attr("val").flatMap { ColorResolver.systemColors[$0] }
        default: return nil
        }
    }

    private static func scripts(_ font: OOXMLNode) -> [String: String] {
        var out: [String: String] = [:]
        for f in font.children("font") {
            if let s = f.attr("script"), let t = f.attr("typeface"), out[s] == nil { out[s] = t }
        }
        return out
    }
}
