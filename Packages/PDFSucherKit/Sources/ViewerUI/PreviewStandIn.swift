// PreviewStandIn.swift — 1.3.4 Vorschau-Puffer
import AppKit
import OutputKit
import SwiftUI

/// What the large preview shows for the focused page until the PDFView has drawn it sharply (spec 1.3.4), where
/// the PDFView will show the page: (1) the prepared picture, (2) else the page's tile from the grid (memory or
/// disk), enlarged, (3) else a plain page of the right shape. Never the page of another file, never a spinner.
/// Opaque, so the PDFView below (still showing the previous page) is hidden; it takes no clicks.
struct PreviewStandIn: View {
    enum Level {
        case prepared(CGImage), tile(NSImage), blank

        init(prepared: CGImage?, tile: NSImage?) {
            if let prepared { self = .prepared(prepared) } else if let tile { self = .tile(tile) } else { self = .blank }
        }

        var name: String {
            switch self {
            case .prepared: "prepared"
            case .tile: "tile"
            case .blank: "blank"
            }
        }
    }

    /// A4 portrait: the page's shape while nothing about it is known yet.
    static let defaultPageSize = CGSize(width: 595, height: 842)

    let ref: PageRef
    let buffer: PreviewBuffer
    let cache: ThumbnailCache
    let marks: PreviewBuffer.Marks
    let layout: PreviewBuffer.Layout
    /// The tile found on disk for `ref`.
    @State private var stored: (ref: PageRef, image: NSImage)?

    var body: some View {
        let tile = cache.bestCachedImage(for: ref, highlightKey: marks.highlightKey, highlighted: marks.ranges != nil,
                                         highlightColor: marks.color)
            ?? cache.bestCachedImage(for: ref, highlightKey: "", highlighted: false)
            ?? (stored?.ref == ref ? stored?.image : nil)
        let level = Level(prepared: buffer.image(for: ref, marks: marks, layout: layout), tile: tile)
        let content = tile.flatMap(Self.content(of:))
        let page = buffer.pageSize(for: ref) ?? content?.rect.size ?? Self.defaultPageSize
        let scale = PreviewGeometry.scale(mode: layout.mode, fractions: layout.fractions, reference: layout.reference,
                                          beyondWidth: layout.beyondWidth, page: page, view: layout.viewSize)
        let frame = PreviewGeometry.frame(page: page, scale: scale, in: layout.viewSize)
        ZStack(alignment: .topLeading) {
            Color(nsColor: .underPageBackgroundColor)
            picture(level, content: content, size: frame.size)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: ref) {
            guard tile == nil, case .blank = level else { return }
            let found = await cache.storedImage(for: ref, highlightKey: marks.highlightKey, highlightRanges: marks.ranges,
                                                highlightColor: marks.color)
            guard !Task.isCancelled, let found else { return }
            stored = (ref, found)
        }
        .task(id: "\(ref.url.path)#\(ref.pageIndex)|\(level.name)") { PreviewTiming.event("standin.\(level.name)", ref) }
    }

    /// The page inside a tile picture (`PreviewGeometry.contentRect`), found once per picture.
    @MainActor private static let contents = NSMapTable<NSImage, NSValue>.weakToStrongObjects()

    static func content(of tile: NSImage) -> (rect: CGRect, pixels: CGSize)? {
        guard let cg = tile.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixels = CGSize(width: cg.width, height: cg.height)
        if let known = contents.object(forKey: tile) { return (known.rectValue, pixels) }
        guard let rect = PreviewGeometry.contentRect(of: cg) else { return nil }
        contents.setObject(NSValue(rect: rect), forKey: tile)
        return (rect, pixels)
    }

    @ViewBuilder private func picture(_ level: Level, content: (rect: CGRect, pixels: CGSize)?, size: CGSize) -> some View {
        switch level {
        case .prepared(let image):
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
        case .tile(let image):
            if let content {
                // Only the page part of the tile fills the page's place (the cell around it is transparent).
                let whole = PreviewGeometry.tileFrame(content: content.rect, imageSize: content.pixels, into: CGRect(origin: .zero, size: size))
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: whole.width, height: whole.height)
                    .offset(x: whole.minX, y: whole.minY)
            } else {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        case .blank:
            Rectangle().fill(.white).shadow(color: .black.opacity(0.15), radius: 2)
        }
    }
}
