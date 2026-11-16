// SlideDeck.swift — Tasks 8, 9, 10, 11, 12a (SlideKit)
// Public entry point: an opened .pptx/.pptm. Immutable, safe to read from several threads.
import CoreGraphics
import Foundation
import IndexKit
import OOXMLKit

public enum SlideKitError: Error, Equatable {
    case notAZip
    case encrypted
    case malformed(String)
    case unsupportedFormat
}

/// A slide reference: its part in the package and the number PowerPoint shows for it.
struct SlideRef: Sendable, Equatable {
    let partPath: String
    let powerPointNumber: Int
}

/// An opened .pptx/.pptm. Immutable and Sendable: any number of threads may draw from one deck (or its copies)
/// at once. Opening reads only the zip directory and presentation.xml; slides, layouts, masters and themes are
/// parsed on first use and cached in a store shared by all copies of the deck.
///
/// Drawing: `draw(_:in:rect:)` takes a standard Core Graphics context (y up, as a bitmap context or a PDF
/// page) and a `rect` in its user space. The slide (`slideSize` points, origin top left) is scaled uniformly to
/// fit `rect` and centred in it; outside the slide nothing is touched (it is clipped to the slide area). The
/// graphics state is saved and restored; the text matrix is not part of it and may change.
public struct SlideDeck: Sendable {
    let package: OPCPackage
    let store: DeckStore
    /// Visible slides only, in presentation.xml order; index i = the i-th visible slide.
    let slides: [SlideRef]
    private let size: CGSize
    /// False: fonts resolve without waiting for Office's registration (`FontResolver.withoutWaitingForRegistration`).
    let waitsForFonts: Bool

    /// Throws `SlideKitError` (.notAZip, .encrypted, .malformed, .unsupportedFormat).
    /// Reads only the zip directory, presentation.xml and the slide roots' `show` attribute.
    ///
    /// `fontSubstitution` decides how fonts that are not installed are drawn: `.powerPoint` (default) like
    /// PowerPoint for Mac, `.similar` the closest-looking macOS font. Meant for an app setting
    /// (`OfficeRenderSettings.fontSubstitutionKey`). Text layout, rendering and `wordBoxes` depend on it, so
    /// callers must re-render and re-index a deck when the setting changes. Each deck has its own caches.
    ///
    /// `waitsForFonts` false (office-speed, display decks): drawing and text never wait for Office's font
    /// registration; until it is done they use substitutes, so open such a deck again once `officeFontsReady`.
    public init(url: URL, fontSubstitution: FontSubstitution = .powerPoint, waitsForFonts: Bool = true) throws {
        self.waitsForFonts = waitsForFonts
        let parsed = try DeckParser.open(url: url)
        package = parsed.package
        slides = parsed.slides
        size = parsed.slideSize
        store = DeckStore(package: parsed.package, presentationPart: parsed.presentationPart,
                          fontSubstitution: fontSubstitution)
    }

    /// Prepares fonts for SlideKit at app start: registers Office's own fonts and lists the installed families
    /// (`FontResolver.prewarm()`; a macOS access prompt for Office's font cache appears then, not at the first
    /// deck). Blocking; call once off the main thread and off Swift's concurrency pool, e.g.
    /// `DispatchQueue.global(qos: .utility).async { SlideDeck.prewarmFonts() }`. Idempotent and thread-safe;
    /// without it the same happens on the first font resolution.
    public static func prewarmFonts() {
        FontResolver.prewarm()
    }

    /// Whether Office's font registration is done in this process (decks opened now draw with Office's fonts and
    /// never wait). Does not wait.
    public static var officeFontsReady: Bool { FontResolver.officeFontsReady }

    /// `body`, without waiting for Office's fonts unless this deck `waitsForFonts`.
    private func fonts<T>(_ body: () -> T) -> T {
        waitsForFonts ? body() : FontResolver.withoutWaitingForRegistration(body)
    }

    /// Thumbnails never exceed this many pixels on the long side (larger `maxPixel` values are clamped).
    static let maxThumbnailPixel = 16384

    /// The font substitution this deck was opened with.
    public var fontSubstitution: FontSubstitution { store.fonts.substitution }

    /// Number of visible slides.
    public var slideCount: Int { slides.count }

    /// Slide size in points.
    public var slideSize: CGSize { size }

    /// Bytes of decoded images this deck (and its copies) keeps now, at most `ImageDecoder.maxCacheBytes`; the bulk
    /// of an open deck's memory once drawn. For caches that bound open decks by memory.
    public var cachedImageBytes: Int { store.images.cachedBytes }

    /// Normalized slide text (IndexKit.TextNormalizer) of the slide's own shapes in z-order (groups depth-first,
    /// tables row by row); master and layout text, hidden shapes and bullets are not included. Cached per slide.
    /// Out-of-range index → "".
    public func slideText(_ i: Int) -> String {
        fonts { slide(i).map { store.slideText($0, slideSize: size).text } ?? "" }
    }

    /// Word ranges in `slideText(i)` with boxes normalized to 0…1, origin top left (rotated text: the axis-aligned
    /// bounding box; clamped to the slide, words entirely off the slide are left out). A word broken across
    /// lines gives one entry per line; table cells included. Out of range → [].
    public func wordBoxes(_ i: Int) -> [OCRWord] {
        fonts { slide(i).map { store.slideText($0, slideSize: size).words } ?? [] }
    }

    /// Draws slide i into `rect` (user space of a y-up context): uniform aspect-fit scaling, centred, clipped
    /// to the slide. Out-of-range index or an empty/non-finite rect → nothing drawn.
    public func draw(_ i: Int, in ctx: CGContext, rect: CGRect) {
        guard let w = fitted(size, into: rect) else { return }
        render(i, in: ctx, rect: w)
    }

    /// Slide i as an sRGB bitmap with premultiplied alpha whose long side is `maxPixel` (16:9 at 256 →
    /// 256×144; clamped to 16384), background included. Out-of-range index or `maxPixel` ≤ 0 → nil.
    public func thumbnail(_ i: Int, maxPixel: Int) -> CGImage? {
        guard slide(i) != nil, let (w, h) = Self.thumbnailSize(size, maxPixel: maxPixel) else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // The whole bitmap: the aspect ratio differs from the slide's by less than a pixel after rounding.
        render(i, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Pixel size of a thumbnail of a slide of `size` points: long side min(maxPixel, 16384), short side scaled
    /// and clamped to 1…long. nil for maxPixel ≤ 0 or a non-positive or non-finite slide size. The ratio is taken
    /// first: `long · a` alone overflows to infinity for sizes near CGFloat's maximum.
    static func thumbnailSize(_ size: CGSize, maxPixel: Int) -> (Int, Int)? {
        guard maxPixel > 0, size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let long = min(maxPixel, maxThumbnailPixel)
        let short = { (a: CGFloat, b: CGFloat) -> Int in
            let v = ((a / b) * CGFloat(long)).rounded()
            return v.isFinite ? Int(min(max(v, 1), CGFloat(long))) : 1
        }
        return size.width >= size.height ? (long, short(size.height, size.width)) : (short(size.width, size.height), long)
    }

    /// The aspect-fit, centred rect of `size` in `rect`; nil if either is empty or not finite.
    func fitted(_ size: CGSize, into rect: CGRect) -> CGRect? {
        let vals = [rect.minX, rect.minY, rect.width, rect.height, size.width, size.height]
        guard vals.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return nil }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Maps the slide onto `rect` (may stretch slightly; callers pass a fitted rect), flips to y down, clips.
    func render(_ i: Int, in ctx: CGContext, rect: CGRect) {
        guard let ref = slide(i), size.width > 0, size.height > 0 else { return }
        fonts { render(ref, in: ctx, rect: rect) }
    }

    private func render(_ ref: SlideRef, in ctx: CGContext, rect: CGRect) {
        let model = store.slideModel(ref.partPath)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
        ctx.clip(to: CGRect(origin: .zero, size: size))
        SlideRenderer.draw(model, text: store.textLayout(ref), size: size, in: ctx, renderer: store.renderer,
                           fonts: store.fonts)
        ctx.restoreGState()
    }

    func slide(_ i: Int) -> SlideRef? {
        slides.indices.contains(i) ? slides[i] : nil
    }
}
