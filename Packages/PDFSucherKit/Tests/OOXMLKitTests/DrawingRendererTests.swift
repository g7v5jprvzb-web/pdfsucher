import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private let red = RGBA(r: 1, g: 0, b: 0)
private let blue = RGBA(r: 0, g: 0, b: 1)

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rotation: Double = 0,
                  flipH: Bool = false, flipV: Bool = false) -> Transform2D {
    Transform2D(offset: CGPoint(x: x, y: y), extent: CGSize(width: w, height: h), rotation: rotation,
                flipH: flipH, flipV: flipV)
}

@Suite struct DrawingRendererTests {
    let r: DrawingRenderer
    init() throws { r = renderer(try emptyPackage()) }

    @Test func solidFillInCentre() {
        let c = Canvas()
        r.drawShape(ShapeModel(transform: rect(50, 25, 100, 50), fill: .solid(red)), in: c.ctx)
        #expect(c.matches(100, 50, 255, 0, 0))
        #expect(c.matches(52, 27, 255, 0, 0))
        #expect(c.isClear(10, 10) && c.isClear(48, 50) && c.isClear(100, 23) && c.isClear(152, 50))
    }

    @Test func rotation90SwapsExtent() {
        let c = Canvas()
        // 100×20 centred at (100,50), rotated 90° → occupies x 90…110, y 0…100.
        r.drawShape(ShapeModel(transform: rect(50, 40, 100, 20, rotation: 90), fill: .solid(red)), in: c.ctx)
        #expect(c.matches(100, 3, 255, 0, 0) && c.matches(100, 96, 255, 0, 0))
        #expect(c.isClear(60, 50) && c.isClear(140, 50) && c.isClear(87, 50))
    }

    @Test func flipHMirrorsArrow() {
        let arrow = Geometry.preset("rightArrow", adjust: [:])
        let normal = Canvas(), flipped = Canvas()
        r.drawShape(ShapeModel(transform: rect(50, 25, 100, 50), geometry: arrow, fill: .solid(red)), in: normal.ctx)
        r.drawShape(ShapeModel(transform: rect(50, 25, 100, 50, flipH: true), geometry: arrow, fill: .solid(red)),
                    in: flipped.ctx)
        // Head (base at x=125, full height) is right normally, left when flipped; shaft is y 37.5…62.5.
        #expect(normal.matches(127, 28, 255, 0, 0) && normal.isClear(73, 28))
        #expect(flipped.matches(73, 28, 255, 0, 0) && flipped.isClear(127, 28))
        #expect(normal.matches(55, 50, 255, 0, 0) && flipped.matches(145, 50, 255, 0, 0))
    }

    @Test func flipVAndRotationCombine() {
        // A right triangle (rtTriangle: right angle bottom-left). flipV puts the right angle top-left.
        let tri = Geometry.preset("rtTriangle", adjust: [:])
        let c = Canvas()
        r.drawShape(ShapeModel(transform: rect(0, 0, 100, 100, flipV: true), geometry: tri, fill: .solid(red)), in: c.ctx)
        #expect(c.matches(5, 5, 255, 0, 0) && c.matches(5, 80, 255, 0, 0) && c.isClear(20, 95) && c.isClear(95, 95))
    }

    @Test func groupTransformScalesChildren() {
        let c = Canvas()
        let child = ShapeModel(transform: rect(100, 100, 200, 100), fill: .solid(red))
        let g = GroupModel(transform: Transform2D(offset: CGPoint(x: 20, y: 10), extent: CGSize(width: 100, height: 50),
                                                  childOffset: CGPoint(x: 100, y: 100),
                                                  childExtent: CGSize(width: 200, height: 100)),
                           children: [.shape(child)])
        r.drawGroup(g, in: c.ctx)
        // Child fills the whole child space → parent (20,10)-(120,60).
        #expect(c.matches(22, 12, 255, 0, 0) && c.matches(118, 58, 255, 0, 0))
        #expect(c.isClear(18, 30) && c.isClear(122, 30) && c.isClear(60, 62))
    }

    @Test func groupScalingDoesNotScaleLineWidths() {
        // A 2 pt line in a group whose child space 10×5 maps onto 100×50 (10×): the line is 100 pt long, still 2 pt wide.
        let c = Canvas()
        let child = ShapeModel(transform: rect(0, 2.5, 10, 0), geometry: .preset("line", adjust: [:]),
                               line: Line(width: 2, fill: .solid(red)))
        let g = GroupModel(transform: Transform2D(offset: CGPoint(x: 50, y: 25), extent: CGSize(width: 100, height: 50),
                                                  childOffset: .zero, childExtent: CGSize(width: 10, height: 5)),
                           children: [.shape(child)])
        r.drawGroup(g, in: c.ctx)
        #expect(c.matches(60, 50, 255, 0, 0) && c.matches(140, 50, 255, 0, 0))
        #expect(c.isClear(100, 47) && c.isClear(100, 53))   // a 10× width would cover y 40…60
        #expect(c.isClear(45, 50) && c.isClear(155, 50))
    }

    @Test func flatGroupStillDrawsItsHorizontalLines() throws {
        // ext cy = 0 with chExt cy > 0 (a group of horizontal lines saved flat): the y scale is 0, the lines still show.
        let c = Canvas()
        let child = ShapeModel(transform: rect(0, 5, 10, 0), geometry: .preset("line", adjust: [:]),
                               line: Line(width: 2, fill: .solid(red)))
        let g = GroupModel(transform: Transform2D(offset: CGPoint(x: 50, y: 50), extent: CGSize(width: 100, height: 0),
                                                  childOffset: .zero, childExtent: CGSize(width: 10, height: 10)),
                           children: [.shape(child)])
        r.drawGroup(g, in: c.ctx)
        #expect(c.matches(60, 50, 255, 0, 0) && c.matches(140, 50, 255, 0, 0))
        #expect(c.isClear(100, 55) && c.isClear(45, 50))
        // The split is well-defined for a zero axis (either one or both): finite, rest orthonormal.
        for m in [CGAffineTransform(scaleX: 10, y: 0), CGAffineTransform(scaleX: 0, y: 3),
                  CGAffineTransform(scaleX: 0, y: 0), CGAffineTransform(scaleX: -2, y: 0).translatedBy(x: 4, y: 5)] {
            let split = try #require(GroupScale(m))
            let r = split.rest
            let finite = [r.a, r.b, r.c, r.d, r.tx, r.ty].allSatisfy(\.isFinite)
            #expect(finite)
            #expect(abs(hypot(r.a, r.b) - 1) < 1e-9 && abs(hypot(r.c, r.d) - 1) < 1e-9 && abs(r.a * r.c + r.b * r.d) < 1e-9)
            #expect(split.scale == CGSize(width: hypot(m.a, m.b), height: hypot(m.c, m.d)))
        }
        #expect(GroupScale(CGAffineTransform(scaleX: .nan, y: 1)) == nil)
        #expect(GroupScale(CGAffineTransform(scaleX: .infinity, y: 0)) == nil)
    }

    @Test func nonUniformGroupScalingKeepsLineWidthsAndBuildsGeometryAtTheScaledSize() {
        // Child space 10×10 → 100×20 (10× by 2×): a 1 pt outline stays 1 pt on every side; the text callback gets
        // the shape box in the scaled size (text is never stretched by a group).
        let c = Canvas()
        let child = ShapeModel(transform: rect(0, 0, 10, 10), line: Line(width: 1, fill: .solid(blue)))
        let g = GroupModel(transform: Transform2D(offset: CGPoint(x: 50, y: 40), extent: CGSize(width: 100, height: 20),
                                                  childOffset: .zero, childExtent: CGSize(width: 10, height: 10)),
                           children: [.shape(child)])
        var textRect = CGRect.null
        r.drawGroup(g, in: c.ctx) { _, _, rect in textRect = rect }
        #expect(c.matches(100, 40, 0, 0, 255, tol: 130) && c.isClear(100, 43))   // top edge ~1 pt (not 2)
        #expect(c.matches(50, 50, 0, 0, 255, tol: 130) && c.isClear(54, 50))     // left edge ~1 pt (not 10)
        #expect(abs(textRect.width - 100) < 0.01 && abs(textRect.height - 20) < 0.01)
    }

    @Test func uprightChildInStretchedGroupKeepsItsVisualBox() {
        // A 4×10 box turned by 90° covers x 0…10, y 3…7 of a 10×10 child space; the group stretches 10× by 2× onto
        // (50,40)-(150,60), so the box must cover x 50…150, y 46…54 (the scale factors swap for upright boxes).
        let c = Canvas()
        let child = ShapeModel(transform: rect(3, 0, 4, 10, rotation: 90), fill: .solid(red))
        let g = GroupModel(transform: Transform2D(offset: CGPoint(x: 50, y: 40), extent: CGSize(width: 100, height: 20),
                                                  childOffset: .zero, childExtent: CGSize(width: 10, height: 10)),
                           children: [.shape(child)])
        r.drawGroup(g, in: c.ctx)
        #expect(c.matches(52, 50, 255, 0, 0) && c.matches(148, 50, 255, 0, 0) && c.matches(100, 47, 255, 0, 0))
        #expect(c.isClear(100, 44) && c.isClear(100, 56) && c.isClear(47, 50))
    }

    @Test func groupFillIsPassedDownAndNestedGroupsCompose() {
        let c = Canvas()
        let inner = GroupModel(transform: Transform2D(offset: CGPoint(x: 0, y: 0), extent: CGSize(width: 50, height: 50),
                                                      childOffset: .zero, childExtent: CGSize(width: 100, height: 100)),
                               children: [.shape(ShapeModel(transform: rect(0, 0, 100, 100), fill: .group))])
        let outer = GroupModel(transform: Transform2D(offset: CGPoint(x: 100, y: 0), extent: CGSize(width: 100, height: 100),
                                                      childOffset: .zero, childExtent: CGSize(width: 100, height: 100)),
                               fill: .solid(blue), children: [.group(inner)])
        r.drawGroup(outer, in: c.ctx)
        #expect(c.matches(110, 10, 0, 0, 255) && c.matches(148, 48, 0, 0, 255))
        #expect(c.isClear(152, 52) && c.isClear(98, 10))
    }

    @Test func linearGradientAngle0And90() {
        let stops = [GradientStop(position: 0, color: red), GradientStop(position: 1, color: blue)]
        let h = Canvas(), v = Canvas()
        r.drawShape(ShapeModel(transform: rect(0, 0, 200, 100), fill: .gradient(Gradient(stops: stops, angle: 0))), in: h.ctx)
        r.drawShape(ShapeModel(transform: rect(0, 0, 200, 100), fill: .gradient(Gradient(stops: stops, angle: 90))), in: v.ctx)
        #expect(h.matches(1, 50, 255, 0, 0, tol: 8) && h.matches(198, 50, 0, 0, 255, tol: 8))
        #expect(h.matches(100, 5, 128, 0, 128, tol: 12) && h.matches(100, 95, 128, 0, 128, tol: 12))
        #expect(v.matches(100, 0, 255, 0, 0, tol: 8) && v.matches(100, 99, 0, 0, 255, tol: 8))
        #expect(v.matches(5, 50, 128, 0, 128, tol: 12) && v.matches(195, 50, 128, 0, 128, tol: 12))
    }

    @Test func pathGradientCircleIsLightAtCentre() {
        let stops = [GradientStop(position: 0, color: RGBA(r: 1, g: 1, b: 1)), GradientStop(position: 1, color: RGBA(r: 0, g: 0, b: 0))]
        let c = Canvas()
        r.drawShape(ShapeModel(transform: rect(0, 0, 200, 100),
                               fill: .gradient(Gradient(stops: stops, path: .circle,
                                                        fillToRect: SrcRect(l: 0.5, t: 0.5, r: 0.5, b: 0.5)))), in: c.ctx)
        #expect(c.matches(100, 50, 255, 255, 255, tol: 10))
        #expect(c.pixel(1, 1).r < 40 && c.pixel(1, 1).a == 255)
    }

    @Test func patternIsApproximatedByBlend() {
        let c = Canvas()
        r.drawShape(ShapeModel(transform: rect(0, 0, 200, 100),
                               fill: .pattern(fg: RGBA(r: 0, g: 0, b: 0), bg: RGBA(r: 1, g: 1, b: 1), preset: "pct25")),
                    in: c.ctx)
        // 25 % foreground: 0.75 white.
        #expect(c.matches(100, 50, 191, 191, 191, tol: 4))
    }

    @Test func shapeBlipFillWithSrcRectCrops() throws {
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255)))
        }
        let rr = renderer(pkg)
        let full = Canvas(), cropped = Canvas()
        let whole = ImageRef(part: "ppt/media/image1.png")
        let right = ImageRef(part: "ppt/media/image1.png", srcRect: SrcRect(l: 0.5, t: 0, r: 0, b: 0))
        rr.drawShape(ShapeModel(transform: rect(0, 0, 200, 100), fill: .picture(whole, stretch: nil, tile: false)), in: full.ctx)
        rr.drawShape(ShapeModel(transform: rect(0, 0, 200, 100), fill: .picture(right, stretch: nil, tile: false)), in: cropped.ctx)
        #expect(full.matches(10, 50, 255, 0, 0) && full.matches(190, 50, 0, 0, 255))
        #expect(cropped.matches(10, 50, 0, 0, 255) && cropped.matches(190, 50, 0, 0, 255))
    }

    @Test func imageIsUprightAndTopCropWorks() throws {
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255), vertical: true))
        }
        let rr = renderer(pkg)
        let c = Canvas(), cropped = Canvas()
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ImageRef(part: "ppt/media/image1.png")), in: c.ctx)
        // Top half red, bottom half blue, as in the image file.
        #expect(c.matches(100, 10, 255, 0, 0) && c.matches(100, 90, 0, 0, 255))
        let ref = ImageRef(part: "ppt/media/image1.png", srcRect: SrcRect(l: 0, t: 0.5, r: 0, b: 0))
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ref), in: cropped.ctx)
        #expect(cropped.matches(100, 10, 0, 0, 255) && cropped.matches(100, 90, 0, 0, 255))
        // fillRect insets: image only in the right half.
        let inset = Canvas()
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ImageRef(part: "ppt/media/image1.png"),
                                    stretch: SrcRect(l: 0.5, t: 0, r: 0, b: 0)), in: inset.ctx)
        #expect(inset.isClear(50, 50) && inset.matches(150, 10, 255, 0, 0))
    }

    @Test func pictureWithNegativeSrcRectPadsAndIsClippedToGeometry() throws {
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (255, 0, 0)))
        }
        let rr = renderer(pkg)
        let c = Canvas()
        // l = -100 %: image occupies only the right half of the frame.
        let ref = ImageRef(part: "ppt/media/image1.png", srcRect: SrcRect(l: -1, t: 0, r: 0, b: 0))
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ref), in: c.ctx)
        #expect(c.isClear(50, 50) && c.matches(150, 50, 255, 0, 0))
        // Ellipse clip: corners stay clear.
        let e = Canvas()
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), geometry: .preset("ellipse", adjust: [:]),
                                    image: ImageRef(part: "ppt/media/image1.png")), in: e.ctx)
        #expect(e.isClear(2, 2) && e.matches(100, 50, 255, 0, 0))
    }

    @Test func pictureAlphaModFix() throws {
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (255, 0, 0)))
        }
        let c = Canvas()
        renderer(pkg).drawPicture(PictureModel(transform: rect(0, 0, 200, 100),
                                               image: ImageRef(part: "ppt/media/image1.png", alphaModFix: 0.5)), in: c.ctx)
        #expect(c.matches(100, 50, 128, 0, 0, a: 128, tol: 3))
    }

    @Test func fillRefIdx2RendersThemeColour() throws {
        let t = try Theme(xml: xml("""
        <a:theme \(drawingNS)><a:themeElements><a:fmtScheme name="t"><a:fillStyleLst>\
        <a:solidFill><a:srgbClr val="00FF00"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """))
        let sp = try xml("<p:spPr \(drawingNS)>\(xfrmXML(0, 0, 200, 100))<a:prstGeom prst=\"rect\"/></p:spPr>")
        let st = try xml("<p:style \(drawingNS)><a:fillRef idx=\"2\"><a:schemeClr val=\"accent1\"/></a:fillRef></p:style>")
        let c = Canvas()
        r.drawShape(ShapeModel(spPr: sp, style: st, colors: ColorContext(theme: t)), in: c.ctx)
        #expect(c.matches(100, 50, 0x44, 0x72, 0xC4, tol: 2))
    }

    @Test func triangleArrowheadAtLineEnd() {
        let c = Canvas()
        let line = Line(width: 2, fill: .solid(red), tailEnd: ArrowEnd(kind: .triangle, width: .lg, length: .lg))
        r.drawShape(ShapeModel(transform: rect(20, 50, 160, 0), geometry: .preset("line", adjust: [:]), line: line),
                    in: c.ctx)
        // Line is 2 pt thick; the head (5×2 = 10 pt wide, 10 pt long) ends at x = 180.
        #expect(c.matches(100, 50, 255, 0, 0, tol: 40))
        #expect(c.isClear(100, 53))
        #expect(c.matches(172, 52, 255, 0, 0, tol: 40))
        #expect(c.isClear(25, 53))
        #expect(c.isClear(183, 50))
    }

    @Test func thinLineGetsVisibleArrowhead() {
        let c = Canvas()
        // 0.75 pt connector, med/med triangle: the head is sized from max(width, 2 pt) → 6 × 6 pt.
        let line = Line(width: 0.75, fill: .solid(red), tailEnd: ArrowEnd(kind: .triangle))
        r.drawShape(ShapeModel(transform: rect(20, 50, 160, 0), geometry: .preset("line", adjust: [:]), line: line),
                    in: c.ctx)
        var minY = 100, maxY = -1, minX = 200
        for y in 40..<60 { for x in 160..<190 where c.pixel(x, y).a > 128 {
            minY = min(minY, y); maxY = max(maxY, y); minX = min(minX, x)
        } }
        #expect(maxY - minY + 1 >= 5)      // head width ≥ 5 px (a factor × 0.75 pt head would be ~2 px)
        #expect(180 - minX >= 5)           // head length ≥ 5 px
    }

    @Test func textInFlippedGroupIsNotMirrored() {
        let base = Canvas().ctx.ctm
        let baseSign = base.a * base.d - base.b * base.c
        func textDeterminants(groupFlipH: Bool, groupFlipV: Bool, shapeFlipV: Bool = false) -> [CGFloat] {
            let c = Canvas()
            let child = ShapeModel(transform: rect(10, 10, 50, 20, flipV: shapeFlipV), fill: .solid(red))
            let inner = GroupModel(transform: Transform2D(offset: .zero, extent: CGSize(width: 100, height: 50),
                                                          flipH: groupFlipH, flipV: groupFlipV,
                                                          childOffset: .zero, childExtent: CGSize(width: 100, height: 50)),
                                   children: [.shape(child)])
            let outer = GroupModel(transform: Transform2D(offset: CGPoint(x: 10, y: 10), extent: CGSize(width: 100, height: 50),
                                                          flipH: true,
                                                          childOffset: .zero, childExtent: CGSize(width: 100, height: 50)),
                                   children: [.group(inner)])
            var dets: [CGFloat] = []
            for g in [inner, outer] {
                r.drawGroup(g, in: c.ctx) { _, ctx, _ in
                    let m = ctx.ctm
                    dets.append((m.a * m.d - m.b * m.c) * baseSign)
                }
            }
            return dets
        }
        for (h, v) in [(true, false), (false, true), (true, true), (false, false)] {
            let dets = textDeterminants(groupFlipH: h, groupFlipV: v)
            #expect(dets.count == 2 && dets.allSatisfy { $0 > 0 }, "flipH \(h) flipV \(v): \(dets)")
        }
        #expect(textDeterminants(groupFlipH: false, groupFlipV: true, shapeFlipV: true).allSatisfy { $0 > 0 })
    }

    @Test func textInFlipVGroupIsTurnedNotMirrored() {
        // Group flipV: the text is turned by 180° (like a shape's own flipV), i.e. x runs right-to-left.
        let c = Canvas()
        var xAxis: CGFloat = 0
        let g = GroupModel(transform: Transform2D(offset: .zero, extent: CGSize(width: 100, height: 50), flipV: true,
                                                  childOffset: .zero, childExtent: CGSize(width: 100, height: 50)),
                           children: [.shape(ShapeModel(transform: rect(10, 10, 50, 20)))])
        r.drawGroup(g, in: c.ctx) { _, ctx, _ in xAxis = ctx.ctm.a }
        #expect(xAxis < 0)
    }

    @Test func headEndArrowAndLineShortening() {
        let c = Canvas()
        // Open "arrow" head at the start; with butt cap and no head the line would reach x = 20 exactly.
        let line = Line(width: 4, fill: .solid(red), headEnd: ArrowEnd(kind: .arrow, width: .med, length: .med))
        r.drawShape(ShapeModel(transform: rect(20, 50, 160, 0), geometry: .preset("line", adjust: [:]), line: line),
                    in: c.ctx)
        #expect(!c.isClear(28, 44))   // upper barb of the open arrow
        #expect(c.isClear(14, 50))
    }

    @Test func dashedLeavesGaps() {
        let c = Canvas()
        let line = Line(width: 4, fill: .solid(red), dash: [4, 3])
        r.drawShape(ShapeModel(transform: rect(0, 50, 200, 0), geometry: .preset("line", adjust: [:]), line: line), in: c.ctx)
        // Pattern 16 on, 12 off.
        #expect(c.matches(8, 50, 255, 0, 0) && c.isClear(22, 50) && c.matches(36, 50, 255, 0, 0))
    }

    @Test func textCallbackGetsTextRectAfterFill() throws {
        let c = Canvas()
        var got: CGRect?
        var filledBefore = false
        r.drawShape(ShapeModel(transform: rect(50, 25, 100, 50), fill: .solid(red)), in: c.ctx) { ctx, tr in
            got = tr
            filledBefore = c.matches(100, 50, 255, 0, 0)
            // Text callback draws in shape coordinates: (0,0) is the shape's top-left.
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        #expect(got == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(filledBefore)
        #expect(c.matches(51, 26, 0, 0, 255))
    }

    @Test func zeroSizeShapeStillGetsTextCallbackButNoFill() {
        let c = Canvas()
        var called = false
        r.drawShape(ShapeModel(transform: rect(10, 10, 0, 0), fill: .solid(red)), in: c.ctx) { _, _ in called = true }
        #expect(called && c.allClear)
        var notCalled = true
        r.drawShape(ShapeModel(transform: rect(.nan, 0, 10, 10), fill: .solid(red)), in: c.ctx) { _, _ in notCalled = false }
        #expect(notCalled)
    }

    @Test func missingImageDrawsNothing() throws {
        let pkg = try makePackage { $0.addData("ppt/media/bad.png", Data([1, 2, 3])) }
        let rr = renderer(pkg)
        let c = Canvas()
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ImageRef(part: "ppt/media/missing.png")), in: c.ctx)
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ImageRef(part: "ppt/media/bad.png")), in: c.ctx)
        rr.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: nil), in: c.ctx)
        rr.drawShape(ShapeModel(transform: rect(0, 0, 200, 100),
                                fill: .picture(ImageRef(part: "nope.png"), stretch: nil, tile: false)), in: c.ctx)
        #expect(c.allClear)
    }

    @Test func degenerateInputDoesNotCrash() {
        let c = Canvas()
        r.drawShape(ShapeModel(transform: rect(.nan, .infinity, -5, 1e30), fill: .solid(red)), in: c.ctx)
        r.drawShape(ShapeModel(transform: rect(0, 0, 0, 0), fill: .solid(red),
                               line: Line(width: 1, fill: .solid(red), headEnd: ArrowEnd(kind: .stealth))), in: c.ctx)
        r.drawShape(ShapeModel(transform: rect(10, 10, 50, 50),
                               fill: .gradient(Gradient(stops: [], angle: 45))), in: c.ctx)
        r.drawPicture(PictureModel(transform: rect(0, 0, 200, 100), image: ImageRef(part: "x",
                                   srcRect: SrcRect(l: 0.6, t: 0, r: 0.6, b: 0))), in: c.ctx)
        #expect(c.isClear(100, 50))
    }

    @Test func svgBlipIgnoredPNGFallbackUsed() throws {
        let pkg = try makePackage {
            $0.add("ppt/slides/slide1.xml", "<x/>")
            $0.add("ppt/slides/_rels/slide1.xml.rels", slideRels([("rId2", "../media/image1.png"), ("rId3", "../media/image2.svg")]))
            $0.addData("ppt/media/image1.png", testImage(left: (0, 0, 255), right: (0, 0, 255)))
            $0.add("ppt/media/image2.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\" fill=\"#ff0000\"/></svg>")
        }
        let part = PartContext(package: pkg, part: "ppt/slides/slide1.xml")
        let blipFill = try xml("""
        <p:blipFill \(drawingNS)><a:blip r:embed="rId2"><a:extLst><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}">\
        <asvg:svgBlip xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main" r:embed="rId3"/></a:ext></a:extLst>\
        </a:blip><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        """)
        let sp = try xml("<p:spPr \(drawingNS)>\(xfrmXML(0, 0, 200, 100))<a:prstGeom prst=\"rect\"/></p:spPr>")
        let pic = PictureModel(blipFill: blipFill, spPr: sp, style: nil, colors: plainColors, part: part)
        #expect(pic.image?.part == "ppt/media/image1.png")
        let c = Canvas()
        renderer(pkg).drawPicture(pic, in: c.ctx)
        #expect(c.matches(100, 50, 0, 0, 255))
    }

    @Test func pictureLineIsDrawnOnTop() throws {
        let pkg = try makePackage { $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (255, 0, 0))) }
        let c = Canvas()
        renderer(pkg).drawPicture(PictureModel(transform: rect(20, 20, 160, 60), image: ImageRef(part: "ppt/media/image1.png"),
                                               line: Line(width: 4, fill: .solid(blue))), in: c.ctx)
        #expect(c.matches(20, 50, 0, 0, 255) && c.matches(100, 50, 255, 0, 0))
    }

    @Test func outerShadowOffsetPointsDownInYDownSpace() {
        let c = Canvas()
        let shadow = Shadow(color: RGBA(r: 0, g: 0, b: 0, a: 1), blur: 0, distance: 10, direction: 90)
        r.drawShape(ShapeModel(transform: rect(50, 20, 40, 40), fill: .solid(red), shadow: shadow), in: c.ctx)
        #expect(c.matches(70, 40, 255, 0, 0))
        #expect(c.matches(70, 65, 0, 0, 0))          // below the shape: shadow
        #expect(c.isClear(70, 15))                    // above: nothing
        let right = Canvas()
        let s0 = Shadow(color: RGBA(r: 0, g: 0, b: 0, a: 1), blur: 0, distance: 10, direction: 0)
        r.drawShape(ShapeModel(transform: rect(50, 20, 40, 40), fill: .solid(red), shadow: s0), in: right.ctx)
        #expect(right.matches(95, 40, 0, 0, 0) && right.isClear(45, 40))
    }

    @Test func shadowFollowsZoomedCTM() {
        let c = Canvas()
        c.ctx.scaleBy(x: 2, y: 2)
        let shadow = Shadow(color: RGBA(r: 0, g: 0, b: 0, a: 1), blur: 0, distance: 5, direction: 90)
        r.drawShape(ShapeModel(transform: rect(10, 10, 20, 20), fill: .solid(red), shadow: shadow), in: c.ctx)
        // Shape covers device y 20…60; shadow 10 device px lower → y 30…70.
        #expect(c.matches(40, 65, 0, 0, 0) && c.isClear(40, 72))
    }

    @Test func drawElementDispatches() throws {
        let c = Canvas()
        r.draw(.shape(ShapeModel(transform: rect(0, 0, 10, 10), fill: .solid(red))), in: c.ctx)
        #expect(c.matches(5, 5, 255, 0, 0))
    }
}

@Suite struct DrawingRendererImageSizeTests {
    private func picturePackage() throws -> (OPCPackage, PictureModel) {
        let pkg = try makePackage { $0.addData("ppt/media/big.png", testImage(width: 1000, height: 500, left: (255, 0, 0), right: (0, 0, 255))) }
        let pic = PictureModel(transform: Transform2D(offset: CGPoint(x: 10, y: 10), extent: CGSize(width: 100, height: 50)),
                               image: ImageRef(part: "ppt/media/big.png"))
        return (pkg, pic)
    }

    @Test func bitmapContextsDecodeAtTheDrawnSize() throws {
        // 100×50 pt on a 1 px/pt canvas: the 1000 px image is decoded at the 128 px bucket.
        let (pkg, pic) = try picturePackage()
        let r = renderer(pkg)
        let c = Canvas()
        r.drawPicture(pic, in: c.ctx)
        #expect(c.matches(30, 30, 255, 0, 0) && c.matches(90, 30, 0, 0, 255))
        #expect(r.images.cachedLongSides(part: "ppt/media/big.png") == [128])
        // A crop to the left tenth shows a tenth of the image across the box: 10× more pixels are needed.
        var cropped = pic
        cropped.image = ImageRef(part: "ppt/media/big.png", srcRect: SrcRect(l: 0, t: 0, r: 0.9, b: 0))
        r.drawPicture(cropped, in: Canvas().ctx)
        #expect(r.images.cachedLongSides(part: "ppt/media/big.png") == [128, 1000])
    }

    @Test func stretchedPicturesDecodeForTheShortAxis() throws {
        // A 1000×50 strip in a 20×20 pt box at 1 px/pt: 20 px of height are needed, so the long side must be
        // ≥ 400 px (bucket 512), not the 64 px the box's long side alone would give.
        let pkg = try makePackage { $0.addData("ppt/media/strip.png", testImage(width: 1000, height: 50, left: (255, 0, 0), right: (0, 0, 255))) }
        let r = renderer(pkg)
        let box = Transform2D(offset: CGPoint(x: 10, y: 10), extent: CGSize(width: 20, height: 20))
        r.drawPicture(PictureModel(transform: box, image: ImageRef(part: "ppt/media/strip.png")), in: Canvas().ctx)
        #expect(r.images.cachedLongSides(part: "ppt/media/strip.png") == [512])
        // Blip fill: the same per-axis need.
        let filled = renderer(pkg)
        let fill = Fill.picture(ImageRef(part: "ppt/media/strip.png"), stretch: nil, tile: false)
        filled.drawShape(ShapeModel(transform: box, fill: fill), in: Canvas().ctx)
        #expect(filled.images.cachedLongSides(part: "ppt/media/strip.png") == [512])
        // Cropped to the top half: twice the source pixels per drawn pixel vertically → 800 px → bucket 1024 ≥
        // native, so the full image.
        let cropped = renderer(pkg)
        let half = ImageRef(part: "ppt/media/strip.png", srcRect: SrcRect(l: 0, t: 0, r: 0, b: 0.5))
        cropped.drawPicture(PictureModel(transform: box, image: half), in: Canvas().ctx)
        #expect(cropped.images.cachedLongSides(part: "ppt/media/strip.png") == [1000])
    }

    @Test func pdfContextsKeepTheFullImage() throws {
        let (pkg, pic) = try picturePackage()
        let r = renderer(pkg)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { Issue.record("no PDF context"); return }
        pdf.beginPDFPage(nil)
        pdf.translateBy(x: 0, y: 100)
        pdf.scaleBy(x: 1, y: -1)
        r.drawPicture(pic, in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        #expect(r.images.cachedLongSides(part: "ppt/media/big.png") == [1000])
    }
}
