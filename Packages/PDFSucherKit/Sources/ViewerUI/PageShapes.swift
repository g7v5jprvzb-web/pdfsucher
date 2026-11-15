// PageShapes.swift — 1.3.4: tiles follow the page shape (portrait or landscape)
import CoreGraphics
import Foundation
import IndexKit
import SearchKit

/// The page shape (height ÷ width of the first page) of each document in the grid, looked up once per file
/// off the main actor (`ThumbnailCache.pageAspect`). Not observed: a row asks for its shape in a task and
/// redraws itself, so a resolved shape does not redraw every other row.
@MainActor final class PageShapes {
    /// A 16:9 slide: PowerPoint rows start in this shape until the deck is laid out.
    static let slideGuess: CGFloat = 9.0 / 16.0

    private struct Entry {
        let aspect: CGFloat?
        /// Layout revision of the lookup (Word/PowerPoint); an unknown shape is asked again at a newer one.
        let revision: Int
    }
    private var entries: [URL: Entry] = [:]
    private var pending: [URL: Task<CGFloat?, Never>] = [:]

    init() {}

    /// The shape used for drawing now: the known one, else a guess by kind (nil = A4 portrait).
    func aspect(for hit: DocumentHit) -> CGFloat? {
        entries[hit.url]?.aspect ?? Self.guess(hit.kind)
    }

    static func guess(_ kind: DocumentKind) -> CGFloat? { kind == .powerpoint ? slideGuess : nil }

    /// The lookup finished for this file (with or without a shape) at `revision` or later; until then a row
    /// holds back its tiles, so they are not rendered at the wrong size first.
    func isResolved(_ url: URL, revision: Int) -> Bool {
        guard let entry = entries[url] else { return false }
        return entry.aspect != nil || entry.revision >= revision
    }

    /// Looks the shape up once (concurrent callers share the lookup); returns the shape to draw with.
    @discardableResult
    func resolve(_ hit: DocumentHit, revision: Int, cache: ThumbnailCache) async -> CGFloat? {
        let url = hit.url
        if isResolved(url, revision: revision) { return aspect(for: hit) }
        let task: Task<CGFloat?, Never>
        if let running = pending[url] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) { cache.pageAspect(of: url) }
            pending[url] = task
        }
        let value = await task.value
        if pending[url] == task { pending[url] = nil }
        let previous = entries[url]
        entries[url] = Entry(aspect: value ?? previous?.aspect, revision: max(revision, previous?.revision ?? 0))
        return aspect(for: hit)
    }

    /// Starts the lookup without waiting (prefetch of rows not on screen yet).
    func request(_ hit: DocumentHit, revision: Int, cache: ThumbnailCache) {
        guard !isResolved(hit.url, revision: revision), pending[hit.url] == nil else { return }
        Task { await resolve(hit, revision: revision, cache: cache) }
    }

    /// Tile size of a row: the shape fitted into the A4 tile `base` (`GridLayout.tileSize(base:pageAspect:)`).
    func tileSize(for hit: DocumentHit, base: CGSize) -> CGSize {
        GridLayout.tileSize(base: base, pageAspect: aspect(for: hit))
    }
}
