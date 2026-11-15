// SlidePDFPage.swift — Task 12c (SlideKit)
// A PDFPage that draws one slide of a SlideDeck live (large preview, merger).
import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// One slide of a `SlideDeck` as a PDFKit page. It has no PDF content of its own: PDFKit calls
/// `draw(with:to:)` for display (PDFView, on a background tile thread) and printing, and when a `PDFDocument`
/// holding it is saved (`dataRepresentation()`, `write(to:)`), PDFKit records that drawing into the PDF as
/// vector content with real text (verified in SlidePDFPageTests, see docs/decisions.md).
///
/// Every box (media, crop, bleed, trim, art) is the slide: origin (0, 0), `deck.slideSize` points, unrotated
/// whatever `rotation` is (PDFKit's convention for every page). A rotated page (the merger may rotate pages) draws
/// rotated like an ordinary PDF page: `draw(with:to:)` applies `transform(_:for:)`, as `PDFPage`'s own drawing does
/// and as PDFView and printing expect; a saved copy carries /Rotate over unrotated content (docs/decisions.md).
///
/// `string` is `deck.slideText(slideIndex)` (normalized). PDFKit's own text features (`selection(for:)`,
/// `characterBounds(at:)`, find in PDFView) do not see this text, because the page has no PDF text layer;
/// highlighting uses `deck.wordBoxes`. A saved and reloaded copy is an ordinary PDF page with a text layer.
///
/// Concurrency: like any `PDFPage` this class is not Sendable; confine each instance to its PDFDocument/PDFView
/// (normally the main actor). PDFKit's own background drawing is safe: the stored properties are immutable and
/// the `deck` is Sendable, so it may also be shared with other background work (thumbnails, indexing).
public final class SlidePDFPage: PDFPage {
    public let deck: SlideDeck
    /// Index of the slide among the deck's visible slides. Out of range → an empty page of the slide size.
    public let slideIndex: Int

    public init(deck: SlideDeck, index: Int) {
        self.deck = deck
        self.slideIndex = index
        super.init()
    }

    /// The slide rect for every box.
    public override func bounds(for box: PDFDisplayBox) -> CGRect {
        CGRect(origin: .zero, size: deck.slideSize)
    }

    /// Draws the slide into `context` (y up), applying the page's rotation like `PDFPage.draw(with:to:)`: a page
    /// rotated by 90° fills a portrait area of the box's height × width. Rotation 0 draws in page space directly.
    /// Does not call super (PDFPage would draw a blank page).
    public override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard rotation % 360 != 0 else {
            deck.draw(slideIndex, in: context, rect: bounds(for: box))
            return
        }
        context.saveGState()
        transform(context, for: box)
        deck.draw(slideIndex, in: context, rect: bounds(for: box))
        context.restoreGState()
    }

    /// PDFKit's own `thumbnail(of:for:)` never calls `draw(with:to:)` for a subclass (it returns a white
    /// image), so it is replaced: the slide aspect-fit and centred on white, like PDFKit's thumbnails, rendered
    /// at 2 pixels per point into our own sRGB bitmap. Not a lazy `NSImage(size:flipped:drawingHandler:)`: its
    /// context has a non-identity base CTM, which doubles shadow offsets and shifts colours (decisions.md).
    /// A rotated page is drawn rotated (aspect-fit of the rotated slide). Empty or non-finite size → an empty image.
    public override func thumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage {
        let w = (size.width * 2).rounded(), h = (size.height * 2).rounded()
        let limit = CGFloat(SlideDeck.maxThumbnailPixel)
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= limit, h <= limit,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if rotation % 360 == 0 {
            deck.draw(slideIndex, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            // Fit the rotated box into the bitmap, then draw the slide through the page's rotation transform.
            let b = bounds(for: box), turn = transform(for: box)
            let r = b.applying(turn)
            let k = min(w / r.width, h / r.height)
            guard k.isFinite, k > 0 else { return NSImage(size: size) }
            ctx.translateBy(x: (w - r.width * k) / 2, y: (h - r.height * k) / 2)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            ctx.concatenate(turn)
            deck.draw(slideIndex, in: ctx, rect: b)
        }
        guard let image = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }

    /// The normalized slide text (`deck.slideText`); "" for an out-of-range index.
    public override var string: String? {
        deck.slideText(slideIndex)
    }

    /// PDFKit copies pages (e.g. when moving them between documents); the copy draws the same slide with the same
    /// rotation. (`label` is read-only, derived from the document; annotations are not copied.)
    public override func copy(with zone: NSZone? = nil) -> Any {
        let page = SlidePDFPage(deck: deck, index: slideIndex)
        page.rotation = rotation
        return page
    }
}
