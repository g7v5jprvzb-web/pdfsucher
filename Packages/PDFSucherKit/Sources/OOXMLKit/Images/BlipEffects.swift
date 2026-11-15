// BlipEffects.swift — slidekit-ref (OOXMLKit)
// Picture recolouring from the children of `a:blip` (ECMA-376 §20.1.8): duotone, grayscl, clrChange, biLevel and
// lum, applied in document order to a decoded bitmap (metafiles are rasterized first, DrawingRenderer). alphaModFix stays on
// ImageRef (drawn with ctx.setAlpha). Formulas (the spec gives none, docs/decisions.md): luminance = BT.601 luma
// of the sRGB values; duotone mixes its first colour (dark end) and second colour (light end) by luminance;
// clrChange replaces pixels within 2.5/255 per channel of clrFrom by clrTo (its alpha included; `useA` is ignored,
// the source alpha never takes part in the match); biLevel → white at
// luminance ≥ thresh, else black; lum: contrast c (−1…1) as v' = (v − ½)·k + ½ with k = 1/(1 − c) for c > 0 and
// 1 + c for c ≤ 0, then brightness + b.
import CoreGraphics
import Foundation

public enum BlipEffect: Sendable, Hashable {
    case duotone(RGBA, RGBA)
    case grayscale
    case colorChange(from: RGBA, to: RGBA)
    case biLevel(threshold: Double)
    case luminance(bright: Double, contrast: Double)

    /// The recolour effects of `a:blip`, in document order; unresolvable colours drop that effect.
    public static func parse(blip: OOXMLNode, colors: ColorContext) -> [BlipEffect] {
        var out: [BlipEffect] = []
        for el in blip.children {
            switch el.name {
            case "duotone":
                let cs = el.children.compactMap { c -> RGBA? in
                    let wrapper = OOXMLNode(name: "w", children: [c])
                    return ColorResolver.resolve(wrapper, in: colors)
                }
                if cs.count == 2 { out.append(.duotone(cs[0], cs[1])) }
            case "grayscl":
                out.append(.grayscale)
            case "clrChange":
                if let f = el.child("clrFrom").flatMap({ ColorResolver.resolve($0, in: colors) }),
                   let t = el.child("clrTo").flatMap({ ColorResolver.resolve($0, in: colors) }) {
                    out.append(.colorChange(from: f, to: t))
                }
            case "biLevel":
                let t = Units.parsePercentage(el.attr("thresh") ?? "50000") ?? 0.5
                out.append(.biLevel(threshold: t.isFinite ? t : 0.5))
            case "lum":
                let b = Units.parsePercentage(el.attr("bright") ?? "0") ?? 0
                let c = Units.parsePercentage(el.attr("contrast") ?? "0") ?? 0
                if (b != 0 || c != 0), b.isFinite, c.isFinite { out.append(.luminance(bright: b, contrast: c)) }
            default:
                continue
            }
        }
        return out
    }

    /// `img` with `effects` applied (sRGB RGBA8); nil if the bitmap cannot be created.
    public static func apply(_ effects: [BlipEffect], to img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard !effects.isEmpty, w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0 else { continue }
            // Un-premultiplied colour 0…1.
            var r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            var alpha = a
            for e in effects {
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                switch e {
                case .duotone(let c1, let c2):
                    r = c1.r + (c2.r - c1.r) * luma
                    g = c1.g + (c2.g - c1.g) * luma
                    b = c1.b + (c2.b - c1.b) * luma
                case .grayscale:
                    r = luma; g = luma; b = luma
                case .colorChange(let from, let to):
                    let tol = 2.5 / 255
                    if abs(r - from.r) <= tol, abs(g - from.g) <= tol, abs(b - from.b) <= tol {
                        r = to.r; g = to.g; b = to.b; alpha *= to.a
                    }
                case .biLevel(let t):
                    let v: Double = luma >= t ? 1 : 0
                    r = v; g = v; b = v
                case .luminance(let bright, let contrast):
                    let k = contrast > 0 ? 1 / max(1 - contrast, 1e-3) : 1 + contrast
                    r = (r - 0.5) * k + 0.5 + bright
                    g = (g - 0.5) * k + 0.5 + bright
                    b = (b - 0.5) * k + 0.5 + bright
                }
                r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1)
            }
            alpha = min(max(alpha, 0), 1)
            px[i] = UInt8((r * alpha * 255).rounded())
            px[i + 1] = UInt8((g * alpha * 255).rounded())
            px[i + 2] = UInt8((b * alpha * 255).rounded())
            px[i + 3] = UInt8((alpha * 255).rounded())
        }
        return ctx.makeImage()
    }
}
