import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private func package(_ build: (inout OOXMLBuilder) -> Void) throws -> OPCPackage {
    var b = OOXMLBuilder()
    build(&b)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("opc-\(UUID().uuidString).zip")
    try b.build().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return OPCPackage(zip: try ZipArchive(url: url))
}

private let ctNS = "http://schemas.openxmlformats.org/package/2006/content-types"
private let pptxMain = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"

private let contentTypes = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="\(ctNS)"><Default Extension="xml" ContentType="application/xml"/>\
<Override PartName="/ppt/presentation.xml" ContentType="\(pptxMain)"/>\
<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>
"""

@Suite struct OPCPackageTests {
    @Test func resolveRelativeTargets() throws {
        let p = try package { $0.add("x", "x") }
        #expect(p.resolve("../media/image1.png", from: "ppt/slides/slide1.xml") == "ppt/media/image1.png")
        #expect(p.resolve("slide2.xml", from: "ppt/slides/slide1.xml") == "ppt/slides/slide2.xml")
        #expect(p.resolve("./slide2.xml", from: "ppt/slides/slide1.xml") == "ppt/slides/slide2.xml")
        #expect(p.resolve("slides/slide1.xml", from: "ppt/presentation.xml") == "ppt/slides/slide1.xml")
        #expect(p.resolve("ppt/presentation.xml", from: "") == "ppt/presentation.xml")
        #expect(p.resolve("document.xml", from: "word/document.xml") == "word/document.xml")
        #expect(p.resolve("a/./b/../c.xml", from: "x/y.xml") == "x/a/c.xml")
        #expect(p.resolve("../../../up.xml", from: "a/b.xml") == "up.xml")
    }

    @Test func resolveAbsoluteAndEncodedTargets() throws {
        let p = try package { $0.add("x", "x") }
        #expect(p.resolve("/ppt/media/image1.png", from: "ppt/slides/slide1.xml") == "ppt/media/image1.png")
        #expect(p.resolve("../media/my%20image%C3%A4.png", from: "ppt/slides/slide1.xml") == "ppt/media/my imageä.png")
        #expect(p.resolve("/word/media/a%20b.png", from: "word/document.xml") == "word/media/a b.png")
    }

    @Test func relationships() throws {
        let p = try package {
            $0.add("_rels/.rels", """
            <Relationships xmlns="\(NS.relPkg)"><Relationship Id="rId1" Type="http://x/officeDocument" Target="ppt/presentation.xml"/></Relationships>
            """)
            $0.add("ppt/_rels/presentation.xml.rels", """
            <Relationships xmlns="\(NS.relPkg)">\
            <Relationship Id="rId1" Type="http://x/slide" Target="slides/slide1.xml"/>\
            <Relationship Id="rId2" Type="http://x/hyperlink" Target="https://example.com/" TargetMode="External"/>\
            <Relationship Id="rId3" Type="http://x/slide" Target="slides/slide2.xml" TargetMode="Internal"/></Relationships>
            """)
        }
        let root = p.relationships(of: "")
        #expect(root["rId1"] == Relationship(id: "rId1", type: "http://x/officeDocument", target: "ppt/presentation.xml", external: false))
        let rels = p.relationships(of: "ppt/presentation.xml")
        #expect(rels.count == 3)
        #expect(rels["rId1"]?.target == "slides/slide1.xml")
        #expect(rels["rId2"]?.external == true)
        #expect(rels["rId2"]?.target == "https://example.com/")
        #expect(rels["rId3"]?.external == false)
    }

    @Test func missingOrBrokenRelsGiveEmptyDictionary() throws {
        let p = try package {
            $0.add("a/_rels/broken.xml.rels", "<Relationships><oops>")
            $0.add("a/broken.xml", "<x/>")
        }
        #expect(p.relationships(of: "nothing/here.xml").isEmpty)
        #expect(p.relationships(of: "").isEmpty)
        #expect(p.relationships(of: "a/broken.xml").isEmpty)
        #expect(p.relationships(of: "top.xml").isEmpty)
    }

    @Test func topLevelPartRels() throws {
        let p = try package {
            $0.add("_rels/top.xml.rels", "<Relationships xmlns=\"\(NS.relPkg)\"><Relationship Id=\"a\" Type=\"t\" Target=\"b.xml\"/></Relationships>")
        }
        #expect(p.relationships(of: "top.xml")["a"]?.target == "b.xml")
        #expect(p.relationships(of: "/top.xml")["a"]?.target == "b.xml")
    }

    @Test func mainPart() throws {
        let p = try package { $0.add("[Content_Types].xml", contentTypes) }
        #expect(p.mainPart(forType: pptxMain) == "ppt/presentation.xml")
        #expect(p.mainPart(forType: "application/none") == nil)
    }

    @Test func mainPartNilWithoutOrWithBrokenContentTypes() throws {
        let none = try package { $0.add("a.xml", "<a/>") }
        #expect(none.mainPart(forType: pptxMain) == nil)
        let broken = try package { $0.add("[Content_Types].xml", "<Types><x>") }
        #expect(broken.mainPart(forType: pptxMain) == nil)
    }

    @Test func dataAndXML() throws {
        let p = try package {
            $0.add("ppt/slides/slide1.xml", "<p:sld xmlns:p=\"\(NS.p)\"/>")
            $0.addData("ppt/media/i.bin", Data([1, 2, 3]))
        }
        #expect(try p.data("ppt/media/i.bin") == Data([1, 2, 3]))
        let n = try p.xml("ppt/slides/slide1.xml")
        #expect(n.name == "sld" && n.ns == NS.p)
        #expect(try p.data("/ppt/media/i.bin") == Data([1, 2, 3]))
    }

    @Test func partNamesAreCaseInsensitive() throws {
        let p = try package { $0.add("PPT/Slides/Slide1.XML", "<a/>") }
        #expect(try p.xml("ppt/slides/slide1.xml").name == "a")
        #expect(try p.data("PPT/Slides/Slide1.XML").isEmpty == false)
    }

    @Test func missingPartThrows() throws {
        let p = try package { $0.add("a.xml", "<a/>") }
        #expect(throws: ZipError.self) { try p.data("nope.xml") }
        #expect(throws: ZipError.self) { try p.xml("nope.xml") }
    }

    @Test func malformedPartThrowsXMLError() throws {
        let p = try package { $0.add("a.xml", "<a><b>") }
        #expect(throws: XMLError.self) { try p.xml("a.xml") }
    }
}
