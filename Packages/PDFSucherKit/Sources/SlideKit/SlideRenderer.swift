// SlideRenderer.swift — Task 9 (SlideKit)
// Draws a SlideModel: white base, background, then the elements in order (master, layout, slide), each shape's
// text (SlideTextLayout) in DrawingRenderer's text pass.
//
// Coordinate convention: `draw(_:size:in:renderer:)` expects the CTM to map slide points with the origin at the
// top left and y down (OOXMLKit's DrawingRenderer convention); `SlideDeck.draw` sets that up.
//
// Shadows: DrawingRenderer maps outer-shadow offsets through `ctx.ctm`, assuming base space = the space of the
// CTM. That holds for bitmap and PDF contexts; NSImage drawing-handler contexts (and possibly PDFView tiles) have a
// scaled base CTM, where shadows land up to 2× too far (Task 12c, see docs/decisions.md).
import CoreGraphics
import Foundation
import OOXMLKit

enum SlideRenderer {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    static func draw(_ model: SlideModel, text: SlideTextLayout, size: CGSize, in ctx: CGContext,
                     renderer: DrawingRenderer, fonts: FontResolver) {
        let bounds = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.setFillColor(white)
        ctx.fill(bounds)
        ctx.restoreGState()
        if model.background != .none {
            renderer.drawShape(ShapeModel(transform: Transform2D(extent: size), fill: model.background), in: ctx)
        }
        for e in model.elements {
            draw(e, text: text, in: ctx, renderer: renderer, fonts: fonts, groupFill: .none, mirroredByGroups: false)
        }
    }

    /// Like `DrawingRenderer.drawGroup` for groups (child space, inherited group fill, mirror parity, boxes scaled by
    /// the group chain instead of stretched: `GroupScale`), with graphic frames as an extra element kind.
    /// `chain`: the enclosing groups' child → slide transform (identity at the top level), not in the CTM.
    static func draw(_ element: SlideElement, text: SlideTextLayout, in ctx: CGContext, renderer: DrawingRenderer,
                     fonts: FontResolver, groupFill: Fill, mirroredByGroups: Bool, chain: CGAffineTransform = .identity) {
        guard let split = GroupScale(chain) else { return }
        switch element {
        case .shape(var s):
            let laidOut = s.tag.flatMap(text.shape(tag:))
            s.transform = split.scaled(s.transform)
            ctx.saveGState()
            ctx.concatenate(split.rest)
            renderer.drawShape(s, in: ctx, groupFill: groupFill, mirroredByGroups: mirroredByGroups) { c, _ in
                laidOut?.draw(in: c, renderer: renderer, fonts: fonts)
            }
            ctx.restoreGState()
        case .picture(var p):
            p.transform = split.scaled(p.transform)
            ctx.saveGState()
            ctx.concatenate(split.rest)
            renderer.drawPicture(p, in: ctx, lineOutside: true)
            ctx.restoreGState()
        case .group(let g, let children):
            let m = g.transform.childToParent.concatenating(chain)
            guard [m.a, m.b, m.c, m.d, m.tx, m.ty].allSatisfy(\.isFinite) else { return }
            let inherited = g.fill == .group ? groupFill : g.fill
            let mirrored = mirroredByGroups != (g.transform.flipH != g.transform.flipV)
            for child in children {
                draw(child, text: text, in: ctx, renderer: renderer, fonts: fonts, groupFill: inherited,
                     mirroredByGroups: mirrored, chain: m)
            }
        case .graphicFrame(let f):
            // Tables (Task 12a) and charts (Task 12b); SmartArt and OLE objects are groups and pictures by now.
            // Their layouts are in the frame's parent space (the group chain is part of their own layout).
            ctx.saveGState()
            ctx.concatenate(chain)
            if let t = f.table, let laidOut = text.tables[t.id] {
                TableRenderer.draw(laidOut, in: ctx, renderer: renderer, fonts: fonts)
            }
            if let c = f.chart, let laidOut = text.charts[c.id] {
                laidOut.draw(in: ctx, fonts: fonts)
            }
            ctx.restoreGState()
        }
    }
}
