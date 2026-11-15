import CoreGraphics
import Foundation
import Testing
@testable import OOXMLKit

private func spPr(_ inner: String) throws -> OOXMLNode { try xml("<p:spPr \(drawingNS)>\(inner)</p:spPr>") }
private func style(_ inner: String) throws -> OOXMLNode { try xml("<p:style \(drawingNS)>\(inner)</p:style>") }

private func near(_ a: Double, _ b: Double, _ tol: Double = 0.002) -> Bool { abs(a - b) <= tol }
private func near(_ a: RGBA, _ b: RGBA) -> Bool { near(a.r, b.r) && near(a.g, b.g) && near(a.b, b.b) && near(a.a, b.a) }

/// Theme whose fillStyleLst / lnStyleLst / effectStyleLst / bgFillStyleLst are given.
private func theme(fills: String = "", lines: String = "", effects: String = "", bgFills: String = "") throws -> Theme {
    try Theme(xml: xml("""
    <a:theme \(drawingNS)><a:themeElements><a:fmtScheme name="t">\
    <a:fillStyleLst>\(fills)</a:fillStyleLst><a:lnStyleLst>\(lines)</a:lnStyleLst>\
    <a:effectStyleLst>\(effects)</a:effectStyleLst><a:bgFillStyleLst>\(bgFills)</a:bgFillStyleLst>\
    </a:fmtScheme></a:themeElements></a:theme>
    """))
}

@Suite struct Transform2DTests {
    @Test func parsesXfrmInPoints() throws {
        let x = try xml("""
        <a:xfrm \(drawingNS) rot="5400000" flipH="1"><a:off x="127000" y="254000"/><a:ext cx="1270000" cy="635000"/>\
        <a:chOff x="12700" y="0"/><a:chExt cx="25400" cy="12700"/></a:xfrm>
        """)
        let t = Transform2D(xfrm: x)
        #expect(t.offset == CGPoint(x: 10, y: 20))
        #expect(t.extent == CGSize(width: 100, height: 50))
        #expect(t.rotation == 90)
        #expect(t.flipH && !t.flipV)
        #expect(t.childOffset == CGPoint(x: 1, y: 0))
        #expect(t.childExtent == CGSize(width: 2, height: 1))
    }

    @Test func missingOrBadXfrmIsZero() throws {
        #expect(Transform2D(xfrm: nil).extent == .zero)
        let bad = try xml("<a:xfrm \(drawingNS) rot=\"x\"><a:off x=\"NaN\" y=\"1e400\"/><a:ext cx=\"-5\" cy=\"q\"/></a:xfrm>")
        let t = Transform2D(xfrm: bad)
        #expect(t.offset == .zero && t.extent == .zero && t.rotation == 0)
    }

    @Test func affineRotatesAboutCenterClockwise() {
        let t = Transform2D(offset: CGPoint(x: 50, y: 40), extent: CGSize(width: 100, height: 20), rotation: 90)
        // Top-left corner (0,0) of a 100×20 shape rotated 90° cw about its centre (100,50) lands top-right.
        let p = CGPoint.zero.applying(t.affine)
        #expect(abs(p.x - 110) < 1e-9 && abs(p.y - 0) < 1e-9)
    }

    @Test func childToParentMapsChildSpace() {
        let t = Transform2D(offset: CGPoint(x: 20, y: 10), extent: CGSize(width: 100, height: 50),
                            childOffset: CGPoint(x: 100, y: 100), childExtent: CGSize(width: 200, height: 100))
        let p = CGPoint(x: 300, y: 200).applying(t.childToParent)
        #expect(abs(p.x - 120) < 1e-9 && abs(p.y - 60) < 1e-9)
    }
}

@Suite struct FillResolverTests {
    @Test func explicitFills() throws {
        #expect(FillResolver.fill(try spPr("<a:noFill/>"), style: nil, colors: plainColors) == .none)
        #expect(FillResolver.fill(try spPr("<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill>"), style: nil,
                                  colors: plainColors) == .solid(RGBA(r: 1, g: 0, b: 0)))
        #expect(FillResolver.fill(try spPr("<a:grpFill/>"), style: nil, colors: plainColors) == .group)
        #expect(FillResolver.fill(nil, style: nil, colors: plainColors) == .none)
    }

    @Test func linearGradient() throws {
        let f = FillResolver.fill(try spPr("""
        <a:gradFill><a:gsLst><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>\
        <a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs></a:gsLst><a:lin ang="5400000" scaled="1"/></a:gradFill>
        """), style: nil, colors: plainColors)
        guard case .gradient(let g) = f else { Issue.record("not a gradient: \(f)"); return }
        #expect(g.stops == [GradientStop(position: 0, color: RGBA(r: 1, g: 0, b: 0)),
                            GradientStop(position: 1, color: RGBA(r: 0, g: 0, b: 1))])
        #expect(g.angle == 90 && g.scaled && g.path == nil)
    }

    @Test func pathGradient() throws {
        let f = FillResolver.fill(try spPr("""
        <a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FFFFFF"/></a:gs><a:gs pos="100000"><a:srgbClr val="000000"/></a:gs>\
        </a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path></a:gradFill>
        """), style: nil, colors: plainColors)
        guard case .gradient(let g) = f else { Issue.record("not a gradient"); return }
        #expect(g.path == .circle && g.angle == nil)
        #expect(g.fillToRect == SrcRect(l: 0.5, t: 0.5, r: 0.5, b: 0.5))
    }

    @Test func patternFill() throws {
        let f = FillResolver.fill(try spPr("""
        <a:pattFill prst="pct25"><a:fgClr><a:srgbClr val="000000"/></a:fgClr><a:bgClr><a:srgbClr val="FFFFFF"/></a:bgClr></a:pattFill>
        """), style: nil, colors: plainColors)
        #expect(f == .pattern(fg: RGBA(r: 0, g: 0, b: 0), bg: RGBA(r: 1, g: 1, b: 1), preset: "pct25"))
    }

    @Test func fillRefIdx2UsesThemeFillStyleWithPhClr() throws {
        let t = try theme(fills: """
        <a:solidFill><a:srgbClr val="00FF00"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"><a:lumMod val="50000"/></a:schemeClr></a:solidFill>\
        <a:solidFill><a:srgbClr val="0000FF"/></a:solidFill>
        """)
        let colors = ColorContext(theme: t)
        let st = try style("<a:fillRef idx=\"2\"><a:srgbClr val=\"FF0000\"/></a:fillRef>")
        let f = FillResolver.fill(nil, style: st, colors: colors)
        guard case .solid(let c) = f else { Issue.record("not solid: \(f)"); return }
        #expect(near(c, RGBA(r: 0.5, g: 0, b: 0)))
        // Explicit spPr fill wins over the style.
        #expect(FillResolver.fill(try spPr("<a:noFill/>"), style: st, colors: colors) == .none)
        // idx 0 means no fill; out-of-range idx too.
        #expect(FillResolver.fill(nil, style: try style("<a:fillRef idx=\"0\"/>"), colors: colors) == .none)
        #expect(FillResolver.fill(nil, style: try style("<a:fillRef idx=\"9\"/>"), colors: colors) == .none)
    }

    @Test func fillRefAbove1000UsesBackgroundFillStyles() throws {
        let t = try theme(fills: "<a:noFill/>", bgFills: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>")
        let st = try style("<a:fillRef idx=\"1001\"><a:schemeClr val=\"accent1\"/></a:fillRef>")
        #expect(FillResolver.fill(nil, style: st, colors: ColorContext(theme: t)) == .solid(t.colors["accent1"]!))
    }

    @Test func blipFillNeedsPartContext() throws {
        let pkg = try makePackage {
            $0.add("ppt/slides/slide1.xml", "<x/>")
            $0.add("ppt/slides/_rels/slide1.xml.rels", slideRels([("rId1", "../media/image1.png")]))
        }
        let sp = try spPr("<a:blipFill><a:blip r:embed=\"rId1\"/><a:tile/></a:blipFill>")
        #expect(FillResolver.fill(sp, style: nil, colors: plainColors) == .none)
        let f = FillResolver.fill(sp, style: nil, colors: plainColors,
                                  part: PartContext(package: pkg, part: "ppt/slides/slide1.xml"))
        #expect(f == .picture(ImageRef(part: "ppt/media/image1.png"), stretch: nil, tile: true))
    }
}

@Suite struct LineResolverTests {
    @Test func explicitLine() throws {
        let l = LineResolver.line(try spPr("""
        <a:ln w="25400" cap="rnd"><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill><a:prstDash val="dash"/>\
        <a:bevel/><a:headEnd type="oval"/><a:tailEnd type="triangle" w="lg" len="sm"/></a:ln>
        """), style: nil, colors: plainColors)
        #expect(l?.width == 2)
        #expect(l?.fill == .solid(RGBA(r: 0, g: 0, b: 1)))
        #expect(l?.dash == [4, 3])
        #expect(l?.cap == .round && l?.join == .bevel)
        #expect(l?.headEnd == ArrowEnd(kind: .oval, width: .med, length: .med))
        #expect(l?.tailEnd == ArrowEnd(kind: .triangle, width: .lg, length: .sm))
    }

    @Test func noLineCases() throws {
        #expect(LineResolver.line(nil, style: nil, colors: plainColors) == nil)
        #expect(LineResolver.line(try spPr("<a:ln w=\"12700\"><a:noFill/></a:ln>"), style: nil, colors: plainColors) == nil)
        // An ln without any fill and no style draws nothing.
        #expect(LineResolver.line(try spPr("<a:ln w=\"12700\"/>"), style: nil, colors: plainColors) == nil)
    }

    @Test func dashPresetsAndCustomDash() throws {
        func dash(_ v: String) throws -> [CGFloat]? {
            LineResolver.line(try spPr("<a:ln><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>\(v)</a:ln>"),
                              style: nil, colors: plainColors)?.dash
        }
        #expect(try dash("<a:prstDash val=\"solid\"/>") == nil)
        #expect(try dash("<a:prstDash val=\"sysDot\"/>") == [1, 1])
        #expect(try dash("<a:prstDash val=\"lgDashDotDot\"/>") == [8, 3, 1, 3, 1, 3])
        #expect(try dash("<a:custDash><a:ds d=\"300000\" sp=\"100000\"/></a:custDash>") == [3, 1])
    }

    @Test func lnRefMergesThemeLineStyleWithOverrides() throws {
        let t = try theme(lines: """
        <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>\
        <a:ln w="38100" cap="sq"><a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr></a:solidFill></a:ln>
        """)
        let st = try style("<a:lnRef idx=\"2\"><a:srgbClr val=\"FF0000\"/></a:lnRef>")
        let l = LineResolver.line(nil, style: st, colors: ColorContext(theme: t))
        #expect(l?.width == 3)
        #expect(l?.cap == .square)
        // spPr ln overrides width and dash but keeps the style's colour.
        let o = LineResolver.line(try spPr("<a:ln w=\"12700\"><a:prstDash val=\"dot\"/></a:ln>"), style: st,
                                  colors: ColorContext(theme: t))
        #expect(o?.width == 1)
        #expect(o?.dash == [1, 3])
        #expect(o?.fill == l?.fill)
        #expect(LineResolver.line(nil, style: try style("<a:lnRef idx=\"0\"/>"), colors: ColorContext(theme: t)) == nil)
    }

    @Test func widthDefaults() throws {
        let solid = "<a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>"
        #expect(LineResolver.line(try spPr("<a:ln>\(solid)</a:ln>"), style: nil, colors: plainColors)?.width == 0.75)
        #expect(LineResolver.line(try spPr("<a:ln w=\"0\">\(solid)</a:ln>"), style: nil, colors: plainColors)?.width == 0)
    }
}

@Suite struct ShadowResolverTests {
    @Test func outerShadow() throws {
        let s = EffectResolver.shadow(try spPr("""
        <a:effectLst><a:outerShdw blurRad="50800" dist="38100" dir="5400000"><a:srgbClr val="000000"><a:alpha val="40000"/></a:srgbClr></a:outerShdw></a:effectLst>
        """), style: nil, colors: plainColors)
        #expect(s?.blur == 4 && s?.distance == 3 && s?.direction == 90)
        #expect(s?.color == RGBA(r: 0, g: 0, b: 0, a: 0.4))
        if let o = s?.offset { #expect(abs(o.width) < 1e-9 && abs(o.height - 3) < 1e-9) }
    }

    @Test func otherEffectsIgnoredAndEmptyListOverridesStyle() throws {
        let t = try theme(effects: """
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst><a:outerShdw dist="12700"><a:schemeClr val="phClr"/></a:outerShdw></a:effectLst></a:effectStyle>
        """)
        let st = try style("<a:effectRef idx=\"2\"><a:srgbClr val=\"00FF00\"/></a:effectRef>")
        #expect(EffectResolver.shadow(nil, style: st, colors: ColorContext(theme: t))?.color == RGBA(r: 0, g: 1, b: 0))
        #expect(EffectResolver.shadow(try spPr("<a:effectLst/>"), style: st, colors: ColorContext(theme: t)) == nil)
        #expect(EffectResolver.shadow(try spPr("<a:effectLst><a:glow rad=\"1\"/><a:innerShdw/></a:effectLst>"),
                                      style: nil, colors: plainColors) == nil)
    }
}

@Suite struct ShapeModelTests {
    @Test func buildsFromSpPrAndStyle() throws {
        let sp = try spPr("""
        \(xfrmXML(10, 20, 100, 50))<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>\
        <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
        """)
        let m = ShapeModel(spPr: sp, style: nil, colors: plainColors)
        #expect(m.transform.frame == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(m.fill == .solid(RGBA(r: 1, g: 0, b: 0)))
        #expect(m.line == nil && m.shadow == nil)
        if case .preset(let name, _)? = m.geometry { #expect(name == "ellipse") } else { Issue.record("no geometry") }
        let tr = m.textRect
        #expect(tr.width > 0 && tr.width < 100)
    }

    @Test func textRectDefaultsToBounds() {
        let m = ShapeModel(transform: Transform2D(offset: .zero, extent: CGSize(width: 40, height: 30)))
        #expect(m.textRect == CGRect(x: 0, y: 0, width: 40, height: 30))
    }
}
