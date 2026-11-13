// HighlightGeometry.swift — 1.1 Task 11 (spec 1.1 §14). Pure: also meant for OCR boxes in 1.2.
import CoreGraphics
import Foundation

/// How matches are marked on a tile.
public enum HighlightStyle: Equatable, Sendable {
    /// Exactly on the found word (large tiles, the large preview).
    case exact
    /// Grown to a minimum size on screen plus a margin, merged, with a stripe at the left edge (small tiles).
    case enlarged
}

/// Boxes (page coordinates) and the vertical extents of the left-edge stripes.
public struct HighlightLayout: Equatable, Sendable {
    public var boxes: [CGRect]
    public var stripes: [ClosedRange<CGFloat>]
}

public enum HighlightGeometry {
    /// Tile width (screen pt) from which marks are exact (Claude's choice, spec §14).
    public static let threshold: CGFloat = 280
    /// Minimum size of an enlarged mark on screen, and its margin, in screen pt.
    public static let minimumSize = CGSize(width: 24, height: 16)
    public static let margin: CGFloat = 3
    public static let stripeWidth: CGFloat = 4
    public static let exactOpacity = 0.45
    public static let enlargedOpacity = 0.70

    public static func style(forTileWidth width: CGFloat) -> HighlightStyle {
        width < threshold ? .enlarged : .exact
    }

    /// - Parameters:
    ///   - matchRects: one rectangle per matched word part (per line), in page coordinates.
    ///   - pageBounds: the page in the same coordinates; every box is clipped to it.
    ///   - scale: screen pt per page unit of the drawn page.
    public static func layout(matchRects: [CGRect], pageBounds: CGRect, scale: CGFloat, style: HighlightStyle) -> HighlightLayout {
        let clipped = { (r: CGRect) -> CGRect? in
            let c = r.intersection(pageBounds)
            return c.isNull || c.isEmpty ? nil : c
        }
        switch style {
        case .exact:
            return HighlightLayout(boxes: matchRects.compactMap(clipped), stripes: [])
        case .enlarged:
            let s = max(scale, 0.0001)
            let minW = minimumSize.width / s, minH = minimumSize.height / s, m = margin / s
            let grown = matchRects.compactMap { r -> CGRect? in
                let w = max(r.width, minW), h = max(r.height, minH)
                let box = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h).insetBy(dx: -m, dy: -m)
                return clipped(box)
            }
            let boxes = merged(grown)
            return HighlightLayout(boxes: boxes, stripes: boxes.map { $0.minY...$0.maxY })
        }
    }

    /// Overlapping boxes become one (their union), repeated until no two overlap (a merged box moves to the end).
    static func merged(_ boxes: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for box in boxes {
            var current = box
            var changed = true
            while changed {
                changed = false
                if let i = result.firstIndex(where: { $0.intersects(current) }) {
                    current = current.union(result.remove(at: i))
                    changed = true
                }
            }
            result.append(current)
        }
        return result
    }
}
