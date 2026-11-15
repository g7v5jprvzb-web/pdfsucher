// ThumbnailCache+Foreign.swift — 1.3 Teil B Task 13: Word/PowerPoint tiles through the `ForeignPageProvider`.
// Kept apart from ThumbnailCache.swift, which only calls these helpers, so merges of the tile cache stay simple.
import Foundation
import OutputKit
import PDFKit

extension ThumbnailCache {
    /// Marks a key's `ocrVersion` slot as an Office tile's: `"ofc:" + contentVersion + "|" + ocrVersion`.
    static let foreignVersionPrefix = "ofc:"

    static func isForeignVersion(_ version: String) -> Bool { version.hasPrefix(foreignVersionPrefix) }

    /// The `ocrVersion` slot of a tile key: unchanged for PDFs and images; for a file the provider handles, the
    /// provider's content version is folded in always (also without marks), so a relayout without a file change
    /// (renderer upgrade, slide cache rebuilt) gets new tiles in memory and on disk. Remembers the content version
    /// for `cachedImage`. Calls the provider: not on the main actor.
    func foreignVersion(_ url: URL, ocrVersion: String) -> String {
        guard let foreign, foreign.handles(url) else { return ocrVersion }
        let content = foreign.contentVersion(url)
        foreignVersions.withLock { $0[url] = content }
        return Self.foreignVersionPrefix + content + "|" + ocrVersion
    }

    /// Like `foreignVersion`, from the content version last seen (`cachedImage` runs on the main actor and asks no
    /// provider); unchanged for files without one.
    func knownForeignVersion(_ url: URL, ocrVersion: String) -> String {
        guard let content = foreignVersions.withLock({ $0[url] }) else { return ocrVersion }
        return Self.foreignVersionPrefix + content + "|" + ocrVersion
    }

    /// Drops the remembered content version of a file that is gone (with its tiles, `forget`).
    func forgetForeignVersion(_ url: URL) {
        foreignVersions.withLock { _ = $0.removeValue(forKey: url) }
    }

    /// Pixel hint for the provider, as for images: the tile's long side at `scale`, at most `maxRenderPixelSide`.
    static func foreignMaxPixel(_ size: CGSize, scale: CGFloat) -> Int {
        min(Int((max(size.width, size.height) * scale).rounded(.up)), Int(maxRenderPixelSide))
    }

    /// A one-page document of page `page` of a Word/PowerPoint file (its page index is 0); nil when the provider
    /// has no such page (not laid out yet, unreadable, out of range). Runs on a render thread.
    func foreignDocument(for url: URL, page: Int, maxPixel: Int) -> PDFDocument? {
        guard let foreign, page >= 0, let document = foreign.pageDocument(PageRef(url: url, pageIndex: page), maxPixel: maxPixel),
              document.pageCount > 0 else { return nil }
        return document
    }
}
