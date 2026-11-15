// PresetGeometry.swift — Task 4 (OOXMLKit)
// DrawingML shape geometry (ECMA-376 Part 1 §20.1.9): preset shapes (`a:prstGeom`, definitions from Annex D,
// embedded in PresetShapeDefinitions.swift) and custom geometry (`a:custGeom`), turned into CGPaths.
//
// Coordinate convention: `size` and all output (paths, textRect) are in points in *shape space*, origin top
// left, y pointing down — the renderer draws them under a flipped CTM. Guides are evaluated in EMU
// (size × 12700), as PowerPoint does, so literal EMU values in custGeom formulas and paths without w/h work.
import CoreGraphics
import Foundation
import Synchronization

public enum Geometry: Sendable {
    case preset(String, adjust: [String: Double])
    case custom(OOXMLNode)
}

/// `a:path@fill`: how a sub-path is filled. lighten/darken variants modulate the shape's fill colour.
public enum PathFillMode: Sendable, Equatable {
    case norm, none, lighten, lightenLess, darken, darkenLess
}

/// One `a:path` of a geometry.
/// `@unchecked Sendable`: CGPath is an immutable CF object (thread-safe to read) but not annotated `Sendable`.
/// The initializer stores an immutable copy, so a `CGMutablePath` passed in cannot be mutated afterwards.
public struct GeometryPath: @unchecked Sendable {
    public let path: CGPath
    public var fill: PathFillMode
    public var stroke: Bool

    public init(path: CGPath, fill: PathFillMode = .norm, stroke: Bool = true) {
        self.path = path.copy() ?? path
        self.fill = fill
        self.stroke = stroke
    }
}

public struct GeometryPaths: Sendable {
    public var paths: [GeometryPath]
    /// Text rectangle (`a:rect`) in shape space; nil if the geometry defines none.
    public var textRect: CGRect?

    public init(paths: [GeometryPath], textRect: CGRect?) {
        self.paths = paths
        self.textRect = textRect
    }
}

public enum GeometryBuilder {
    /// Builds the paths for `g` at `size` (points). Unknown or unusable presets yield a rectangle; a custom
    /// geometry without usable paths yields no paths. Never traps; all coordinates are finite.
    public static func paths(_ g: Geometry, size: CGSize) -> GeometryPaths {
        let w = sanitizedLength(size.width), h = sanitizedLength(size.height)
        switch g {
        case .preset(let name, let adjust):
            guard let def = PresetGeometry.definition(name) else { return rectangle(w, h) }
            let built = build(def, adjust: adjust, width: w, height: h)
            return built.paths.isEmpty ? rectangle(w, h) : built
        case .custom(let node):
            return build(node, adjust: [:], width: w, height: h)
        }
    }

    /// Reads `a:prstGeom` (prst + avLst `gd fmla="val N"`) or `a:custGeom` from a shape-properties element.
    public static func geometry(from spPr: OOXMLNode?) -> Geometry? {
        guard let spPr else { return nil }
        if let prst = spPr.child("prstGeom"), let name = prst.attr("prst"), !name.isEmpty {
            var adjust: [String: Double] = [:]
            for gd in prst.child("avLst")?.children("gd") ?? [] {
                guard let n = gd.attr("name"), let f = gd.attr("fmla") else { continue }
                let parts = f.split(whereSeparator: \.isWhitespace)
                if parts.count == 2, parts[0] == "val", let v = Double(parts[1]), v.isFinite { adjust[n] = v }
            }
            return .preset(name, adjust: adjust)
        }
        if let cust = spPr.child("custGeom") { return .custom(cust) }
        return nil
    }

    // MARK: building

    static let emuPerPoint = Units.emuPerPoint
    /// Larger sizes are clamped (no slide is that big; keeps EMU products finite).
    static let maxLength = 1.0e8

    static func sanitizedLength(_ v: CGFloat) -> Double {
        let d = Double(v)
        guard d.isFinite, d > 0 else { return 0 }
        return min(d, maxLength)
    }

    static func rectangle(_ w: Double, _ h: Double) -> GeometryPaths {
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        return GeometryPaths(paths: [GeometryPath(path: CGPath(rect: r, transform: nil))], textRect: r)
    }

    /// `def` is a preset element or an `a:custGeom`: both have avLst, gdLst, rect, pathLst children.
    static func build(_ def: OOXMLNode, adjust: [String: Double], width: Double, height: Double) -> GeometryPaths {
        let k = emuPerPoint
        var ctx = GuideContext(width: width * k, height: height * k)
        for gd in def.child("avLst")?.children("gd") ?? [] {
            if let n = gd.attr("name") { ctx.define(n, gd.attr("fmla") ?? "") }
        }
        for (n, v) in adjust { ctx.set(n, v) }
        for gd in def.child("gdLst")?.children("gd") ?? [] {
            if let n = gd.attr("name") { ctx.define(n, gd.attr("fmla") ?? "") }
        }

        var textRect: CGRect?
        if let r = def.child("rect") {
            let l = ctx.value(r.attr("l") ?? "l") / k, t = ctx.value(r.attr("t") ?? "t") / k
            let rr = ctx.value(r.attr("r") ?? "r") / k, b = ctx.value(r.attr("b") ?? "b") / k
            textRect = CGRect(x: min(l, rr), y: min(t, b), width: abs(rr - l), height: abs(b - t))
        }

        var paths: [GeometryPath] = []
        for p in def.child("pathLst")?.children("path") ?? [] {
            if let gp = buildPath(p, ctx: ctx, width: width * k, height: height * k) { paths.append(gp) }
        }
        return GeometryPaths(paths: paths, textRect: textRect)
    }

    static func fillMode(_ s: String?) -> PathFillMode {
        switch s {
        case "none": .none
        case "lighten": .lighten
        case "lightenLess": .lightenLess
        case "darken": .darken
        case "darkenLess": .darkenLess
        default: .norm
        }
    }

    static func bool(_ s: String?, default d: Bool) -> Bool {
        switch s {
        case "0", "false": false
        case "1", "true": true
        default: d
        }
    }

    /// One `a:path`. Its own w/h (if > 0) define the coordinate space that is scaled to the shape size.
    /// `extrusionOk` only matters for 3D and is ignored.
    static func buildPath(_ node: OOXMLNode, ctx: GuideContext, width: Double, height: Double) -> GeometryPath? {
        let k = emuPerPoint
        let pw = node.attr("w").flatMap(Double.init) ?? 0
        let ph = node.attr("h").flatMap(Double.init) ?? 0
        // Factors from path units to output points.
        let fx = finiteOrZero((pw.isFinite && pw > 0 ? width / pw : 1) / k)
        let fy = finiteOrZero((ph.isFinite && ph > 0 ? height / ph : 1) / k)

        let path = CGMutablePath()
        var current: CGPoint?
        var subpathStart = CGPoint.zero
        var needsMove = true

        func point(_ pt: OOXMLNode?) -> CGPoint {
            CGPoint(x: finiteOrZero(ctx.value(pt?.attr("x") ?? "0") * fx), y: finiteOrZero(ctx.value(pt?.attr("y") ?? "0") * fy))
        }
        /// Ensures a current point (CG needs one before lines/curves) and returns it.
        func begin() -> CGPoint {
            let c = current ?? .zero
            if needsMove {
                path.move(to: c)
                subpathStart = c
                current = c
                needsMove = false
            }
            return c
        }

        for cmd in node.children {
            switch cmd.name {
            case "moveTo":
                let p = point(cmd.child("pt"))
                path.move(to: p)
                current = p; subpathStart = p; needsMove = false
            case "lnTo":
                let p = point(cmd.child("pt"))
                _ = begin()
                path.addLine(to: p)
                current = p
            case "quadBezTo":
                let pts = cmd.children("pt")
                guard pts.count >= 2 else { continue }
                _ = begin()
                let c1 = point(pts[0]), e = point(pts[1])
                path.addQuadCurve(to: e, control: c1)
                current = e
            case "cubicBezTo":
                let pts = cmd.children("pt")
                guard pts.count >= 3 else { continue }
                _ = begin()
                let c1 = point(pts[0]), c2 = point(pts[1]), e = point(pts[2])
                path.addCurve(to: e, control1: c1, control2: c2)
                current = e
            case "arcTo":
                let start = begin()
                let wR = ctx.value(cmd.attr("wR") ?? "0"), hR = ctx.value(cmd.attr("hR") ?? "0")
                let stAng = ctx.value(cmd.attr("stAng") ?? "0"), swAng = ctx.value(cmd.attr("swAng") ?? "0")
                current = addArc(to: path, from: start, wR: wR, hR: hR, stAng: stAng, swAng: swAng, fx: fx, fy: fy)
            case "close":
                guard current != nil, !needsMove else { continue }
                path.closeSubpath()
                current = subpathStart
                needsMove = true
            default:
                continue
            }
        }
        if path.isEmpty { return nil }
        return GeometryPath(path: path, fill: fillMode(node.attr("fill")),
                            stroke: bool(node.attr("stroke"), default: true))
    }

    /// `a:arcTo`: the arc starts at the current point. stAng/swAng (60000ths of a degree) are visual angles,
    /// clockwise from the x axis in y-down space; they are converted to the ellipse's parametric angles.
    /// The arc is emitted as cubic Béziers (≤ 90° each). Returns the end point.
    static func addArc(to path: CGMutablePath, from start: CGPoint, wR: Double, hR: Double,
                       stAng: Double, swAng: Double, fx: Double, fy: Double) -> CGPoint {
        let toRad = Double.pi / 180 / 60000
        let twoPi = 2 * Double.pi
        var sweep = finiteOrZero(swAng * toRad)
        if abs(sweep) > twoPi {   // keep the end point, cap the work at two turns
            sweep = (sweep < 0 ? -1 : 1) * (twoPi + abs(sweep).truncatingRemainder(dividingBy: twoPi))
        }
        let theta0 = finiteOrZero(stAng * toRad).truncatingRemainder(dividingBy: twoPi)
        let theta1 = theta0 + sweep

        func parametric(_ t: Double) -> Double {
            guard wR != 0, hR != 0 else { return t }
            return atan2(wR * sin(t), hR * cos(t))
        }
        let phi0 = parametric(theta0)
        var delta = parametric(theta1) - phi0
        delta += twoPi * ((sweep - delta) / twoPi).rounded()
        delta = finiteOrZero(delta)

        let rx = finiteOrZero(wR * fx), ry = finiteOrZero(hR * fy)
        let cx = finiteOrZero(Double(start.x) - rx * cos(phi0)), cy = finiteOrZero(Double(start.y) - ry * sin(phi0))
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: finiteOrZero(cx + rx * x), y: finiteOrZero(cy + ry * y)) }

        guard delta != 0 else { return start }
        let n = max(1, Int((abs(delta) / (Double.pi / 2) - 1e-9).rounded(.up)))
        let d = delta / Double(n)
        let kk = 4.0 / 3.0 * tan(d / 4)
        var a = phi0
        var end = start
        for _ in 0..<n {
            let b = a + d
            let (ca, sa, cb, sb) = (cos(a), sin(a), cos(b), sin(b))
            end = pt(cb, sb)
            path.addCurve(to: end, control1: pt(ca - kk * sa, sa + kk * ca), control2: pt(cb + kk * sb, sb - kk * cb))
            a = b
        }
        return end
    }
}

@inline(__always) func finiteOrZero(_ v: Double) -> Double { v.isFinite ? v : 0 }

// MARK: guides

/// Guide values (ECMA-376 §20.1.9.11): builtins, then avLst/gdLst definitions in document order.
/// Unknown names → 0, non-finite results (division by zero, sqrt of a negative, overflow) → 0.
struct GuideContext {
    private var values: [String: Double]

    init(width: Double, height: Double) {
        let w = finiteOrZero(width), h = finiteOrZero(height)
        let ss = min(w, h), ls = max(w, h)
        values = [
            "w": w, "h": h, "l": 0, "t": 0, "r": w, "b": h, "hc": w / 2, "vc": h / 2,
            "wd2": w / 2, "wd3": w / 3, "wd4": w / 4, "wd5": w / 5, "wd6": w / 6, "wd8": w / 8,
            "wd10": w / 10, "wd12": w / 12, "wd32": w / 32,
            "hd2": h / 2, "hd3": h / 3, "hd4": h / 4, "hd5": h / 5, "hd6": h / 6, "hd8": h / 8,
            "hd10": h / 10, "hd12": h / 12,
            "ss": ss, "ls": ls, "ssd2": ss / 2, "ssd4": ss / 4, "ssd6": ss / 6, "ssd8": ss / 8,
            "ssd16": ss / 16, "ssd32": ss / 32,
            "cd2": 10_800_000, "cd4": 5_400_000, "cd8": 2_700_000, "3cd4": 16_200_000, "3cd8": 8_100_000,
            "5cd8": 13_500_000, "7cd8": 18_900_000,
        ]
    }

    /// A guide name or a numeric literal.
    func value<S: StringProtocol>(_ token: S) -> Double {
        let s = String(token)
        if let v = values[s] { return v }
        return finiteOrZero(Double(s) ?? 0)
    }

    mutating func set(_ name: String, _ v: Double) { values[name] = finiteOrZero(v) }

    mutating func define(_ name: String, _ fmla: String) { values[name] = evaluate(fmla) }

    func evaluate(_ fmla: String) -> Double {
        let parts = fmla.split(whereSeparator: \.isWhitespace)
        guard let op = parts.first else { return 0 }
        let args = parts.dropFirst().map { value($0) }
        func need(_ n: Int) -> Bool { args.count >= n }
        let deg = Double.pi / 180 / 60000
        let r: Double
        switch op {
        case "val": guard need(1) else { return 0 }; r = args[0]
        case "*/": guard need(3) else { return 0 }; r = args[2] == 0 ? 0 : args[0] * args[1] / args[2]
        case "+-": guard need(3) else { return 0 }; r = args[0] + args[1] - args[2]
        case "+/": guard need(3) else { return 0 }; r = args[2] == 0 ? 0 : (args[0] + args[1]) / args[2]
        case "?:": guard need(3) else { return 0 }; r = args[0] > 0 ? args[1] : args[2]
        case "abs": guard need(1) else { return 0 }; r = abs(args[0])
        case "at2": guard need(2) else { return 0 }; r = atan2(args[1], args[0]) / deg
        case "cat2": guard need(3) else { return 0 }; r = args[0] * cos(atan2(args[2], args[1]))
        case "sat2": guard need(3) else { return 0 }; r = args[0] * sin(atan2(args[2], args[1]))
        case "cos": guard need(2) else { return 0 }; r = args[0] * cos(args[1] * deg)
        case "sin": guard need(2) else { return 0 }; r = args[0] * sin(args[1] * deg)
        case "tan": guard need(2) else { return 0 }; r = args[0] * tan(args[1] * deg)
        case "max": guard need(2) else { return 0 }; r = max(args[0], args[1])
        case "min": guard need(2) else { return 0 }; r = min(args[0], args[1])
        case "mod": guard need(3) else { return 0 }; r = (args[0] * args[0] + args[1] * args[1] + args[2] * args[2]).squareRoot()
        case "pin": guard need(3) else { return 0 }; r = args[1] < args[0] ? args[0] : (args[1] > args[2] ? args[2] : args[1])
        case "sqrt": guard need(1) else { return 0 }; r = args[0] < 0 ? 0 : args[0].squareRoot()
        default: return 0
        }
        return finiteOrZero(r)
    }
}

// MARK: preset table

enum PresetGeometry {
    /// Preset name → its XML line in `PresetShapeDefinitions.xml` (one preset per line).
    static let index: [String: Substring] = {
        var out: [String: Substring] = [:]
        for line in PresetShapeDefinitions.xml.split(separator: "\n") {
            guard line.first == "<", let end = line.firstIndex(where: { $0 == " " || $0 == ">" }) else { continue }
            let name = String(line[line.index(after: line.startIndex)..<end])
            if out[name] == nil { out[name] = line }
        }
        return out
    }()

    static var names: [String] { index.keys.sorted() }

    /// Parsed preset elements, filled on first use of each preset. A preset whose XML does not parse is
    /// cached as `.some(nil)` so it is not re-parsed on every draw. Unknown names never reach the cache.
    private static let cache = Mutex<[String: OOXMLNode?]>([:])

    static func definition(_ name: String) -> OOXMLNode? {
        if let hit = cache.withLock({ $0[name] }) { return hit }
        guard let line = index[name] else { return nil }
        let node = try? OOXMLNode.parse(Data(line.utf8))
        return cache.withLock { c in
            if let existing = c[name] { return existing }
            c[name] = .some(node)
            return node
        }
    }
}
