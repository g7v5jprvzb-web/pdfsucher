import CoreGraphics
import Foundation
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

@Suite struct SlideModelTests {
    private func ph(_ type: String?, _ idx: Int?) -> Placeholder {
        Placeholder(type: Placeholder.normalize(type), idx: idx, node: OOXMLNode(name: "sp"))
    }

    @Test func placeholderTypeNormalisation() {
        #expect(Placeholder.normalize(nil) == "obj")
        #expect(Placeholder.normalize("ctrTitle") == "title")
        #expect(Placeholder.normalize("subTitle") == "body")
        #expect(Placeholder.normalize("dt") == "dt")
    }

    @Test func placeholderMatching() {
        let master = [ph("title", nil), ph("body", 1), ph("dt", 2), ph("ftr", 3), ph("sldNum", 4)]
        // idx equal and compatible first.
        #expect(ph(nil, 1).match(in: master)?.type == "body")
        // Layout content placeholder idx 2 must not take the master's date (idx 2): falls back to obj ↔ body.
        #expect(ph(nil, 2).match(in: master)?.type == "body")
        // Type match when the idx differs (layout dt idx 10 → master dt idx 2).
        #expect(ph("dt", 10).match(in: master)?.idx == 2)
        #expect(ph("ctrTitle", nil).match(in: master)?.type == "title")
        #expect(ph("subTitle", 1).match(in: master)?.type == "body")
        #expect(ph("pic", 13).match(in: master) == nil)
        // A typed slide placeholder takes a layout obj with the same idx.
        #expect(ph("chart", 13).match(in: [ph(nil, 13)])?.idx == 13)
        #expect(ph("title", nil).match(in: [ph(nil, 0), ph("title", nil)])?.type == "title")
    }

    private func model(_ f: PptxFixture) throws -> (OpenedDeck, SlideModel) {
        let opened = try f.open()
        let ref = try #require(opened.deck.slide(0))
        return (opened, opened.deck.store.slideModel(ref.partPath))
    }

    @Test func textSourcesCarryTheInheritanceChain() throws {
        var f = PptxFixture()
        let body = { (lvl: String) in "<p:txBody><a:bodyPr anchor=\"\(lvl)\"/><a:lstStyle/><a:p><a:r><a:t>\(lvl)</a:t></a:r></a:p></p:txBody>" }
        f.masterShapes = X.sp(2, CGRect(x: 0, y: 0, width: 10, height: 10), ph: "type=\"body\" idx=\"1\"", txBody: body("m"))
        f.layoutShapes = X.sp(2, nil, ph: "idx=\"1\"", txBody: body("l"))
        f.slides = [.init(shapes: X.sp(2, nil, ph: "idx=\"1\"", txBody: body("s")) + X.sp(3, CGRect(x: 0, y: 0, width: 5, height: 5)))]
        let (_, m) = try model(f)
        #expect(m.elements.count == 2)
        guard case .shape(let s) = m.elements[0], let tag = s.tag else { Issue.record("expected tagged shape"); return }
        let t = m.texts[tag]
        #expect(t.layer == .slide)
        #expect(t.placeholder?.idx == 1)
        #expect(t.txBody?.child("bodyPr")?.attr("anchor") == "s")
        #expect(t.inheritedTxBodies.map { $0.child("bodyPr")?.attr("anchor") } == ["l", "m"])
        // A shape without text gets no tag.
        guard case .shape(let plain) = m.elements[1] else { Issue.record("expected shape"); return }
        #expect(plain.tag == nil)
        #expect(m.master?.root.name == "sldMaster")
        #expect(m.layout?.root.name == "sldLayout")
    }

    @Test func graphicFrameIsModelledButNotDrawn() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"4\" name=\"t\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"\(X.emu(10))\" y=\"\(X.emu(20))\"/><a:ext cx=\"\(X.emu(100))\" cy=\"\(X.emu(50))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl/></a:graphicData></a:graphic></p:graphicFrame>"
            + "<p:contentPart r:id=\"rId5\"/>")]
        let (_, m) = try model(f)
        #expect(m.elements.count == 1)
        guard case .graphicFrame(let g) = m.elements.first else { Issue.record("expected graphic frame"); return }
        #expect(g.transform.frame == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(g.graphicData?.attr("uri")?.hasSuffix("/table") == true)
    }

    @Test func modelsAreCachedAndShared() throws {
        let opened = try PptxFixture().open()
        let copy = opened.deck
        #expect(copy.store === opened.deck.store)
        let path = try #require(copy.slide(0)).partPath
        let a = copy.store.layer(path, kind: .slide)
        let b = opened.deck.store.layer(path, kind: .slide)
        #expect(a?.root === b?.root)
    }
}
