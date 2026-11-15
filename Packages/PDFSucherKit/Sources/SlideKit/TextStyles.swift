// TextStyles.swift — Task 10 (SlideKit)
// The text style cascade (list styles per level, attribute-wise merge) and the conversion of merged DrawingML
// paragraph/run/body properties into OOXMLKit's `ParagraphStyle`, `RunStyle` and `BodyProps`.
//
// Cascade per level 0…8, lowest priority first (docs/decisions.md, "Text style cascade"):
//   non-placeholders: presentation `p:defaultTextStyle`; placeholders: master `p:txStyles` (titleStyle |
//   bodyStyle | otherStyle by placeholder type)
//   → the shape's `p:style/a:fontRef` (color as solidFill, idx major/minor as latin +mj-lt/+mn-lt)
//   → placeholders only: master placeholder `a:lstStyle` → layout placeholder `a:lstStyle`
//   → the shape's own `a:lstStyle` → the paragraph's `a:pPr` → the run's `a:rPr`.
// In every list style `a:defPPr` applies first, then `a:lvlNpPr`. Attributes override one by one; child
// elements override per group (the bullet kind, bullet color/size/font, the fill, …); `a:defRPr` inside a level
// is the run default and merges the same way.
import CoreGraphics
import Foundation
import OOXMLKit

/// Merged paragraph properties of one level plus its run defaults.
struct LevelProps: Sendable {
    var pAttrs: [String: String] = [:]
    /// `a:pPr` children by group (see `group`), `a:defRPr` excluded.
    var pChildren: [String: OOXMLNode] = [:]
    var rAttrs: [String: String] = [:]
    var rChildren: [String: OOXMLNode] = [:]

    /// Merges an `a:lvlNpPr` / `a:defPPr` / `a:pPr` over these props (its `a:defRPr` into the run defaults).
    mutating func apply(pPr: OOXMLNode?) {
        guard let pPr else { return }
        pAttrs.merge(pPr.attributes) { $1 }
        for c in pPr.children {
            if c.name == "defRPr" { apply(rPr: c) } else { pChildren[Self.group(c.name)] = c }
        }
    }

    /// Merges an `a:rPr` / `a:defRPr` / `a:endParaRPr` over the run defaults.
    mutating func apply(rPr: OOXMLNode?) {
        guard let rPr else { return }
        rAttrs.merge(rPr.attributes) { $1 }
        for c in rPr.children { rChildren[Self.group(c.name)] = c }
    }

    /// Mutually exclusive elements share one key, so a nearer level replaces the whole choice.
    static func group(_ name: String) -> String {
        switch name {
        case "buNone", "buAutoNum", "buChar", "buBlip": "bu"
        case "buClrTx", "buClr": "buClr"
        case "buSzTx", "buSzPct", "buSzPts": "buSz"
        case "buFontTx", "buFont": "buFont"
        case "noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill": "fill"
        default: name
        }
    }
}

/// The base props of levels 0…8 of one text body (everything below the paragraph's own `a:pPr`).
struct TextStyleCascade: Sendable {
    static let levelCount = 9
    let levels: [LevelProps]

    /// `sources`: list-style-like elements (`a:lstStyle`, `p:titleStyle`, `p:defaultTextStyle`, …), lowest
    /// priority first; nil entries are skipped.
    init(sources: [OOXMLNode?]) {
        var levels = [LevelProps](repeating: LevelProps(), count: Self.levelCount)
        for case let s? in sources {
            let def = s.child("defPPr")
            for l in 0..<Self.levelCount {
                levels[l].apply(pPr: def)
                levels[l].apply(pPr: s.child("lvl\(l + 1)pPr"))
            }
        }
        self.levels = levels
    }

    func level(_ l: Int) -> LevelProps { levels[Self.clamp(l)] }

    static func clamp(_ l: Int) -> Int { min(max(l, 0), levelCount - 1) }

    /// A list-style-like element holding the shape's `a:fontRef` as a run default for every level: its color
    /// child as `a:solidFill`, idx major/minor as `a:latin` +mj-lt/+mn-lt. nil when it says neither.
    static func fontRefSource(_ fontRef: OOXMLNode?) -> OOXMLNode? {
        guard let fontRef else { return nil }
        var children: [OOXMLNode] = []
        if let color = fontRef.children.first { children.append(OOXMLNode(name: "solidFill", children: [color])) }
        switch fontRef.attr("idx") {
        case "major": children.append(OOXMLNode(name: "latin", attributes: ["typeface": "+mj-lt"]))
        case "minor": children.append(OOXMLNode(name: "latin", attributes: ["typeface": "+mn-lt"]))
        default: break
        }
        guard !children.isEmpty else { return nil }
        return OOXMLNode(name: "lstStyle", children: [
            OOXMLNode(name: "defPPr", children: [OOXMLNode(name: "defRPr", children: children)]),
        ])
    }

    /// Master `p:txStyles` child for a placeholder of normalised type `type`.
    static func masterStyleName(placeholderType type: String) -> String {
        switch type {
        case "title": "titleStyle"
        case "dt", "ftr", "sldNum", "hdr", "sldImg": "otherStyle"
        default: "bodyStyle" // obj, body, chart, tbl, dgm, pic, media, clipArt, unknown
        }
    }
}

/// What a text body needs besides its own XML: theme colors and fonts, the shape's `p:style` fallbacks.
struct TextEnvironment: Sendable {
    let colors: ColorContext
    /// `p:style/a:fontRef`: color child (text color fallback) and idx major/minor (typeface fallback).
    let fontRef: OOXMLNode?

    /// Theme shorthand (+mj-lt, +mn-lt, +mj-ea, +mn-ea, +mj-cs, +mn-cs) → the slide theme's typeface; nil for an
    /// empty name. Other names pass through.
    func typeface(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let t = colors.theme
        let name: String
        switch raw.lowercased() {
        case "+mj-lt": name = t.majorLatin
        case "+mn-lt": name = t.minorLatin
        case "+mj-ea": name = t.majorEA
        case "+mn-ea": name = t.minorEA
        case "+mj-cs", "+mn-cs": name = "Arial"
        default: return raw
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Default text color: the fontRef color, else tx1 through the color map.
    var defaultColor: RGBA {
        if let fontRef, let c = ColorResolver.resolve(fontRef, in: colors) { return c }
        return colors.theme.colors[colors.map.map("tx1")] ?? RGBA(r: 0, g: 0, b: 0)
    }

    /// Default typeface: the fontRef idx (major/minor), else the minor font.
    var defaultTypeface: String? {
        typeface(fontRef?.attr("idx") == "major" ? "+mj-lt" : "+mn-lt")
    }

    // MARK: runs

    /// A run style from merged run properties. Latin typeface only (ea/cs ignored, docs/decisions.md).
    func runStyle(_ p: LevelProps) -> RunStyle {
        let a = p.rAttrs
        var s = RunStyle()
        s.typeface = typeface(p.rChildren["latin"]?.attr("typeface")) ?? defaultTypeface
        if let sz = Self.number(a["sz"]), sz > 0 { s.size = CGFloat(sz / 100) }
        s.bold = Self.flag(a["b"])
        s.italic = Self.flag(a["i"])
        switch a["u"] {
        case nil, "none": s.underline = .none
        case "dbl", "wavyDbl": s.underline = .double
        default: s.underline = .single
        }
        s.strike = a["strike"] == "sngStrike" || a["strike"] == "dblStrike"
        // Superscript/subscript: PowerPoint draws them at 2/3 size, shifted by the percentage of the full size
        // (measured against a PowerPoint PDF export, docs/decisions.md).
        if let b = Self.number(a["baseline"]), b.isFinite, b != 0 {
            s.size = s.size * 2 / 3
            s.baselineShift = b / 1000 * 1.5
        }
        switch a["cap"] {
        case "small": s.caps = .small
        case "all": s.caps = .all
        default: s.caps = .none
        }
        if let spc = Self.number(a["spc"]) { s.spacing = CGFloat(spc / 100) }
        s.color = color(p.rChildren["fill"]) ?? defaultColor
        if let h = p.rChildren["highlight"] { s.highlight = ColorResolver.resolve(h, in: colors) }
        // Hyperlinks: theme hlink color, underlined (PowerPoint), unless the link asks for the text color.
        if let link = p.rChildren["hlinkClick"], !Self.linkKeepsTextColor(link),
           let c = colors.theme.colors[colors.map.map("hlink")] {
            s.color = c
            if s.underline == .none { s.underline = .single }
        }
        return s
    }

    /// Text fill: solid → its color, noFill → transparent, gradient → first stop, else nil (inherit further).
    func color(_ fill: OOXMLNode?) -> RGBA? {
        guard let fill else { return nil }
        switch fill.name {
        case "solidFill": return ColorResolver.resolve(fill, in: colors)
        case "noFill": return RGBA(r: 0, g: 0, b: 0, a: 0)
        case "gradFill":
            return fill.child("gsLst")?.children.first.flatMap { ColorResolver.resolve($0, in: colors) }
        default: return nil
        }
    }

    private static func linkKeepsTextColor(_ link: OOXMLNode) -> Bool {
        guard let ext = link.child("extLst") else { return false }
        return ext.children.contains { $0.child("hlinkClr")?.attr("val") == "tx" }
    }

    // MARK: paragraphs

    /// A paragraph style from merged props. `firstRun` is the style the bullet follows (size for buSzPts).
    func paragraphStyle(_ p: LevelProps, firstRun: RunStyle, part: PartContext) -> ParagraphStyle {
        let a = p.pAttrs
        var s = ParagraphStyle()
        switch a["algn"] {
        case "ctr": s.align = .center
        case "r": s.align = .right
        case "just", "justLow": s.align = .justify
        case "dist", "thaiDist": s.align = .distributed
        default: s.align = .left
        }
        s.marginLeft = Self.points(a["marL"]) ?? 0
        s.marginRight = Self.points(a["marR"]) ?? 0
        // PowerPoint never puts the first line left of the box: marL + indent ≥ 0.
        s.indentFirst = max(Self.points(a["indent"]) ?? 0, -s.marginLeft)
        if let v = Self.spacing(p.pChildren["spcBef"]) { s.spaceBefore = v }
        if let v = Self.spacing(p.pChildren["spcAft"]) { s.spaceAfter = v }
        if let ln = p.pChildren["lnSpc"] {
            if let pct = ln.child("spcPct").flatMap({ Units.parsePercentage($0.attr("val")) }), pct > 0 {
                s.lineSpacing = .multiple(pct)
            } else if let pts = ln.child("spcPts").flatMap({ Self.number($0.attr("val")) }), pts > 0 {
                s.lineSpacing = .exact(CGFloat(pts / 100))
            }
        }
        s.tabs = (p.pChildren["tabLst"]?.children("tab") ?? []).compactMap { t in
            guard let pos = Self.points(t.attr("pos")) else { return nil }
            let align: TabAlignment = switch t.attr("algn") {
            case "ctr": .center
            case "r": .right
            case "dec": .decimal
            default: .left
            }
            return TabStop(position: pos, alignment: align)
        }
        if let d = Self.points(a["defTabSz"]), d > 0 { s.defaultTab = d }
        s.rtl = Self.flag(a["rtl"])
        s.bullet = bullet(p, firstRun: firstRun, part: part)
        return s
    }

    private func bullet(_ p: LevelProps, firstRun: RunStyle, part: PartContext) -> Bullet? {
        guard let bu = p.pChildren["bu"] else { return nil }
        let font = p.pChildren["buFont"].flatMap { $0.name == "buFont" ? typeface($0.attr("typeface")) : nil }
        let color = p.pChildren["buClr"].flatMap { $0.name == "buClr" ? ColorResolver.resolve($0, in: colors) : nil }
        var percent: Double?
        if let sz = p.pChildren["buSz"] {
            switch sz.name {
            case "buSzPct": percent = Units.parsePercentage(sz.attr("val")).map { $0 * 100 }
            case "buSzPts":
                if let pts = Self.number(sz.attr("val")), firstRun.size > 0 { percent = pts / 100 / Double(firstRun.size) * 100 }
            default: break
            }
        }
        switch bu.name {
        case "buChar":
            guard let ch = bu.attr("char"), !ch.isEmpty else { return nil }
            return .char(ch, typeface: font, color: color, sizePercent: percent)
        case "buAutoNum":
            // PowerPoint's range is 1…32767.
            let start = TextEnvironment.number(bu.attr("startAt")).map { Int(min(max($0, 1), 32767)) } ?? 1
            return .autoNumber(scheme: bu.attr("type") ?? "arabicPeriod", startAt: start, typeface: font,
                               color: color, sizePercent: percent)
        case "buBlip":
            // The picture is drawn by TextBodyLayout; the id indexes `ShapeTextLayout.pictureBullets`.
            let side = firstRun.size * CGFloat((percent ?? 100) / 100)
            return .picture(id: 0, size: CGSize(width: side, height: side))
        default:
            return nil // buNone
        }
    }

    // MARK: values

    static func flag(_ s: String?) -> Bool { s == "1" || s == "true" }

    static func number(_ s: String?) -> Double? {
        guard let s, let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v
    }

    /// EMU → points.
    static func points(_ s: String?) -> CGFloat? {
        number(s).map { CGFloat(Units.points(fromEMU: $0)) }
    }

    /// `a:spcBef`/`a:spcAft`: spcPts (1/100 pt) or spcPct (1/1000 %).
    static func spacing(_ n: OOXMLNode?) -> Spacing? {
        if let pts = n?.child("spcPts").flatMap({ number($0.attr("val")) }) { return .points(CGFloat(pts / 100)) }
        if let pct = n?.child("spcPct").flatMap({ Units.parsePercentage($0.attr("val")) }) { return .percent(pct * 100) }
        return nil
    }
}

// MARK: - bodyPr

/// Resolved `a:bodyPr`: attributes inherited one by one (slide over layout over master), the autofit choice as
/// a whole.
struct BodyProps: Sendable {
    /// Points.
    var insets = (left: CGFloat(7.2), top: CGFloat(3.6), right: CGFloat(7.2), bottom: CGFloat(3.6))
    enum Anchor: Sendable { case top, center, bottom }
    var anchor = Anchor.top
    var anchorCenter = false
    var wrap = true
    /// Text rotation in degrees, clockwise: `vert` (90), `vert270` (−90) plus `rot`.
    var rotation: Double = 0
    /// Box width and height swap (vertical text).
    var vertical = false
    var fontScale: Double = 1
    var lineSpaceReduction: Double = 0
    var columns = 1
    var columnSpacing: CGFloat = 0

    /// `bodies`: `a:bodyPr` elements, nearest first (slide, layout, master).
    init(_ bodies: [OOXMLNode]) {
        var attrs: [String: String] = [:]
        for b in bodies.reversed() { attrs.merge(b.attributes) { $1 } }
        func pt(_ k: String, _ d: CGFloat) -> CGFloat { TextEnvironment.points(attrs[k]).map { max($0, 0) } ?? d }
        insets = (pt("lIns", 7.2), pt("tIns", 3.6), pt("rIns", 7.2), pt("bIns", 3.6))
        switch attrs["anchor"] {
        case "ctr": anchor = .center
        case "b": anchor = .bottom
        default: anchor = .top // t, just, dist
        }
        anchorCenter = TextEnvironment.flag(attrs["anchorCtr"])
        wrap = attrs["wrap"] != "none"
        switch attrs["vert"] {
        case "vert", "eaVert", "mongolianVert": rotation = 90; vertical = true
        case "vert270": rotation = -90; vertical = true
        default: break // horz, wordArtVert, wordArtVertRtl: drawn horizontally
        }
        if let rot = TextEnvironment.number(attrs["rot"]) { rotation += Units.degrees(fromAngle: rot) }
        if let n = TextEnvironment.number(attrs["numCol"]), n >= 1 { columns = Int(min(n, 16)) }
        columnSpacing = pt("spcCol", 0)
        let autofit = bodies.lazy.compactMap { b in
            b.children.first { ["normAutofit", "spAutoFit", "noAutofit"].contains($0.name) }
        }.first
        if let a = autofit, a.name == "normAutofit" {
            if let s = Units.parsePercentage(a.attr("fontScale")), s > 0 { fontScale = min(s, 1) }
            if let r = Units.parsePercentage(a.attr("lnSpcReduction")), r > 0 { lineSpaceReduction = min(r, 1) }
        }
    }
}
