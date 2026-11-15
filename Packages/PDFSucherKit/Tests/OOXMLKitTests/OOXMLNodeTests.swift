import Foundation
import Testing
@testable import OOXMLKit

private func parse(_ s: String) throws -> OOXMLNode { try OOXMLNode.parse(Data(s.utf8)) }

private let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
private let pNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
private let mcNS = "http://schemas.openxmlformats.org/markup-compatibility/2006"

@Suite struct OOXMLNodeTests {
    @Test func namespacesAreResolvedIndependentOfPrefix() throws {
        let root = try parse("""
        <x:sld xmlns:x="\(pNS)" xmlns:q="\(aNS)"><q:off/><x:sp xmlns="\(aNS)"><txBody/></x:sp></x:sld>
        """)
        #expect(root.name == "sld")
        #expect(root.ns == NS.p)
        #expect(root.child("off")?.ns == NS.a)
        let sp = try #require(root.child("sp"))
        #expect(sp.child("txBody")?.ns == NS.a)
        #expect(root.child("off", ns: NS.p) == nil)
        #expect(root.child("off", ns: NS.a) != nil)
    }

    @Test func attributeKeys() throws {
        let root = try parse("""
        <a:blip xmlns:a="\(aNS)" xmlns:r="\(NS.r)" xmlns:z="urn:z" r:embed="rId2" z:embed="other" cx="5" xml:space="preserve"/>
        """)
        #expect(root.attr("cx") == "5")
        #expect(root.attr("embed", ns: NS.r) == "rId2")
        #expect(root.attr("embed", ns: "urn:z") == "other")
        #expect(root.attr("embed") == nil)
        #expect(root.attributes[NS.r + "|embed"] == "rId2")
        #expect(root.attr("space", ns: NS.xml) == "preserve")
        #expect(root.attributes.keys.contains { $0.contains("xmlns") } == false)
    }

    @Test func childLookup() throws {
        let root = try parse("<r><a/><b/><a/></r>")
        #expect(root.children("a").count == 2)
        #expect(root.children("zz").isEmpty)
        #expect(root.child("b")?.name == "b")
        #expect(root.children.map(\.name) == ["a", "b", "a"])
    }

    @Test func entitiesAndCDATA() throws {
        let root = try parse("<t>a &amp; b &lt;c&gt; &#65;<![CDATA[<raw> & ]]>end</t>")
        #expect(root.text == "a & b <c> A<raw> & end")
    }

    @Test func whitespaceHandling() throws {
        let root = try parse("""
        <a:p xmlns:a="\(aNS)" xmlns:w="\(NS.w)">
          <a:r><a:t>  lead and trail  </a:t></a:r>
          <a:r><a:t> </a:t></a:r>
          <w:t xml:space="preserve"> </w:t>
          <keep xml:space="preserve">  <inner/>  </keep>
          <drop>  <inner/>  </drop>
          <mixed>x <inner/> y</mixed>
        </a:p>
        """)
        #expect(root.text == "")
        let runs = root.children("r")
        #expect(runs[0].child("t")?.text == "  lead and trail  ")
        #expect(runs[1].child("t")?.text == " ")
        #expect(root.child("t", ns: NS.w)?.text == " ")
        #expect(root.child("keep")?.text == "    ")
        #expect(root.child("drop")?.text == "")
        #expect(root.child("mixed")?.text == "x  y")
    }

    @Test func preserveIsInherited() throws {
        let root = try parse("<a xml:space=\"preserve\"><b> <c/> </b></a>")
        #expect(root.child("b")?.text == "  ")
    }

    // MARK: mc:AlternateContent

    private func ac(_ body: String, extra: String = "") throws -> OOXMLNode {
        try parse("""
        <root xmlns="urn:r" xmlns:mc="\(mcNS)" xmlns:pp="http://schemas.microsoft.com/office/powerpoint/2010/main" \
        xmlns:zz="urn:unknown" xmlns:w16="http://schemas.microsoft.com/office/word/2018/wordml" \(extra)>\
        <before/>\(body)<after/></root>
        """)
    }

    @Test func alternateContentPicksSupportedChoice() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="pp"><chosen/><chosen2/></mc:Choice><mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "chosen", "chosen2", "after"])
    }

    @Test func alternateContentFallsBackForUnsupported() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="zz"><chosen/></mc:Choice><mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "fb", "after"])
    }

    @Test func alternateContentRequiresAllPrefixes() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="pp zz"><chosen/></mc:Choice><mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "fb", "after"])
    }

    @Test func alternateContentSecondChoiceAndUnresolvablePrefix() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="nope"><c1/></mc:Choice><mc:Choice Requires="  pp  "><c2/></mc:Choice><mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "c2", "after"])
    }

    @Test func alternateContentPreferringFallbackOverANamespace() throws {
        func parse(_ body: String) throws -> OOXMLNode {
            let xml = "<root xmlns=\"urn:r\" xmlns:mc=\"\(mcNS)\" xmlns:v=\"\(NS.v)\" "
                + "xmlns:pp=\"http://schemas.microsoft.com/office/powerpoint/2010/main\"><before/>\(body)<after/></root>"
            return try OOXMLNode.parse(Data(xml.utf8), preferringFallbackOver: [NS.v])
        }
        // A Choice requiring v is taken only when there is neither another supported Choice nor a Fallback.
        let fb = try parse("<mc:AlternateContent><mc:Choice Requires=\"v\"><c1/></mc:Choice><mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>")
        #expect(fb.children.map(\.name) == ["before", "fb", "after"])
        let other = try parse("<mc:AlternateContent><mc:Choice Requires=\"v\"><c1/></mc:Choice><mc:Choice Requires=\"pp\"><c2/></mc:Choice>"
                              + "<mc:Fallback><fb/></mc:Fallback></mc:AlternateContent>")
        #expect(other.children.map(\.name) == ["before", "c2", "after"])
        let only = try parse("<mc:AlternateContent><mc:Choice Requires=\"v\"><c1/></mc:Choice></mc:AlternateContent>")
        #expect(only.children.map(\.name) == ["before", "c1", "after"])
        // The default parse still takes the v Choice.
        let plain = try OOXMLNode.parse(Data(("<root xmlns:mc=\"\(mcNS)\" xmlns:v=\"\(NS.v)\"><mc:AlternateContent><mc:Choice Requires=\"v\"><c1/></mc:Choice>"
                                              + "<mc:Fallback><fb/></mc:Fallback></mc:AlternateContent></root>").utf8))
        #expect(plain.children.map(\.name) == ["c1"])
    }

    @Test func alternateContentWithoutFallbackDisappears() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="w16"><c1/></mc:Choice></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "after"])
        let r2 = try ac("<mc:AlternateContent><mc:Choice><c1/></mc:Choice></mc:AlternateContent>")
        #expect(r2.children.map(\.name) == ["before", "after"])
    }

    @Test func alternateContentPrefixDeclaredOnChoiceItself() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="a14" xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main"><c1/></mc:Choice></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "c1", "after"])
    }

    @Test func alternateContentNested() throws {
        let r = try ac("""
        <mc:AlternateContent><mc:Choice Requires="pp"><mc:AlternateContent><mc:Choice Requires="zz"><x/></mc:Choice><mc:Fallback><y/></mc:Fallback></mc:AlternateContent></mc:Choice></mc:AlternateContent>
        """)
        #expect(r.children.map(\.name) == ["before", "y", "after"])
    }

    @Test func supportedNamespaceList() {
        for uri in [
            "http://schemas.microsoft.com/office/powerpoint/2010/main",
            "http://schemas.microsoft.com/office/drawing/2010/main",
            "http://schemas.microsoft.com/office/powerpoint/2012/main",
            "http://schemas.microsoft.com/office/drawing/2014/main",
            "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
            "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
            "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing",
            "http://schemas.microsoft.com/office/word/2010/wordml",
            "http://schemas.microsoft.com/office/word/2012/wordml",
            "urn:schemas-microsoft-com:vml",
        ] { #expect(OOXMLNode.supportedMCNamespaces.contains(uri), "\(uri)") }
    }

    @Test func ignorableUnknownNamespacesAreKept() throws {
        let r = try parse("""
        <root xmlns="urn:r" xmlns:mc="\(mcNS)" xmlns:zz="urn:unknown" mc:Ignorable="zz"><zz:ext zz:foo="1">t</zz:ext></root>
        """)
        let e = try #require(r.child("ext"))
        #expect(e.ns == "urn:unknown")
        #expect(e.attr("foo", ns: "urn:unknown") == "1")
        #expect(e.text == "t")
    }

    // MARK: robustness

    @Test func malformedThrows() {
        #expect(throws: XMLError.self) { try parse("<a><b></a>") }
        #expect(throws: XMLError.self) { try parse("") }
        #expect(throws: XMLError.self) { try parse("not xml") }
        #expect(throws: XMLError.self) { try parse("<a/><b/>") }
    }

    @Test func doctypeIsRejectedAndExternalEntityNotRead() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("xxe-\(UUID().uuidString).txt")
        try "TOP-SECRET".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><d>&x;</d>"
        #expect(throws: XMLError.self) { try parse(xml) }
    }

    @Test func billionLaughsIsRejectedQuickly() {
        var dtd = "<!ENTITY l0 \"lol\">"
        for i in 1...9 { dtd += "<!ENTITY l\(i) \"" + String(repeating: "&l\(i - 1);", count: 10) + "\">" }
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE d [\(dtd)]><d>&l9;</d>"
        let start = Date()
        #expect(throws: XMLError.self) { try parse(xml) }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func utf16DoctypeIsRejected() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE d [<!ENTITY x \"y\">]><d>&x;</d>"
        let data = try #require(xml.data(using: .utf16LittleEndian))
        #expect(throws: XMLError.self) { try OOXMLNode.parse(data) }
    }

    @Test func utf16WithoutDoctypeParses() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><d>hé</d>"
        var data = Data([0xFF, 0xFE])
        data.append(try #require(xml.data(using: .utf16LittleEndian)))
        #expect(try OOXMLNode.parse(data).text == "hé")
    }

    @Test func excessiveDepthThrows() {
        let n = 5000
        let xml = String(repeating: "<a>", count: n) + String(repeating: "</a>", count: n)
        #expect(throws: XMLError.self) { try parse(xml) }
    }

    @Test func publicInit() {
        let child = OOXMLNode(name: "c", ns: NS.a)
        let n = OOXMLNode(name: "n", ns: NS.p, attributes: ["k": "v"], children: [child], text: "t")
        #expect(n.child("c") === child)
        #expect(n.attr("k") == "v")
        #expect(n.text == "t")
    }
}
