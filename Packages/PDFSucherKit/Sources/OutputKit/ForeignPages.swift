// ForeignPages.swift — 1.3 Office Task 8
import Foundation
import IndexKit
import PDFKit

/// Pages of files that are neither PDF nor image (Word, PowerPoint), supplied from outside OutputKit
/// (`OfficeKit.OfficePages`), so OutputKit itself stays free of Office code.
public protocol ForeignPageProvider: Sendable {
    /// Whether this provider is responsible for `url` (by extension). `Merger` asks it before anything else.
    func handles(_ url: URL) -> Bool
    /// Pages the file has for output right now; nil = cannot be read (or not laid out yet).
    func pageCount(of url: URL) -> Int?
    /// One page of a merged or printed document. Called only for a page index below `pageCount(of:)`; the page must
    /// stay valid after any document it came from is gone. Errors other than `OutputError` count as `cannotOpen`.
    func makePage(_ ref: PageRef) throws -> PDFPage
    /// A one-page document of the page for display (1.3 Teil B, thumbnails and preview in PDFKit views); nil = no
    /// such page (not readable, not laid out, out of range). `maxPixel` is a hint: a provider may draw a raster page
    /// from a smaller image (its long side at most `maxPixel` pixels); nil = full quality, as in output.
    func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument?
    /// Identifies what `pageDocument` currently draws for the file beyond its date and size (renderer and version,
    /// whether a layout is cached), so cached tiles of an older layout are not shown (1.3 Teil B). "" = unknown.
    /// May touch the disk; called off the main actor.
    func contentVersion(_ url: URL) -> String
    /// A page drawn straight into a tile's bitmap, without a PDF page in between (office-speed: Word); nil = no such
    /// fast path, tiles use `pageDocument`. Output, printing and the large preview keep `makePage`/`pageDocument`.
    func tile(_ ref: PageRef) -> ForeignTile?
}

/// A page for a tile, drawn directly. Calls may block (the provider's locks); called off the main actor.
public struct ForeignTile: Sendable {
    /// Page size in points.
    public let size: CGSize
    /// Draws the page into a context whose user space has its origin bottom left and measures the page in points; no
    /// background.
    public let draw: @Sendable (CGContext) -> Void
    /// The page text and its word boxes (0…1, origin top left), for marks; asked only when a tile is marked.
    public let text: @Sendable () -> (text: String, words: [OCRWord])

    public init(size: CGSize, draw: @escaping @Sendable (CGContext) -> Void,
                text: @escaping @Sendable () -> (text: String, words: [OCRWord])) {
        self.size = size
        self.draw = draw
        self.text = text
    }
}

extension ForeignPageProvider {
    /// Default: "" (the file's date and size alone identify its pages).
    public func contentVersion(_ url: URL) -> String { "" }

    /// Default: no direct tile.
    public func tile(_ ref: PageRef) -> ForeignTile? { nil }

    /// Default: the output page (`makePage`) in a new document; ignores `maxPixel`.
    public func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
        guard ref.pageIndex >= 0, let page = try? makePage(ref) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }
}
