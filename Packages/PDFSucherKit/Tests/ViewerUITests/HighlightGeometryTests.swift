import AppKit
import Foundation
import OutputKit
import PDFKit
import Testing
import TestSupport
@testable import ViewerUI

/// Spec 1.1 §14: enlarged highlights on small tiles, highlight colour.
@Suite("Highlight geometry")
struct HighlightGeometryTests {
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)

    @Test func thresholdSwitchesAt280() {
        #expect(HighlightGeometry.threshold == 280)
        #expect(HighlightGeometry.style(forTileWidth: 279) == .enlarged)
        #expect(HighlightGeometry.style(forTileWidth: 279.9) == .enlarged)
        #expect(HighlightGeometry.style(forTileWidth: 280) == .exact)
        #expect(HighlightGeometry.style(forTileWidth: 900) == .exact)
    }

    @Test func enlargedHasMinimumSizeAndMargin() {
        // scale 0.2: 1 page pt = 0.2 screen pt; minimum 24 × 16 screen pt = 120 × 80 page pt, margin 3 = 15.
        let word = CGRect(x: 300, y: 400, width: 20, height: 10)
        let layout = HighlightGeometry.layout(matchRects: [word], pageBounds: page, scale: 0.2, style: .enlarged)
        let box = try! #require(layout.boxes.first)
        #expect(abs(box.width - (120 + 30)) < 0.001)
        #expect(abs(box.height - (80 + 30)) < 0.001)
        #expect(abs(box.midX - word.midX) < 0.001 && abs(box.midY - word.midY) < 0.001)
        // A rect already larger than the minimum only gets the margin.
        let wide = CGRect(x: 100, y: 100, width: 300, height: 100)
        let grown = HighlightGeometry.layout(matchRects: [wide], pageBounds: page, scale: 0.2, style: .enlarged).boxes[0]
        #expect(grown == wide.insetBy(dx: -15, dy: -15))
    }

    @Test func exactKeepsRects() {
        let words = [CGRect(x: 10, y: 10, width: 30, height: 12), CGRect(x: 15, y: 12, width: 30, height: 12)]
        let layout = HighlightGeometry.layout(matchRects: words, pageBounds: page, scale: 0.2, style: .exact)
        #expect(layout.boxes == words)
        #expect(layout.stripes.isEmpty)
    }

    @Test func clippedAtPageEdge() {
        let corner = CGRect(x: 0, y: 790, width: 10, height: 10)
        let box = HighlightGeometry.layout(matchRects: [corner], pageBounds: page, scale: 0.2, style: .enlarged).boxes[0]
        #expect(page.contains(box))
        #expect(box.minX == 0 && box.maxY == 800)
        let outside = CGRect(x: 700, y: 900, width: 10, height: 10)
        #expect(HighlightGeometry.layout(matchRects: [outside], pageBounds: page, scale: 1, style: .exact).boxes.isEmpty)
    }

    @Test func overlappingBoxesMerge() {
        // A∩B and B∩C, A and C apart: one area.
        let a = CGRect(x: 100, y: 100, width: 10, height: 10)
        let b = CGRect(x: 180, y: 100, width: 10, height: 10)
        let c = CGRect(x: 260, y: 100, width: 10, height: 10)
        let far = CGRect(x: 100, y: 600, width: 10, height: 10)
        let layout = HighlightGeometry.layout(matchRects: [a, c, far, b], pageBounds: page, scale: 0.2, style: .enlarged)
        #expect(layout.boxes.count == 2)
        #expect(layout.stripes.count == 2)
        let merged = layout.boxes.first { $0.minY < 300 }!
        #expect(merged.minX < a.minX && merged.maxX > c.maxX)
    }

    @Test func stripePositionsTopMiddleBottom() {
        let rects = [CGRect(x: 300, y: 760, width: 20, height: 10),   // top (PDF y grows upwards)
                     CGRect(x: 300, y: 400, width: 20, height: 10),
                     CGRect(x: 300, y: 20, width: 20, height: 10)]
        let layout = HighlightGeometry.layout(matchRects: rects, pageBounds: page, scale: 0.2, style: .enlarged)
        let centres = layout.stripes.map { ($0.lowerBound + $0.upperBound) / 2 }.sorted()
        #expect(centres.count == 3)
        #expect(abs(centres[0] - 25) < 30 && abs(centres[1] - 405) < 1 && abs(centres[2] - 765) < 30)
        for (stripe, box) in zip(layout.stripes, layout.boxes) {
            #expect(stripe.lowerBound == box.minY && stripe.upperBound == box.maxY)
        }
        #expect(HighlightGeometry.stripeWidth == 4)
    }

    @MainActor @Test func colourPersistsAndResets() {
        let defaults = UserDefaults(suiteName: "HL-\(UUID())")!
        let s = GridSettings(defaults: defaults)
        #expect(s.highlightColor == RGBA(r: 1, g: 1, b: 0, a: 1))
        s.highlightColor = RGBA(r: 0.2, g: 0.8, b: 1, a: 1)
        #expect(defaults.data(forKey: "highlight.color") != nil)
        #expect(GridSettings(defaults: defaults).highlightColor == RGBA(r: 0.2, g: 0.8, b: 1, a: 1))
        s.resetHighlightColor()
        #expect(s.highlightColor == RGBA(r: 1, g: 1, b: 0, a: 1))
        #expect(GridSettings(defaults: defaults).highlightColor == RGBA(r: 1, g: 1, b: 0, a: 1))
        #expect(HighlightGeometry.exactOpacity == 0.45 && HighlightGeometry.enlargedOpacity == 0.70)
    }

    /// Snapshot: a small tile has the stripe at its left edge and larger marks, a large tile neither.
    @Test func snapshotSmallAndLargeTile() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("hl.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Der Vertrag beginnt hier. Weitere Worte folgen ohne den Begriff."])
        let ranges: HighlightRanges = { text in text.range(of: "Vertrag").map { [$0] } ?? [] }
        let cache = ThumbnailCache(scale: 1)
        let ref = PageRef(url: url, pageIndex: 0)
        let red = RGBA(r: 1, g: 0, b: 0, a: 1)       // easy to count
        func stats(_ width: CGFloat) async throws -> (stripe: Int, marked: Double, tinted: Int) {
            let size = CGSize(width: width, height: width * 1.414)
            let image = try #require(await cache.thumbnail(for: ref, size: size, highlightKey: "v", highlightRanges: ranges, highlightColor: red))
            var rect = CGRect(origin: .zero, size: size)
            let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let rep = NSBitmapImageRep(cgImage: cg)
            var stripe = 0, marked = 0, tinted = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // Any red tint (exact marks: 45 % multiply gives green ≈ 0.55).
                    if c.redComponent > 0.9, c.greenComponent < 0.75, abs(c.greenComponent - c.blueComponent) < 0.1 { tinted += 1 }
                    if c.redComponent > 0.8, c.greenComponent < 0.5, c.blueComponent < 0.5 {
                        marked += 1
                        if x < 6 { stripe += 1 }
                    }
                }
            }
            return (stripe, Double(marked) / Double(rep.pixelsWide * rep.pixelsHigh), tinted)
        }
        let small = try await stats(200)
        let large = try await stats(400)
        #expect(small.stripe > 0, "stripe at the left edge of a small tile")
        #expect(large.stripe == 0, "no stripe on a large tile")
        #expect(large.tinted > 20, "the large tile marks the word exactly: \(large.tinted) tinted pixels")
        #expect(large.marked < 0.001, "no enlarged 70 % marks on a large tile")
        #expect(small.marked > 0.005, "enlarged marks on a small tile: \(small.marked)")
    }

    /// Review of Task 11: tiles of 275–284 pt share the 10 pt cache rounding; the style must be in the key.
    @Test func cacheSeparatesStylesAroundTheThreshold() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("hl2.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Der Vertrag beginnt hier."])
        let ranges: HighlightRanges = { text in text.range(of: "Vertrag").map { [$0] } ?? [] }
        let cache = ThumbnailCache(scale: 1)
        let ref = PageRef(url: url, pageIndex: 0)
        let below = await cache.thumbnail(for: ref, size: CGSize(width: 276, height: 400), highlightKey: "v", highlightRanges: ranges)
        let above = await cache.thumbnail(for: ref, size: CGSize(width: 283, height: 400), highlightKey: "v", highlightRanges: ranges)
        #expect(below != nil && above != nil)
        #expect(below !== above, "an enlarged image must not be reused for an exact tile")
    }
}
