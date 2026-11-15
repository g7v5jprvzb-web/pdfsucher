import Testing
import Foundation
import CoreGraphics
@testable import OOXMLKit

private let aNS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""

private enum Seg: Equatable {
    case move(CGPoint), line(CGPoint), quad(CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint), close
}

private func segments(_ p: CGPath) -> [Seg] {
    var out: [Seg] = []
    p.applyWithBlock { el in
        let e = el.pointee
        switch e.type {
        case .moveToPoint: out.append(.move(e.points[0]))
        case .addLineToPoint: out.append(.line(e.points[0]))
        case .addQuadCurveToPoint: out.append(.quad(e.points[0], e.points[1]))
        case .addCurveToPoint: out.append(.cubic(e.points[0], e.points[1], e.points[2]))
        case .closeSubpath: out.append(.close)
        @unknown default: break
        }
    }
    return out
}

private func allPoints(_ p: CGPath) -> [CGPoint] {
    segments(p).flatMap { s -> [CGPoint] in
        switch s {
        case .move(let a), .line(let a): return [a]
        case .quad(let a, let b): return [a, b]
        case .cubic(let a, let b, let c): return [a, b, c]
        case .close: return []
        }
    }
}

private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }
private func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.01) -> Bool {
    near(a.minX, b.minX, tol) && near(a.minY, b.minY, tol) && near(a.maxX, b.maxX, tol) && near(a.maxY, b.maxY, tol)
}

private func bounds(_ g: GeometryPaths) -> CGRect {
    g.paths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
}

private func custom(_ inner: String) throws -> Geometry {
    .custom(try OOXMLNode.parse(Data("<a:custGeom \(aNS)>\(inner)</a:custGeom>".utf8)))
}

/// The 33 presets that occur in Chris' decks.
private let corpusPresets = """
rect line ellipse roundRect straightConnector1 frame arc rightArrow chevron rtTriangle leftRightArrow triangle \
curvedConnector3 rightBrace bracketPair wedgeRoundRectCallout uturnArrow round1Rect plus mathPlus chord \
bentConnector3 trapezoid parallelogram donut can bracePair upArrow round2DiagRect mathMultiply heart downArrow blockArc
""".split(separator: " ").map(String.init)

@Suite struct GuideFormulaTests {
    private func eval(_ fmla: String, w: Double = 100, h: Double = 60) -> Double {
        var g = GuideContext(width: w, height: h)
        g.define("x", fmla)
        return g.value("x")
    }

    @Test func operators() {
        #expect(eval("*/ w 1 2") == 50)
        #expect(eval("+- 10 5 3") == 12)
        #expect(eval("+/ 10 6 4") == 4)
        #expect(eval("?: 1 7 9") == 7)
        #expect(eval("?: 0 7 9") == 9)
        #expect(eval("?: -1 7 9") == 9)
        #expect(eval("abs -3") == 3)
        #expect(near(eval("at2 1 1"), 2_700_000, 1e-6))
        #expect(near(eval("at2 -1 0"), 10_800_000, 1e-6))
        #expect(near(eval("cat2 10 3 4"), 6, 1e-9))
        #expect(near(eval("sat2 10 3 4"), 8, 1e-9))
        #expect(near(eval("cos 100 cd2"), -100, 1e-9))
        #expect(near(eval("sin 100 cd4"), 100, 1e-9))
        #expect(near(eval("tan 100 2700000"), 100, 1e-9))
        #expect(eval("max 3 -4") == 3)
        #expect(eval("min 3 -4") == -4)
        #expect(eval("mod 3 4 0") == 5)
        #expect(eval("pin 0 150 100") == 100)
        #expect(eval("pin 0 -5 100") == 0)
        #expect(eval("pin 0 50 100") == 50)
        #expect(eval("sqrt 16") == 4)
        #expect(eval("val 12345") == 12345)
    }

    @Test func builtins() {
        let g = GuideContext(width: 120, height: 60)
        let want: [String: Double] = [
            "w": 120, "h": 60, "l": 0, "t": 0, "r": 120, "b": 60, "hc": 60, "vc": 30,
            "wd2": 60, "wd3": 40, "wd4": 30, "wd5": 24, "wd6": 20, "wd8": 15, "wd10": 12, "wd12": 10, "wd32": 3.75,
            "hd2": 30, "hd3": 20, "hd4": 15, "hd5": 12, "hd6": 10, "hd8": 7.5, "hd10": 6, "hd12": 5,
            "ss": 60, "ls": 120, "ssd2": 30, "ssd4": 15, "ssd6": 10, "ssd8": 7.5, "ssd16": 3.75, "ssd32": 1.875,
            "cd2": 10_800_000, "cd4": 5_400_000, "cd8": 2_700_000, "3cd4": 16_200_000, "3cd8": 8_100_000,
            "5cd8": 13_500_000, "7cd8": 18_900_000,
        ]
        for (k, v) in want { #expect(g.value(k) == v, "\(k)") }
    }

    @Test func robustness() {
        #expect(eval("*/ 5 5 0") == 0)          // division by zero → 0
        #expect(eval("+/ 5 5 0") == 0)
        #expect(eval("sqrt -4") == 0)           // NaN → 0
        #expect(eval("tan 1 cd4").isFinite)
        #expect(eval("*/ nosuchguide 2 1") == 0) // unknown name → 0
        #expect(eval("bogus 1 2 3") == 0)       // unknown operator → 0
        #expect(eval("") == 0)
        #expect(eval("*/ 1") == 0)              // missing arguments → 0
        #expect(eval("val 1e400") == 0)         // inf → 0
    }

    @Test func guidesEvaluatedInOrder() {
        var g = GuideContext(width: 100, height: 60)
        g.define("a", "*/ w 1 4")
        g.define("b", "+- a a 0")
        g.define("a", "val 1")
        #expect(g.value("b") == 50)
        #expect(g.value("a") == 1)
    }
}

@Suite struct PresetGeometryTests {
    let size = CGSize(width: 100, height: 60)

    @Test func rect() {
        let g = GeometryBuilder.paths(.preset("rect", adjust: [:]), size: size)
        #expect(g.paths.count == 1)
        #expect(g.paths[0].fill == .norm && g.paths[0].stroke)
        #expect(segments(g.paths[0].path) == [
            .move(.zero), .line(CGPoint(x: 100, y: 0)), .line(CGPoint(x: 100, y: 60)),
            .line(CGPoint(x: 0, y: 60)), .close,
        ])
        #expect(g.textRect == CGRect(x: 0, y: 0, width: 100, height: 60))
    }

    @Test func roundRectDefaultRadius() {
        let g = GeometryBuilder.paths(.preset("roundRect", adjust: [:]), size: size)
        #expect(g.paths.count == 1)
        let r = 0.16667 * 60.0
        let segs = segments(g.paths[0].path)
        guard case .move(let start)? = segs.first else { Issue.record("no moveTo"); return }
        #expect(near(start.x, 0) && near(start.y, r))
        #expect(segs.contains(.line(CGPoint(x: 100 - r, y: 0))) || allPoints(g.paths[0].path).contains {
            near($0.x, 100 - r) && near($0.y, 0) })
        #expect(near(bounds(g), CGRect(x: 0, y: 0, width: 100, height: 60)))
        // Adjust override: adj 50000 → radius = half of the short side.
        let half = GeometryBuilder.paths(.preset("roundRect", adjust: ["adj": 50000]), size: size)
        guard case .move(let s2)? = segments(half.paths[0].path).first else { Issue.record("no moveTo"); return }
        #expect(near(s2.y, 30))
    }

    @Test func roundRectTextRect() throws {
        let g = GeometryBuilder.paths(.preset("roundRect", adjust: [:]), size: size)
        // il = ss·adj/100000 · 29289/100000 (ECMA: dx1·sin45 inset)
        let inset = 60.0 * 0.16667 * 0.29289
        let tr = try #require(g.textRect)
        #expect(near(tr.minX, inset) && near(tr.minY, inset) && near(tr.maxX, 100 - inset) && near(tr.maxY, 60 - inset))
    }

    @Test func ellipseBounds() {
        let g = GeometryBuilder.paths(.preset("ellipse", adjust: [:]), size: size)
        #expect(near(bounds(g), CGRect(origin: .zero, size: size)))
        // Control points of a correct Bézier ellipse stay inside the box as well.
        #expect(near(g.paths[0].path.boundingBox, CGRect(origin: .zero, size: size)))
    }

    @Test func rightArrow() {
        let g = GeometryBuilder.paths(.preset("rightArrow", adjust: [:]), size: size)
        let pts = allPoints(g.paths[0].path)
        let maxX = pts.map(\.x).max() ?? 0
        #expect(near(maxX, 100))
        let tip = pts.filter { near($0.x, 100) }
        #expect(tip.count == 1 && near(tip[0].y, 30))      // apex at (w, vc)
        // Shaft: points at x = 0 lie at h/4 and 3h/4 → shaft height 50 %.
        let left = pts.filter { near($0.x, 0) }.map(\.y).sorted()
        #expect(left.count == 2 && near(left[0], 15) && near(left[1], 45))
    }

    @Test func triangleApex() {
        let g = GeometryBuilder.paths(.preset("triangle", adjust: [:]), size: size)
        let pts = allPoints(g.paths[0].path)
        #expect(pts.contains { near($0.x, 50) && near($0.y, 0) })
        #expect(near(bounds(g), CGRect(origin: .zero, size: size)))
    }

    @Test func donutHasHole() {
        let g = GeometryBuilder.paths(.preset("donut", adjust: [:]), size: size)
        let moves = g.paths.flatMap { segments($0.path) }.filter { if case .move = $0 { return true }; return false }
        #expect(moves.count >= 2)
        let p = g.paths[0].path
        #expect(p.contains(CGPoint(x: 2, y: 30), using: .evenOdd))
        #expect(!p.contains(CGPoint(x: 50, y: 30), using: .evenOdd))
    }

    @Test func pathAttributes() {
        // can: body fill + lighter top (lighten, no stroke) + outline (fill none)
        let g = GeometryBuilder.paths(.preset("can", adjust: [:]), size: size)
        #expect(g.paths.map(\.fill) == [.norm, .lighten, .none])
        #expect(g.paths.map(\.stroke) == [false, false, true])
    }

    @Test func unknownPresetIsRect() {
        for name in ["noSuchShape", "", "presetShapeDefinitons"] {
            let g = GeometryBuilder.paths(.preset(name, adjust: [:]), size: size)
            #expect(g.paths.count == 1)
            #expect(near(bounds(g), CGRect(origin: .zero, size: size)))
            #expect(g.textRect == CGRect(origin: .zero, size: size))
        }
    }

    /// Presets whose own data draws exactly the fallback rectangle (so they cannot be told apart from it).
    static let rectangleLookalikes: Set<String> = ["rect", "actionButtonBlank", "flowChartProcess"]

    /// Parses the preset and builds it without the rectangle fallback of `GeometryBuilder.paths`, so broken
    /// data shows up as a failure instead of a silently drawn rectangle.
    private func expectBuildsWithoutFallback(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let def = PresetGeometry.definition(name) else {
            Issue.record("\(name): definition does not parse", sourceLocation: sourceLocation); return
        }
        let built = GeometryBuilder.build(def, adjust: [:], width: 100, height: 60)
        #expect(!built.paths.isEmpty, "\(name): no paths", sourceLocation: sourceLocation)
        if !Self.rectangleLookalikes.contains(name) {
            let fallback = GeometryBuilder.rectangle(100, 60).paths.map { segments($0.path) }
            #expect(built.paths.map { segments($0.path) } != fallback, "\(name): equals fallback rectangle",
                    sourceLocation: sourceLocation)
        }
    }

    @Test func embeddedPresetsAllBuild() {
        let names = PresetGeometry.names
        #expect(names.count == 187)
        for name in names {
            expectBuildsWithoutFallback(name)
            let g = GeometryBuilder.paths(.preset(name, adjust: [:]), size: size)
            #expect(!g.paths.isEmpty, "\(name)")
            let b = bounds(g)
            #expect(!b.isNull && (b.width > 0 || b.height > 0), "\(name) \(b)")
            for p in g.paths {
                #expect(allPoints(p.path).allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(name)")
            }
            if let t = g.textRect {
                #expect(t.minX.isFinite && t.minY.isFinite && t.width.isFinite && t.height.isFinite, "\(name)")
            }
        }
    }

    @Test func corpusPresetsExist() {
        #expect(corpusPresets.count == 33)
        let names = Set(PresetGeometry.names)
        for name in corpusPresets {
            #expect(names.contains(name), "\(name)")
            expectBuildsWithoutFallback(name)
            #expect(!GeometryBuilder.paths(.preset(name, adjust: [:]), size: size).paths.isEmpty, "\(name)")
        }
    }

    @Test func degenerateSizes() {
        for s in [CGSize.zero, CGSize(width: 100, height: 0), CGSize(width: -5, height: CGFloat.nan),
                  CGSize(width: CGFloat.infinity, height: 3)] {
            for name in PresetGeometry.names {
                let g = GeometryBuilder.paths(.preset(name, adjust: ["adj": 1e300, "adj1": -1e300]), size: s)
                for p in g.paths {
                    #expect(allPoints(p.path).allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(name) \(s)")
                }
            }
        }
    }
}

@Suite struct CustomGeometryTests {
    let size = CGSize(width: 200, height: 100)

    @Test func customScaledByPathSize() throws {
        let g = GeometryBuilder.paths(try custom("""
            <a:pathLst><a:path w="20" h="10" fill="none" stroke="0">
            <a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:lnTo><a:pt x="20" y="10"/></a:lnTo>
            <a:quadBezTo><a:pt x="10" y="0"/><a:pt x="0" y="10"/></a:quadBezTo>
            <a:cubicBezTo><a:pt x="0" y="0"/><a:pt x="5" y="5"/><a:pt x="10" y="5"/></a:cubicBezTo>
            <a:close/></a:path></a:pathLst>
            """), size: size)
        #expect(g.paths.count == 1)
        #expect(g.paths[0].fill == PathFillMode.none && !g.paths[0].stroke)
        #expect(segments(g.paths[0].path) == [
            .move(.zero), .line(CGPoint(x: 200, y: 100)),
            .quad(CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)),
            .cubic(.zero, CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 50)), .close,
        ])
        #expect(g.textRect == nil)
    }

    @Test func customWithoutPathSizeUsesEMU() throws {
        // No w/h on the path: coordinates are in shape space, i.e. EMU (12700 per point).
        let g = GeometryBuilder.paths(try custom("""
            <a:gdLst><a:gd name="mid" fmla="*/ w 1 2"/></a:gdLst>
            <a:rect l="l" t="t" r="mid" b="b"/>
            <a:pathLst><a:path><a:moveTo><a:pt x="0" y="0"/></a:moveTo>
            <a:lnTo><a:pt x="mid" y="1270000"/></a:lnTo></a:path></a:pathLst>
            """), size: size)
        #expect(segments(g.paths[0].path) == [.move(.zero), .line(CGPoint(x: 100, y: 100))])
        #expect(g.textRect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func arcToQuarterCircle() throws {
        // Start at the top of a circle centred at (100,100) r=100, sweep 90° clockwise (y down) → (200,100).
        let g = GeometryBuilder.paths(try custom("""
            <a:pathLst><a:path w="200" h="100"><a:moveTo><a:pt x="100" y="0"/></a:moveTo>
            <a:arcTo wR="100" hR="100" stAng="16200000" swAng="5400000"/>
            <a:lnTo><a:pt x="100" y="100"/></a:lnTo><a:close/></a:path></a:pathLst>
            """), size: CGSize(width: 200, height: 100))
        let segs = segments(g.paths[0].path)
        guard segs.count >= 3, case .cubic(_, _, let end) = segs[1] else { Issue.record("\(segs)"); return }
        #expect(near(end.x, 200) && near(end.y, 100))
        // The arc bulges up-right: its midpoint lies on the circle at 315°.
        let b = g.paths[0].path.boundingBoxOfPath
        #expect(near(b, CGRect(x: 100, y: 0, width: 100, height: 100)))
        let mid = CGPoint(x: 100 + 100 * cos(CGFloat.pi / 4) - 1, y: 100 - 100 * sin(CGFloat.pi / 4) + 1)
        #expect(g.paths[0].path.contains(mid))
    }

    @Test func arcToCounterClockwiseAndEllipse() throws {
        // Full ellipse, wR 100 hR 50, starting at the right point, sweeping −360°.
        let g = GeometryBuilder.paths(try custom("""
            <a:pathLst><a:path w="200" h="100"><a:moveTo><a:pt x="200" y="50"/></a:moveTo>
            <a:arcTo wR="100" hR="50" stAng="0" swAng="-21600000"/><a:close/></a:path></a:pathLst>
            """), size: size)
        #expect(near(g.paths[0].path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 200, height: 100)))
        // −90° from the right point goes up (y down space): first segment ends at the top (100, 0).
        let segs = segments(g.paths[0].path)
        guard segs.count >= 2, case .cubic(_, _, let end) = segs[1] else { Issue.record("\(segs)"); return }
        #expect(near(end.x, 100) && near(end.y, 0))
    }

    @Test func arcToEllipseUsesVisualAngle() throws {
        // On a 200×100 ellipse, stAng 45° is the visual angle: the point at 45° from the centre
        // lies where |dx| == |dy|. Starting at the bottom (90°) and sweeping −45° must end there.
        let g = GeometryBuilder.paths(try custom("""
            <a:pathLst><a:path w="200" h="100"><a:moveTo><a:pt x="100" y="100"/></a:moveTo>
            <a:arcTo wR="100" hR="50" stAng="5400000" swAng="-2700000"/></a:path></a:pathLst>
            """), size: size)
        let segs = segments(g.paths[0].path)
        guard case .cubic(_, _, let end)? = segs.last else { Issue.record("\(segs)"); return }
        #expect(near(end.x - 100, end.y - 50, 0.01))
        #expect(end.x > 100 && end.y > 50)
    }

    @Test func avLstAndGuidesInCustom() throws {
        let g = GeometryBuilder.paths(try custom("""
            <a:avLst><a:gd name="adj" fmla="val 25000"/></a:avLst>
            <a:gdLst><a:gd name="x" fmla="*/ w adj 100000"/></a:gdLst>
            <a:pathLst><a:path><a:moveTo><a:pt x="x" y="t"/></a:moveTo><a:lnTo><a:pt x="r" y="b"/></a:lnTo></a:path></a:pathLst>
            """), size: size)
        #expect(segments(g.paths[0].path) == [.move(CGPoint(x: 50, y: 0)), .line(CGPoint(x: 200, y: 100))])
    }

    @Test func malformedCustomNeverCrashes() throws {
        let cases = [
            "",
            "<a:pathLst/>",
            "<a:pathLst><a:path w=\"0\" h=\"-3\"><a:lnTo><a:pt x=\"5\"/></a:lnTo><a:arcTo/><a:close/><a:quadBezTo/></a:path></a:pathLst>",
            "<a:pathLst><a:path><a:arcTo wR=\"x\" hR=\"1e308\" stAng=\"1e308\" swAng=\"1e308\"/></a:path></a:pathLst>",
            "<a:gdLst><a:gd name=\"a\" fmla=\"*/ a a 0\"/></a:gdLst><a:pathLst><a:path><a:moveTo><a:pt x=\"a\" y=\"nan\"/></a:moveTo></a:path></a:pathLst>",
        ]
        for c in cases {
            let g = GeometryBuilder.paths(try custom(c), size: size)
            for p in g.paths {
                #expect(allPoints(p.path).allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(c)")
            }
        }
        #expect(GeometryBuilder.paths(try custom("<a:pathLst/>"), size: size).paths.isEmpty)
    }
}

@Suite struct GeometryFromSpPrTests {
    private func spPr(_ inner: String) throws -> OOXMLNode {
        try OOXMLNode.parse(Data("<p:spPr xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" \(aNS)>\(inner)</p:spPr>".utf8))
    }

    @Test func preset() throws {
        let g = GeometryBuilder.geometry(from: try spPr("""
            <a:xfrm/><a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val 8000"/><a:gd name="bad" fmla="*/ 1 2 3"/></a:avLst></a:prstGeom>
            """))
        guard case .preset(let name, let adjust)? = g else { Issue.record("\(String(describing: g))"); return }
        #expect(name == "roundRect")
        #expect(adjust == ["adj": 8000])
    }

    @Test func customAndNone() throws {
        let g = GeometryBuilder.geometry(from: try spPr("<a:custGeom><a:pathLst/></a:custGeom>"))
        guard case .custom(let node)? = g else { Issue.record("\(String(describing: g))"); return }
        #expect(node.name == "custGeom")
        #expect(GeometryBuilder.geometry(from: try spPr("<a:xfrm/>")) == nil)
        #expect(GeometryBuilder.geometry(from: nil) == nil)
        #expect(GeometryBuilder.geometry(from: try spPr("<a:prstGeom/>")) == nil)
    }
}
