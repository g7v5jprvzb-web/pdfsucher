// TextBodyTests.swift — Task 10 (SlideKit tests)
// Text bodies: style cascade, bodyPr, fields, auto-numbering, empty placeholders, drawing.
import CoreGraphics
import Foundation
import OOXMLKit
import Testing
import TestSupport
@testable import SlideKit

extension X {
    /// `p:txBody` with the given paragraphs.
    static func body(_ paras: String, bodyPr: String = "<a:bodyPr/>", lst: String = "") -> String {
        "<p:txBody>\(bodyPr)<a:lstStyle>\(lst)</a:lstStyle>\(paras)</p:txBody>"
    }

    /// One paragraph with one run.
    static func para(_ text: String, pPr: String = "", rPr: String = "") -> String {
        "<a:p>\(pPr)<a:r>\(rPr)<a:t>\(text)</a:t></a:r></a:p>"
    }

    /// A non-placeholder text box (`txBox="1"`), optional `p:style`.
    static func textBox(_ id: Int, _ frame: CGRect, style: String = "", body: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"t\(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr>\(xfrm(frame))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\(style)\(body)</p:sp>"
    }

    static let noInsets = "lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\""

    static let txStyles = "<p:titleStyle><a:lvl1pPr algn=\"ctr\"><a:defRPr sz=\"4400\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
        + "<a:latin typeface=\"+mj-lt\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
        + "<p:bodyStyle><a:lvl1pPr marL=\"228600\" indent=\"-228600\"><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/>"
        + "<a:defRPr sz=\"2800\"><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr>"
        + "<a:lvl2pPr marL=\"742950\" indent=\"-285750\"><a:buFont typeface=\"Arial\"/><a:buChar char=\"–\"/>"
        + "<a:defRPr sz=\"2400\"/></a:lvl2pPr></p:bodyStyle>"
        + "<p:otherStyle><a:lvl1pPr><a:defRPr sz=\"1000\"/></a:lvl1pPr></p:otherStyle>"
}

extension Pixels {
    /// Bounding box (x, y, width, height in pixels) of pixels darker than `threshold` in every channel.
    func ink(in r: CGRect? = nil, threshold: UInt8 = 160) -> CGRect? {
        let area = r ?? CGRect(x: 0, y: 0, width: width, height: height)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in max(0, Int(area.minY))..<min(height, Int(area.maxY)) {
            for x in max(0, Int(area.minX))..<min(width, Int(area.maxX)) {
                let i = (y * width + x) * 4
                guard bytes[i + 3] > 0, bytes[i] < threshold, bytes[i + 1] < threshold, bytes[i + 2] < threshold else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Number of pixels in `r` whose color is within `tol` of `hex`.
    func count(_ hex: String, in r: CGRect, tol: Int = 40) -> Int {
        guard let v = Int(hex, radix: 16) else { return 0 }
        let want = [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
        var n = 0
        for y in max(0, Int(r.minY))..<min(height, Int(r.maxY)) {
            for x in max(0, Int(r.minX))..<min(width, Int(r.maxX)) {
                let i = (y * width + x) * 4
                if (0..<3).allSatisfy({ abs(Int(bytes[i + $0]) - want[$0]) <= tol }) { n += 1 }
            }
        }
        return n
    }
}

@Suite struct TextBodyTests {
    private func texts(_ o: OpenedDeck, _ i: Int = 0) throws -> SlideTextLayout {
        o.deck.store.textLayout(try #require(o.deck.slide(i)))
    }

    private static let georgiaTheme = PptxFixture.defaultTheme.replacingOccurrences(
        of: "<a:majorFont><a:latin typeface=\"Arial\"/>", with: "<a:majorFont><a:latin typeface=\"Georgia\"/>")

    /// Master/layout/slide title placeholders; the slide's has `body`.
    private func titleFixture(_ body: String, layoutLst: String = "") -> PptxFixture {
        var f = PptxFixture()
        f.theme = Self.georgiaTheme
        f.masterTxStyles = X.txStyles
        f.masterShapes = X.sp(2, CGRect(x: 40, y: 20, width: 880, height: 100), ph: "type=\"title\"")
        f.layoutShapes = X.sp(2, nil, ph: "type=\"title\"", txBody: X.body("<a:p/>", lst: layoutLst))
        f.slides = [.init(shapes: X.sp(2, nil, ph: "type=\"title\"", txBody: body))]
        return f
    }

    // MARK: cascade

    @Test func titleInheritsSizeFromTitleStyle() throws {
        let o = try titleFixture(X.body(X.para("Hello"))).open()
        let s = try #require(try texts(o).shapes.first)
        let run = try #require(s.paragraphs.first?.runs.first)
        #expect(run.style.size == 44)
        #expect(run.style.typeface == "Georgia")  // +mj-lt through the slide's theme
        #expect(run.style.color == RGBA(r: 0x11 / 255.0, g: 0x11 / 255.0, b: 0x11 / 255.0))
        #expect(s.paragraphs[0].style.align == .center)
        #expect(s.sets[0].plainText == "Hello")
    }

    @Test func cascadeOrderLayoutThenSlideThenRun() throws {
        let layoutLst = "<a:lvl1pPr><a:defRPr sz=\"3600\" b=\"1\"/></a:lvl1pPr>"
        let o = try titleFixture(X.body(X.para("A") + X.para("B", rPr: "<a:rPr lang=\"de-DE\" sz=\"2000\" i=\"1\"/>"),
                                        lst: "<a:lvl1pPr algn=\"r\"/>"), layoutLst: layoutLst).open()
        let s = try #require(try texts(o).shapes.first)
        #expect(s.paragraphs[0].runs[0].style.size == 36)
        #expect(s.paragraphs[0].runs[0].style.bold)
        #expect(s.paragraphs[0].style.align == .right)
        #expect(s.paragraphs[1].runs[0].style.size == 20)
        #expect(s.paragraphs[1].runs[0].style.bold)
        #expect(s.paragraphs[1].runs[0].style.italic)
    }

    @Test func levelTwoBulletInheritsMarginsAndChar() throws {
        var f = PptxFixture()
        f.masterTxStyles = X.txStyles
        f.masterShapes = X.sp(2, CGRect(x: 40, y: 120, width: 880, height: 380), ph: "type=\"body\" idx=\"1\"")
        f.layoutShapes = X.sp(2, nil, ph: "idx=\"1\"")
        let paras = X.para("Top") + X.para("Sub", pPr: "<a:pPr lvl=\"1\"/>") + X.para("Flat", pPr: "<a:pPr lvl=\"1\" indent=\"0\"/>")
        f.slides = [.init(shapes: X.sp(2, nil, ph: "idx=\"1\"", txBody: X.body(paras)))]
        let s = try #require(try texts(try f.open()).shapes.first)
        #expect(s.paragraphs[0].style.marginLeft == 18)
        #expect(s.paragraphs[0].runs[0].style.size == 28)
        let sub = s.paragraphs[1]
        #expect(sub.style.marginLeft == 58.5)
        #expect(sub.style.indentFirst == -22.5)
        #expect(sub.style.bullet == .char("–", typeface: "Arial", color: nil, sizePercent: nil))
        #expect(sub.runs[0].style.size == 24)
        #expect(s.sets[1].bullet?.text == "–")
        // Attribute-wise merge: the paragraph's indent replaces only the indent.
        #expect(s.paragraphs[2].style.marginLeft == 58.5)
        #expect(s.paragraphs[2].style.indentFirst == 0)
        #expect(s.paragraphs[2].style.bullet == sub.style.bullet)
    }

    @Test func nonPlaceholderUsesDefaultTextStyleAndFontRef() throws {
        var f = PptxFixture()
        f.theme = Self.georgiaTheme
        f.presentationExtra = "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"de-DE\"/></a:defPPr>"
            + "<a:lvl1pPr><a:defRPr sz=\"1600\"/></a:lvl1pPr></p:defaultTextStyle>"
        let style = "<p:style><a:lnRef idx=\"0\"><a:schemeClr val=\"accent1\"/></a:lnRef><a:fillRef idx=\"0\"><a:schemeClr val=\"accent1\"/></a:fillRef>"
            + "<a:effectRef idx=\"0\"><a:schemeClr val=\"accent1\"/></a:effectRef><a:fontRef idx=\"major\"><a:schemeClr val=\"accent3\"/></a:fontRef></p:style>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 100, y: 100, width: 600, height: 100), body: X.body(X.para("Plain")))
            + X.textBox(3, CGRect(x: 100, y: 300, width: 600, height: 120), style: style,
                        body: X.body(X.para("HHHH", rPr: "<a:rPr lang=\"de-DE\" sz=\"6000\"/>"), bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let o = try f.open()
        let t = try texts(o)
        #expect(t.shapes.count == 2)
        let plain = t.shapes[0].paragraphs[0].runs[0].style
        #expect(plain.size == 16)
        #expect(plain.typeface == "Arial")  // minor font
        #expect(plain.color == RGBA(r: 0x11 / 255.0, g: 0x11 / 255.0, b: 0x11 / 255.0))  // tx1 → dk1
        let styled = t.shapes[1].paragraphs[0].runs[0].style
        #expect(styled.color == RGBA(r: 1, g: 0, b: 0))  // fontRef color
        #expect(styled.typeface == "Georgia")  // fontRef idx major
        // Drawn in red.
        #expect(o.deck.pixels(0).count("FF0000", in: CGRect(x: 100, y: 300, width: 600, height: 120)) > 100)
    }

    /// Real decks' defaultTextStyle sets `solidFill tx1` and `latin +mn-lt`; the shape's fontRef must still win
    /// over it, and the shape's own properties over the fontRef.
    @Test func fontRefOverridesDefaultTextStyleFillAndFont() throws {
        var f = PptxFixture()
        f.theme = Self.georgiaTheme
        f.presentationExtra = "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"de-DE\"/></a:defPPr><a:lvl1pPr><a:defRPr sz=\"1800\">"
            + "<a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr></p:defaultTextStyle>"
        let style = "<p:style><a:lnRef idx=\"0\"><a:schemeClr val=\"accent1\"/></a:lnRef><a:fillRef idx=\"1\"><a:schemeClr val=\"accent1\"/></a:fillRef>"
            + "<a:effectRef idx=\"0\"><a:schemeClr val=\"accent1\"/></a:effectRef><a:fontRef idx=\"major\"><a:schemeClr val=\"lt1\"/></a:fontRef></p:style>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 100, y: 100, width: 300, height: 100), style: style, body: X.body(X.para("A")))
            + X.textBox(3, CGRect(x: 100, y: 300, width: 300, height: 100), style: style,
                        body: X.body(X.para("B", rPr: "<a:rPr lang=\"de-DE\"><a:solidFill><a:srgbClr val=\"00FF00\"/></a:solidFill><a:latin typeface=\"Menlo\"/></a:rPr>")))
            + X.textBox(4, CGRect(x: 100, y: 450, width: 300, height: 50), body: X.body(X.para("C"))))]
        let t = try texts(try f.open())
        let a = t.shapes[0].paragraphs[0].runs[0].style
        #expect(a.color == RGBA(r: 0xEE / 255.0, g: 0xEE / 255.0, b: 0xEE / 255.0))  // fontRef lt1, not tx1
        #expect(a.typeface == "Georgia")  // fontRef major, not +mn-lt
        let b = t.shapes[1].paragraphs[0].runs[0].style
        #expect(b.color == RGBA(r: 0, g: 1, b: 0))
        #expect(b.typeface == "Menlo")
        let c = t.shapes[2].paragraphs[0].runs[0].style
        #expect(c.color == RGBA(r: 0x11 / 255.0, g: 0x11 / 255.0, b: 0x11 / 255.0))  // no fontRef: defaultTextStyle tx1
        #expect(c.typeface == "Arial")
    }

    @Test func placeholdersDoNotUseDefaultTextStyle() throws {
        var f = titleFixture(X.body(X.para("Hello")))
        f.masterTxStyles = "<p:titleStyle><a:lvl1pPr><a:defRPr/></a:lvl1pPr></p:titleStyle>"
        f.presentationExtra = "<p:defaultTextStyle><a:lvl1pPr><a:defRPr sz=\"1000\" b=\"1\"/></a:lvl1pPr></p:defaultTextStyle>"
        let s = try #require(try texts(try f.open()).shapes.first)
        #expect(s.paragraphs[0].runs[0].style.size == 18)  // RunStyle default, not defaultTextStyle's 10
        #expect(!s.paragraphs[0].runs[0].style.bold)
    }

    @Test func hostileValuesDoNotTrap() throws {
        var f = PptxFixture()
        let paras = X.para("a", pPr: "<a:pPr lvl=\"99999999999999999999\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"9223372036854775807\"/></a:pPr>")
            + X.para("b", pPr: "<a:pPr lvl=\"-5\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"9223372036854775807\"/></a:pPr>")
            + X.para("c", pPr: "<a:pPr><a:buAutoNum type=\"arabicPeriod\" startAt=\"9223372036854775807\"/></a:pPr>")
            + X.para("d", pPr: "<a:pPr><a:buAutoNum type=\"arabicPeriod\" startAt=\"-9223372036854775808\"/></a:pPr>")
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300),
                                            body: X.body(paras, bodyPr: "<a:bodyPr numCol=\"1e20\" spcCol=\"1e300\" rot=\"1e308\"/>"))
            + X.textBox(3, CGRect(x: 0, y: 300, width: 400, height: 100),
                        body: X.body(X.para("x", rPr: "<a:rPr sz=\"1e300\" spc=\"-1e300\" baseline=\"1e300\"/>"),
                                     bodyPr: "<a:bodyPr numCol=\"-1e20\" lIns=\"1e300\"/>")))]
        let o = try f.open()
        let t = try texts(o)
        let s = try #require(t.shapes.first)
        #expect(s.sets.map { $0.bullet?.text } == ["32767.", "32768.", "32769.", "1."])  // lvl clamped to 0: one list
        _ = o.deck.pixels(0)
    }

    // MARK: bodyPr

    @Test func fontScaleShrinksText() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 100), body: X.body(X.para("Text")))
            + X.textBox(3, CGRect(x: 0, y: 200, width: 400, height: 100),
                        body: X.body(X.para("Text"), bodyPr: "<a:bodyPr><a:normAutofit fontScale=\"62500\" lnSpcReduction=\"20000\"/></a:bodyPr>")))]
        let t = try texts(try f.open())
        #expect(t.shapes[0].fontScale == 1)
        #expect(t.shapes[1].fontScale == 0.625)
        #expect(t.shapes[1].lineSpaceReduction == 0.2)
        let full = t.shapes[0].sets[0].lines[0].height, scaled = t.shapes[1].sets[0].lines[0].height
        #expect(abs(full - 21.6) < 0.01)
        #expect(abs(scaled - 21.6 * 0.625 * 0.8) < 0.01)
    }

    @Test func anchorCentresAndBottomAligns() throws {
        var f = PptxFixture()
        let frame = { (x: Double) in CGRect(x: x, y: 100, width: 200, height: 100) }
        f.slides = [.init(shapes: X.textBox(2, frame(0), body: X.body(X.para("Top")))
            + X.textBox(3, frame(300), body: X.body(X.para("HHH"), bodyPr: "<a:bodyPr anchor=\"ctr\" \(X.noInsets)/>"))
            + X.textBox(4, frame(600), body: X.body(X.para("Bot"), bodyPr: "<a:bodyPr anchor=\"b\" \(X.noInsets)/>")))]
        let o = try f.open()
        let t = try texts(o)
        // Default insets 0.1"/0.05": the box is inset, the text starts at its top.
        let box = t.shapes[0].boxSize, start = CGPoint.zero.applying(t.shapes[0].toSlide)
        #expect(abs(box.width - (200 - 14.4)) < 1e-6 && abs(box.height - (100 - 7.2)) < 1e-6)
        #expect(t.shapes[0].pieces[0].origin == .zero)
        #expect(abs(start.x - 7.2) < 1e-6 && abs(start.y - 103.6) < 1e-6)
        #expect(abs(t.shapes[1].pieces[0].origin.y - (100 - 21.6) / 2) < 0.01)
        #expect(abs(t.shapes[2].pieces[0].origin.y - (100 - 21.6)) < 0.01)
        // Pixels: the centred text's ink is centred on the shape (y 100…200).
        let ink = try #require(o.deck.pixels(0).ink(in: frame(300)))
        #expect(abs(ink.midY - 150) < 4)
    }

    @Test func vert270RotatesCounterClockwise() throws {
        var f = PptxFixture()
        let frame = CGRect(x: 400, y: 100, width: 40, height: 300)
        f.slides = [.init(shapes: X.textBox(2, frame, body: X.body(X.para("HHHHHHHH", rPr: "<a:rPr lang=\"de-DE\" sz=\"2000\"/>"),
                                                               bodyPr: "<a:bodyPr vert=\"vert270\" \(X.noInsets)/>"))
            + X.textBox(3, CGRect(x: 600, y: 100, width: 40, height: 300),
                        body: X.body(X.para("HHHHHHHH"), bodyPr: "<a:bodyPr vert=\"vert\" \(X.noInsets)/>")))]
        let o = try f.open()
        let t = try texts(o)
        let s = t.shapes[0]
        #expect(s.boxSize == CGSize(width: 300, height: 40))
        func dir(_ m: CGAffineTransform) -> CGPoint {
            let a = CGPoint.zero.applying(m), b = CGPoint(x: 1, y: 0).applying(m)
            return CGPoint(x: (b.x - a.x).rounded(), y: (b.y - a.y).rounded())
        }
        #expect(dir(s.toShape) == CGPoint(x: 0, y: -1))  // reading direction: upwards
        #expect(dir(t.shapes[1].toShape) == CGPoint(x: 0, y: 1))  // vert: downwards
        // The text starts at the bottom-left of the shape.
        let start = CGPoint.zero.applying(s.toSlide)
        #expect(abs(start.x - 400) < 0.01 && abs(start.y - 400) < 0.01)
        let ink = try #require(o.deck.pixels(0).ink(in: frame.insetBy(dx: -20, dy: -20)))
        #expect(ink.height > ink.width * 3)
    }

    @Test func textOutsideTheShapeIsNotClipped() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 100, y: 100, width: 40, height: 20),
                                            body: X.body(X.para("HHHHHHHHHH", rPr: "<a:rPr lang=\"de-DE\" sz=\"2000\"/>"),
                                                         bodyPr: "<a:bodyPr wrap=\"none\" \(X.noInsets)/>"))
            + X.textBox(3, CGRect(x: 500, y: 300, width: 200, height: 20),
                        body: X.body(X.para("HHH") + X.para("HHH") + X.para("HHH"), bodyPr: "<a:bodyPr anchor=\"b\" \(X.noInsets)/>")))]
        let o = try f.open()
        let t = try texts(o)
        // wrap="none": one line, wider than the shape.
        #expect(t.shapes[0].sets[0].lines.count == 1)
        #expect(t.shapes[0].sets[0].lines[0].width > 100)
        // Bottom anchor overflows upwards.
        #expect(t.shapes[1].pieces[0].origin.y < 0)
        let px = o.deck.pixels(0)
        let right = try #require(px.ink(in: CGRect(x: 100, y: 90, width: 400, height: 40)))
        #expect(right.maxX > 200)
        let above = try #require(px.ink(in: CGRect(x: 500, y: 200, width: 200, height: 130)))
        #expect(above.minY < 280)  // the shape starts at y 300
    }

    @Test func wrapNoneAlignsWithinTheBox() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 100, y: 100, width: 400, height: 40),
                                            body: X.body(X.para("HH", pPr: "<a:pPr algn=\"ctr\"/>"),
                                                         bodyPr: "<a:bodyPr wrap=\"none\" \(X.noInsets)/>")))]
        let o = try f.open()
        let ink = try #require(o.deck.pixels(0).ink(in: CGRect(x: 0, y: 90, width: 960, height: 60)))
        #expect(abs(ink.midX - 300) < 3)
    }

    @Test func scalingGroupScalesTheBoxButNotTheText() throws {
        var f = PptxFixture()
        // Child space 200×50 shown at 200×150: the box triples in height, the 18 pt text keeps its size.
        let child = X.textBox(3, CGRect(x: 0, y: 0, width: 200, height: 50),
                              body: X.body(X.para("HHH"), bodyPr: "<a:bodyPr anchor=\"b\" \(X.noInsets)/>"))
        f.slides = [.init(shapes: "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"2\" name=\"g\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>"
            + "<a:xfrm><a:off x=\"\(X.emu(100))\" y=\"\(X.emu(100))\"/><a:ext cx=\"\(X.emu(200))\" cy=\"\(X.emu(150))\"/>"
            + "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(X.emu(200))\" cy=\"\(X.emu(50))\"/></a:xfrm></p:grpSpPr>\(child)</p:grpSp>")]
        let o = try f.open()
        let s = try #require(try texts(o).shapes.first)
        #expect(abs(s.boxSize.height - 150) < 1e-6)
        #expect(abs(s.sets[0].lines[0].height - 21.6) < 0.01)
        let top = CGPoint(x: 0, y: s.pieces[0].origin.y).applying(s.toSlide)
        #expect(abs(top.y - (250 - 21.6)) < 0.01)
        // Drawn unstretched: the ink of one 18 pt line is less than 21.6 px high and sits at the bottom.
        let ink = try #require(o.deck.pixels(0).ink(in: CGRect(x: 100, y: 100, width: 200, height: 150)))
        #expect(ink.height < 21.6 && ink.maxY > 235)
    }

    // MARK: fields

    @Test func slideNumberCountsHiddenSlides() throws {
        var f = PptxFixture()
        let fld = { (t: String) in "<a:p><a:fld id=\"{1}\" type=\"slidenum\"><a:rPr lang=\"de-DE\"/><a:t>\(t)</a:t></a:fld></a:p>" }
        let shapes = X.textBox(2, CGRect(x: 0, y: 0, width: 200, height: 50), body: X.body(fld("&lt;#&gt;")))
            + X.textBox(3, CGRect(x: 0, y: 100, width: 200, height: 50), body: X.body(fld("7")))
            + X.textBox(4, CGRect(x: 0, y: 200, width: 200, height: 50),
                        body: X.body("<a:p><a:r><a:t>Am </a:t></a:r><a:fld id=\"{2}\" type=\"datetime1\"><a:t>12.11.2026</a:t></a:fld>"
                                     + "<a:fld id=\"{3}\" type=\"other\"><a:t>!</a:t></a:fld></a:p>"))
        f.slides = [.init(), .init(rootAttrs: "show=\"0\""), .init(shapes: shapes)]
        let o = try f.open()
        #expect(o.deck.slideCount == 2)
        let t = try texts(o, 1)
        #expect(t.shapes.map { $0.sets.first?.plainText } == ["3", "3", "Am 12.11.2026!"])
    }

    // MARK: numbering

    @Test func autoNumberingCountsPerLevel() throws {
        var f = PptxFixture()
        let num = { (lvl: Int, scheme: String) in
            "<a:pPr marL=\"342900\" lvl=\"\(lvl)\" indent=\"-342900\"><a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"\(scheme)\"/></a:pPr>"
        }
        let paras = X.para("a", pPr: num(0, "arabicPeriod")) + X.para("b", pPr: num(0, "arabicPeriod"))
            + X.para("c", pPr: num(0, "arabicPeriod")) + X.para("d", pPr: num(1, "alphaLcParenR"))
            + X.para("e", pPr: num(0, "arabicPeriod")) + X.para("f", pPr: num(0, "romanUcPeriod"))
            + X.para("g", pPr: "<a:pPr><a:buAutoNum type=\"arabicPeriod\" startAt=\"5\"/></a:pPr>")
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 400, height: 300), body: X.body(paras)))]
        let s = try #require(try texts(try f.open()).shapes.first)
        #expect(s.sets.map { $0.bullet?.text } == ["1.", "2.", "3.", "a)", "4.", "I.", "5."])
    }

    // MARK: empty placeholders and matching

    @Test func emptyPlaceholdersDrawNothing() throws {
        var f = PptxFixture()
        f.layoutShapes = X.sp(2, CGRect(x: 100, y: 100, width: 200, height: 100), fill: "0000FF", ph: "idx=\"1\"")
            + X.sp(3, CGRect(x: 500, y: 100, width: 200, height: 100), fill: "FF0000", ph: "type=\"pic\" idx=\"2\"")
        let empty = X.body("<a:p><a:endParaRPr lang=\"de-DE\"/></a:p>")
        f.slides = [
            .init(shapes: X.sp(2, nil, ph: "idx=\"1\"", txBody: empty) + X.sp(3, nil, ph: "type=\"pic\" idx=\"2\"")),
            .init(shapes: X.sp(2, nil, ph: "idx=\"1\"", txBody: X.body(X.para("x")))),
            .init(shapes: X.sp(2, nil, fill: "00FF00", ph: "idx=\"1\"", txBody: empty)),
        ]
        let d = try f.open().deck
        #expect(d.pixels(0).hex(150, 180) == "FFFFFF")
        #expect(d.pixels(0).hex(600, 150) == "FFFFFF")
        #expect(d.pixels(1).hex(150, 180) == "0000FF")
        #expect(d.pixels(2).hex(150, 180) == "00FF00")
    }

    @Test func slidePlaceholderIdxDoesNotTakeAnotherIdxOfTheSameType() throws {
        let ph = { (type: String?, idx: Int?) in Placeholder(type: Placeholder.normalize(type), idx: idx, node: OOXMLNode(name: "sp")) }
        #expect(ph("body", 14).match(in: [ph("body", 13)], slideToLayout: true) == nil)
        #expect(ph("body", 14).match(in: [ph("body", 13)])?.idx == 13)  // layout → master stays lenient
        #expect(ph("body", 14).match(in: [ph("body", nil)], slideToLayout: true) != nil)
        #expect(ph("title", 7).match(in: [ph("title", 0)], slideToLayout: true)?.type == "title")
        #expect(ph("sldNum", 9).match(in: [ph("sldNum", 12)], slideToLayout: true)?.idx == 12)
        #expect(ph(nil, 14).match(in: [ph("body", 13)], slideToLayout: true) == nil)

        var f = PptxFixture()
        f.layoutShapes = X.sp(2, CGRect(x: 100, y: 100, width: 200, height: 100), fill: "0000FF", ph: "type=\"body\" idx=\"13\"")
        f.slides = [.init(shapes: X.sp(2, CGRect(x: 500, y: 300, width: 200, height: 100), ph: "type=\"body\" idx=\"14\"",
                                       txBody: X.body(X.para("x"))))]
        let o = try f.open()
        let m = o.deck.store.slideModel(try #require(o.deck.slide(0)).partPath)
        #expect(m.texts.first?.inheritedTxBodies.isEmpty == true)
        let px = o.deck.pixels(0)
        #expect(px.hex(150, 150) == "FFFFFF")
        #expect(px.hex(650, 380) == "FFFFFF")
    }

    // MARK: Task 11 hook

    @Test func wordRectsAreInSlideCoordinates() throws {
        var f = PptxFixture()
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 100, y: 200, width: 400, height: 100),
                                            body: X.body(X.para("Hallo Welt"), bodyPr: "<a:bodyPr \(X.noInsets)/>")))]
        let t = try texts(try f.open())
        let words = t.shapes[0].slideWordRects()
        #expect(words.count == 2)
        #expect(words.allSatisfy { $0.paragraph == 0 })
        #expect(words[0].range == NSRange(location: 0, length: 5))
        let r = words[0].rect
        #expect(r.minX >= 100 && r.minX < 102 && r.minY >= 200 && r.maxY <= 222)
        #expect(words[1].rect.minX > r.maxX)
    }
}
