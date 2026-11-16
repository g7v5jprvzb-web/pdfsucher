// SlideKitPages.swift — SlideKit adapter for the Office integration: PowerPoint pages for viewer, tiles and output.
import CoreGraphics
import Foundation
import IndexKit
import OutputKit
import PDFKit
import SlideKit

/// PowerPoint pages drawn live by SlideKit, as the `ForeignPageProvider` of `Merger`, `Printer`, the viewer and
/// the tile cache. Unlike `OfficePages` a deck needs no layout run first: pages exist as soon as the file is
/// readable. Every page is a `SlidePDFPage` (vector; saved or printed it becomes ordinary PDF content with real
/// text), so `maxPixel` hints are not needed and ignored.
///
/// Tile hook: `ThumbnailCache` renders foreign tiles through `pageDocument(_:maxPixel:)` and folds
/// `contentVersion(_:)` into the tile key (ThumbnailCache+Foreign). The content version is
/// `"slidekit:<layout version>:r<renderVersion>"` (layout version from `SlideKitLayoutSource`, same
/// `FontSubstitution`; a trailing `~` while Office's fonts are not registered yet), so switching the setting shows new tiles in memory and on disk without a file change, and
/// a SlideKit drawing fix that leaves text alone bumps only `renderVersion` (new tiles, no new layout).
///
/// When the font setting changes, build the provider (and the `ThumbnailCache` holding it) and the Indexer's
/// `SlideKitLayoutSource` again from the same value, and call `SlideDeckCache.shared.removeAll()`.
///
/// Files that are not PowerPoint (Word, …) go to `fallback` (e.g. `OfficePages`), if given; without one this
/// provider does not handle them. Pass the app's font setting; there is no default here. Safe from any thread.
public struct SlideKitPages: ForeignPageProvider {
    /// Bump when SlideKit draws slides differently (tiles on disk are redrawn; the index is not touched).
    public static let renderVersion = 1

    public let fontSubstitution: FontSubstitution
    private let decks: SlideDeckCache
    private let fallback: (any ForeignPageProvider)?

    public init(fontSubstitution: FontSubstitution, decks: SlideDeckCache = .shared,
                fallback: (any ForeignPageProvider)? = nil) {
        self.fontSubstitution = fontSubstitution
        self.decks = decks
        self.fallback = fallback
    }

    static func isPowerPoint(_ url: URL) -> Bool { DocumentKind(fileExtension: url.pathExtension) == .powerpoint }

    private func deck(_ url: URL) -> SlideDeck? {
        try? decks.deck(for: url, fontSubstitution: fontSubstitution)
    }

    public func handles(_ url: URL) -> Bool {
        Self.isPowerPoint(url) || fallback?.handles(url) == true
    }

    /// Visible slides; nil for an unreadable deck.
    public func pageCount(of url: URL) -> Int? {
        guard Self.isPowerPoint(url) else { return fallback?.pageCount(of: url) }
        return deck(url)?.slideCount
    }

    /// A `SlidePDFPage` of slide `pageIndex` for output (merge, print): waits for Office's font registration (and
    /// starts it, as before office-speed), so saved pages never carry substitute fonts. Throws
    /// `OutputError.cannotOpen` for an unreadable deck (or a file no provider handles) and `pageOutOfRange` for a
    /// slide it does not have.
    public func makePage(_ ref: PageRef) throws -> PDFPage {
        guard Self.isPowerPoint(ref.url) else {
            guard let fallback, fallback.handles(ref.url) else { throw OutputError.cannotOpen(ref.url) }
            return try fallback.makePage(ref)
        }
        if !SlideDeck.officeFontsReady { SlideDeck.prewarmFonts() }
        return try displayPage(ref)
    }

    /// A `SlidePDFPage` for display (tiles, the large preview): never waits for Office's fonts. Until they are
    /// registered the deck draws with substitutes and `contentVersion` says so, so it is drawn again after.
    private func displayPage(_ ref: PageRef) throws -> PDFPage {
        guard let deck = deck(ref.url) else { throw OutputError.cannotOpen(ref.url) }
        guard ref.pageIndex >= 0, ref.pageIndex < deck.slideCount else { throw OutputError.pageOutOfRange(ref) }
        return SlidePDFPage(deck: deck, index: ref.pageIndex)
    }

    /// A one-page document holding the `SlidePDFPage` (vector at any size, `maxPixel` ignored); nil when there is
    /// no such slide.
    public func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
        guard Self.isPowerPoint(ref.url) else { return fallback?.pageDocument(ref, maxPixel: maxPixel) }
        guard let page = try? displayPage(ref) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    /// `"slidekit:<layout version>:r<renderVersion>"` for PowerPoint (depends on the font setting), the fallback's
    /// for other files.
    public func contentVersion(_ url: URL) -> String {
        guard Self.isPowerPoint(url) else { return fallback?.contentVersion(url) ?? "" }
        let layout = SlideKitLayoutSource.layoutVersion(for: fontSubstitution)
        // „~“ while Office's fonts are not registered (substitutes): such tiles are not reused after it.
        return "\(SlideKitLayoutSource.rendererName):\(layout):r\(Self.renderVersion)" + (SlideDeck.officeFontsReady ? "" : "~")
    }

    /// Slide `pageIndex` as an image, long side `maxPixel` (`SlideDeck.thumbnail`, background included). Nil for an
    /// unreadable deck, a slide it does not have or another file type.
    public func thumbnail(_ ref: PageRef, maxPixel: Int) -> CGImage? {
        guard Self.isPowerPoint(ref.url), let deck = deck(ref.url) else { return nil }
        return deck.thumbnail(ref.pageIndex, maxPixel: maxPixel)
    }

    /// The fallback's direct tile for other files (Word); none for slides (drawn through `SlidePDFPage`, which costs
    /// nothing measurable beside a direct bitmap).
    public func tile(_ ref: PageRef) -> ForeignTile? {
        Self.isPowerPoint(ref.url) ? nil : fallback?.tile(ref)
    }

    /// The page for the large preview, the same as in output (`makePage`); nil when there is none.
    public func previewPage(_ ref: PageRef) -> PDFPage? {
        Self.isPowerPoint(ref.url) ? try? displayPage(ref) : try? makePage(ref)
    }
}
