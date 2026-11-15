import Testing
import Foundation
@testable import OOXMLKit

private let aNS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
private let pNS = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

private func node(_ inner: String) throws -> OOXMLNode {
    try OOXMLNode.parse(Data("<a:solidFill \(aNS)>\(inner)</a:solidFill>".utf8))
}

private func ctx(_ ph: RGBA? = nil, map: ColorMap = ColorMap()) -> ColorContext {
    ColorContext(theme: .fallback, map: map, placeholderColor: ph)
}

private func resolve(_ inner: String, _ c: ColorContext? = nil) throws -> RGBA? {
    ColorResolver.resolve(try node(inner), in: c ?? ctx())
}

private func expectHex(_ c: RGBA?, _ hex: String, tol: Double = 1, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let c, let want = RGBA(hex: hex) else {
        Issue.record("nil color, wanted \(hex)", sourceLocation: sourceLocation); return
    }
    #expect(abs(c.r - want.r) * 255 <= max(tol, 1e-6), "r \(c.r * 255) vs \(want.r * 255)", sourceLocation: sourceLocation)
    #expect(abs(c.g - want.g) * 255 <= max(tol, 1e-6), "g \(c.g * 255) vs \(want.g * 255)", sourceLocation: sourceLocation)
    #expect(abs(c.b - want.b) * 255 <= max(tol, 1e-6), "b \(c.b * 255) vs \(want.b * 255)", sourceLocation: sourceLocation)
}

@Suite struct UnitsTests {
    @Test func conversions() {
        #expect(Units.points(fromEMU: 12700) == 1)
        #expect(Units.inches(fromEMU: 914400) == 1)
        #expect(Units.degrees(fromAngle: 5_400_000) == 90)
        #expect(Units.fraction(fromPercent: 50000) == 0.5)
    }
    @Test func percentageStrings() {
        #expect(Units.parsePercentage("50%") == 0.5)
        #expect(Units.parsePercentage("50000") == 0.5)
        #expect(Units.parsePercentage("-12.5%") == -0.125)
        #expect(Units.parsePercentage(" 100000 ") == 1)
        #expect(Units.parsePercentage("abc") == nil)
        #expect(Units.parsePercentage(nil) == nil)
    }
}

@Suite struct ColorResolverTests {
    @Test func srgbAndScheme() throws {
        expectHex(try resolve("<a:srgbClr val=\"FF8000\"/>"), "FF8000", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"accent1\"/>"), "4472C4", tol: 0)
        #expect(try resolve("<a:srgbClr val=\"FF8000\"/>")?.a == 1)
    }
    @Test func lumModLumOff() throws {
        expectHex(try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"75000\"/></a:schemeClr>"), "2F5597")
        expectHex(try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"60000\"/><a:lumOff val=\"40000\"/></a:schemeClr>"), "8FAADC")
        expectHex(try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"50000\"/></a:schemeClr>"), "203864")
        expectHex(try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"20000\"/><a:lumOff val=\"80000\"/></a:schemeClr>"), "D9E2F3")
    }
    @Test func tintShadeLinear() throws {
        // linear-light blend towards white / black (LibreOffice oox Color::getColor)
        expectHex(try resolve("<a:srgbClr val=\"000000\"><a:tint val=\"50000\"/></a:srgbClr>"), "BCBCBC")
        expectHex(try resolve("<a:srgbClr val=\"FFFFFF\"><a:shade val=\"50000\"/></a:srgbClr>"), "BCBCBC")
        expectHex(try resolve("<a:srgbClr val=\"FF0000\"><a:tint val=\"100000\"/></a:srgbClr>"), "FF0000", tol: 0)
        expectHex(try resolve("<a:srgbClr val=\"FF0000\"><a:shade val=\"0\"/></a:srgbClr>"), "000000", tol: 0)
    }
    @Test func alpha() throws {
        #expect(try resolve("<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/></a:srgbClr>")?.a == 0.5)
        #expect(try resolve("<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/><a:alphaMod val=\"50000\"/></a:srgbClr>")?.a == 0.25)
        let off = try resolve("<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/><a:alphaOff val=\"-25000\"/></a:srgbClr>")
        #expect(off?.a == 0.25)
    }
    @Test func satHueModifiers() throws {
        expectHex(try resolve("<a:srgbClr val=\"FF0000\"><a:hueOff val=\"7200000\"/></a:srgbClr>"), "00FF00", tol: 1) // +120 deg
        expectHex(try resolve("<a:srgbClr val=\"FF0000\"><a:satMod val=\"0\"/></a:srgbClr>"), "808080")
        expectHex(try resolve("<a:srgbClr val=\"FF0000\"><a:comp/></a:srgbClr>"), "00FFFF")
        expectHex(try resolve("<a:srgbClr val=\"FF8000\"><a:inv/></a:srgbClr>"), "007FFF")
    }
    @Test func grayAndChannelMods() throws {
        let g = try resolve("<a:srgbClr val=\"FF0000\"><a:gray/></a:srgbClr>")
        #expect(g != nil && abs(g!.r - g!.g) < 1e-9 && abs(g!.g - g!.b) < 1e-9)
        expectHex(try resolve("<a:srgbClr val=\"000000\"><a:redOff val=\"100000\"/></a:srgbClr>"), "FF0000", tol: 0)
    }
    @Test func schemeMapping() throws {
        expectHex(try resolve("<a:schemeClr val=\"bg1\"/>"), "FFFFFF", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"tx1\"/>"), "000000", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"bg2\"/>"), "E7E6E6", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"tx2\"/>"), "44546A", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"dk2\"/>"), "44546A", tol: 0)
        #expect(try resolve("<a:schemeClr val=\"nonsense\"/>") == nil)
    }
    @Test func inverseClrMap() throws {
        let xml = "<p:clrMap \(pNS) bg1=\"dk1\" tx1=\"lt1\" bg2=\"dk2\" tx2=\"lt2\" accent1=\"accent2\" accent2=\"accent1\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        let map = ColorMap(xml: try OOXMLNode.parse(Data(xml.utf8)))
        #expect(map.map("bg1") == "dk1")
        #expect(map.map("accent1") == "accent2")
        #expect(map.map("dk1") == "dk1")
        expectHex(try resolve("<a:schemeClr val=\"bg1\"/>", ctx(map: map)), "000000", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"accent1\"/>", ctx(map: map)), "ED7D31", tol: 0)
    }
    @Test func clrMapOverride() throws {
        let master = try OOXMLNode.parse(Data("<p:clrMapOvr \(pNS) \(aNS)><a:masterClrMapping/></p:clrMapOvr>".utf8))
        #expect(ColorMap(override: master) == nil)
        let ovr = try OOXMLNode.parse(Data("<p:clrMapOvr \(pNS) \(aNS)><a:overrideClrMapping bg1=\"dk1\" tx1=\"lt1\" bg2=\"dk2\" tx2=\"lt2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/></p:clrMapOvr>".utf8))
        #expect(ColorMap(override: ovr)?.map("bg1") == "dk1")
        #expect(ColorMap(xml: master).map("bg1") == "lt1")   // init(xml:) falls back to default
        #expect(ColorMap(xml: nil).map("tx1") == "dk1")
    }
    @Test func sysClr() throws {
        expectHex(try resolve("<a:sysClr val=\"windowText\" lastClr=\"112233\"/>"), "112233", tol: 0)
        expectHex(try resolve("<a:sysClr val=\"window\"/>"), "FFFFFF", tol: 0)
        expectHex(try resolve("<a:sysClr val=\"windowText\"/>"), "000000", tol: 0)
    }
    @Test func prstClr() throws {
        expectHex(try resolve("<a:prstClr val=\"red\"/>"), "FF0000", tol: 0)
        expectHex(try resolve("<a:prstClr val=\"black\"/>"), "000000", tol: 0)
        expectHex(try resolve("<a:prstClr val=\"darkGray\"/>"), "A9A9A9", tol: 0)
        #expect(try resolve("<a:prstClr val=\"notAColor\"/>") == nil)
    }
    @Test func hslAndScrgb() throws {
        expectHex(try resolve("<a:hslClr hue=\"0\" sat=\"100000\" lum=\"50000\"/>"), "FF0000")
        expectHex(try resolve("<a:hslClr hue=\"7200000\" sat=\"100000\" lum=\"50000\"/>"), "00FF00")
        expectHex(try resolve("<a:scrgbClr r=\"100000\" g=\"0\" b=\"0\"/>"), "FF0000")
        // 21.4% linear = 128 sRGB
        expectHex(try resolve("<a:scrgbClr r=\"21586\" g=\"21586\" b=\"21586\"/>"), "808080")
    }
    @Test func unknownKindAndEmpty() throws {
        #expect(try resolve("<a:foo val=\"1\"/>") == nil)
        #expect(try resolve("") == nil)
        #expect(try resolve("<a:srgbClr val=\"zz\"/>") == nil)
    }
    @Test func placeholder() throws {
        let ph = RGBA(hex: "123456")
        expectHex(try resolve("<a:schemeClr val=\"phClr\"/>", ctx(ph)), "123456", tol: 0)
        expectHex(try resolve("<a:schemeClr val=\"phClr\"><a:lumMod val=\"50000\"/></a:schemeClr>", ctx(ph)), "091B2B", tol: 2)
        let missing = ColorResolver.resolveDetailed(try node("<a:schemeClr val=\"phClr\"/>"), in: ctx())
        expectHex(missing?.color, "000000", tol: 0)
        #expect(missing?.placeholderMissing == true)
        #expect(ColorResolver.resolveDetailed(try node("<a:srgbClr val=\"FFFFFF\"/>"), in: ctx())?.placeholderMissing == false)
    }
    @Test func modifiersApplyInDocumentOrder() throws {
        let a = try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"50000\"/><a:lumOff val=\"50000\"/></a:schemeClr>")
        let b = try resolve("<a:schemeClr val=\"accent1\"><a:lumOff val=\"50000\"/><a:lumMod val=\"50000\"/></a:schemeClr>")
        #expect(a != b)
    }
}

@Suite struct ThemeTests {
    static let xml = """
    <a:theme \(aNS) name="T"><a:themeElements>
    <a:clrScheme name="x"><a:dk1><a:sysClr val="windowText" lastClr="010101"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FEFEFE"/></a:lt1>
    <a:dk2><a:srgbClr val="111111"/></a:dk2><a:lt2><a:srgbClr val="EEEEEE"/></a:lt2>
    <a:accent1><a:srgbClr val="AA0000"/></a:accent1><a:accent2><a:srgbClr val="00AA00"/></a:accent2><a:accent3><a:srgbClr val="0000AA"/></a:accent3>
    <a:accent4><a:srgbClr val="AAAA00"/></a:accent4><a:accent5><a:srgbClr val="00AAAA"/></a:accent5><a:accent6><a:srgbClr val="AA00AA"/></a:accent6>
    <a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="f"><a:majorFont><a:latin typeface="Major L"/><a:ea typeface="Major EA"/><a:cs typeface=""/><a:font script="Jpan" typeface="MS PGothic"/><a:font script="Hang" typeface="Malgun"/></a:majorFont>
    <a:minorFont><a:latin typeface="Minor L"/><a:ea typeface=""/><a:font script="Jpan" typeface="MS PMincho"/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="o"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:noFill/></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="6350"/></a:lnStyleLst><a:effectStyleLst><a:effectStyle/><a:effectStyle/></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
    </a:themeElements></a:theme>
    """

    @Test func parses() throws {
        let t = Theme(xml: try OOXMLNode.parse(Data(Self.xml.utf8)))
        expectHex(t.colors["dk1"], "010101", tol: 0)
        expectHex(t.colors["lt1"], "FEFEFE", tol: 0)
        expectHex(t.colors["accent6"], "AA00AA", tol: 0)
        expectHex(t.colors["folHlink"], "800080", tol: 0)
        #expect(t.majorLatin == "Major L" && t.minorLatin == "Minor L")
        #expect(t.majorEA == "Major EA")
        #expect(t.minorEA == "")
        #expect(t.majorScripts["Jpan"] == "MS PGothic")
        #expect(t.minorScripts["Jpan"] == "MS PMincho")
        #expect(t.fillStyles.count == 2 && t.bgFillStyles.count == 1 && t.lineStyles.count == 1 && t.effectStyles.count == 2)
    }
    @Test func missingPartsFallBack() throws {
        let t = Theme(xml: try OOXMLNode.parse(Data("<a:theme \(aNS)/>".utf8)))
        expectHex(t.colors["accent1"], "4472C4", tol: 0)
        #expect(t.minorLatin == "Calibri" && t.majorLatin == "Calibri Light")
    }
    @Test func fallbackValues() {
        let t = Theme.fallback
        expectHex(t.colors["accent5"], "5B9BD5", tol: 0)
        expectHex(t.colors["hlink"], "0563C1", tol: 0)
        expectHex(t.colors["folHlink"], "954F72", tol: 0)
    }
}
