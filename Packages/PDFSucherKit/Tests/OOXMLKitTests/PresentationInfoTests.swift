import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private let relNS = NS.relPkg
private let pres = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
private let presM = "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml"

private func deck(attrs: String = "", sz: String = "<p:sldSz cx=\"12192000\" cy=\"6858000\"/>",
                  ids: [(String, String)] = [("256", "rId1"), ("257", "rId2"), ("258", "rId3"), ("259", "rId4")],
                  hidden: Set<Int> = [2], missingParts: Set<Int> = [], rootRels: Bool = true,
                  contentType: String? = pres, dangling: Bool = false) throws -> OPCPackage {
    var b = OOXMLBuilder()
    if let contentType {
        b.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(contentType)\"/></Types>")
    }
    if rootRels {
        b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
    }
    let list = ids.map { "<p:sldId id=\"\($0.0)\" r:id=\"\($0.1)\"/>" }.joined()
    b.add("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(NS.p)\" xmlns:r=\"\(NS.r)\" \(attrs)><p:sldIdLst>\(list)</p:sldIdLst>\(sz)</p:presentation>")
    var rels = ""
    for i in 1...4 {
        rels += "<Relationship Id=\"rId\(i)\" Type=\"http://x/slide\" Target=\"slides/slide\(i).xml\"/>"
        if missingParts.contains(i) { continue }
        b.add("ppt/slides/slide\(i).xml", "<p:sld xmlns:p=\"\(NS.p)\"\(hidden.contains(i) ? " show=\"0\"" : "")/>")
    }
    b.add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relNS)\">\(rels)</Relationships>")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString).zip")
    try b.build().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return OPCPackage(zip: try ZipArchive(url: url))
}

@Suite struct PresentationInfoTests {
    @Test func hiddenSlideAndNumbers() throws {
        let info = try PresentationInfo(package: deck())
        #expect(info.presentationPart == "ppt/presentation.xml")
        #expect(info.slides.count == 4)
        #expect(info.slides[1].hidden)
        #expect(info.visibleSlides.map(\.powerPointNumber) == [1, 3, 4])
        #expect(info.visibleSlides.map(\.partPath) == ["ppt/slides/slide1.xml", "ppt/slides/slide3.xml", "ppt/slides/slide4.xml"])
        #expect(info.slideSize == CGSize(width: 960, height: 540))
    }

    @Test func firstSlideNum() throws {
        let info = try PresentationInfo(package: deck(attrs: "firstSlideNum=\"0\""))
        #expect(info.visibleSlides.map(\.powerPointNumber) == [0, 2, 3])
    }

    @Test func defaultSize() throws {
        #expect(try PresentationInfo(package: deck(sz: "")).slideSize == CGSize(width: 720, height: 540))
    }

    @Test func missingPresentation() throws {
        let p = try deck(rootRels: false, contentType: nil)
        #expect(throws: PresentationInfoError.noPresentation) { try PresentationInfo(package: p) }
    }

    @Test func danglingRelationshipIdAndMissingPartAreSkipped() throws {
        let info = try PresentationInfo(package: deck(
            ids: [("1", "rId1"), ("2", "rId9"), ("3", "rId2"), ("4", "rId3"), ("5", "rId4")],
            hidden: [], missingParts: [2]))
        #expect(info.slides.map(\.partPath) == ["ppt/slides/slide1.xml", "ppt/slides/slide3.xml", "ppt/slides/slide4.xml"])
        #expect(info.slides.map(\.powerPointNumber) == [1, 2, 3])
    }

    @Test func fallsBackToContentTypes() throws {
        let info = try PresentationInfo(package: deck(rootRels: false))
        #expect(info.presentationPart == "ppt/presentation.xml")
    }

    @Test func pptmContentType() throws {
        let info = try PresentationInfo(package: deck(rootRels: false, contentType: presM))
        #expect(info.slides.count == 4)
    }

    @Test func unparseableSlideCountsAsVisible() throws {
        var b = OOXMLBuilder()
        b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"r1\" Type=\"x/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        b.add("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(NS.p)\" xmlns:r=\"\(NS.r)\"><p:sldIdLst><p:sldId id=\"1\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>")
        b.add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"x/slide\" Target=\"slides/s.xml\"/></Relationships>")
        b.add("ppt/slides/s.xml", "<p:sld show=\"0\"><oops>")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString).zip")
        try b.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try PresentationInfo(package: OPCPackage(zip: try ZipArchive(url: url)))
        #expect(info.slides.map(\.hidden) == [false])
    }

    @Test func malformedPresentation() throws {
        var b = OOXMLBuilder()
        b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"r1\" Type=\"x/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        b.add("ppt/presentation.xml", "<p:presentation><oops>")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString).zip")
        try b.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pkg = OPCPackage(zip: try ZipArchive(url: url))
        #expect(throws: PresentationInfoError.self) { try PresentationInfo(package: pkg) }
    }

    @Test func showFalseIsHidden() throws {
        // `show="false"` is the xsd:boolean spelling
        var b = OOXMLBuilder()
        b.add("_rels/.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"r1\" Type=\"x/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        b.add("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(NS.p)\" xmlns:r=\"\(NS.r)\"><p:sldIdLst><p:sldId id=\"1\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>")
        b.add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"x/slide\" Target=\"slides/s.xml\"/></Relationships>")
        b.add("ppt/slides/s.xml", "<p:sld xmlns:p=\"\(NS.p)\" show=\"false\"/>")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString).zip")
        try b.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try PresentationInfo(package: OPCPackage(zip: try ZipArchive(url: url)))
        #expect(info.visibleSlides.isEmpty)
    }
}
