// QuickLookSlideSource.swift — 1.3 Office Task 6: PowerPoint pages from macOS's own Quick Look preview.
import CoreGraphics
import Foundation
import IndexKit

/// Lays out a PowerPoint file as one page per visible slide: `QuickLookHTML` writes the HTML preview,
/// `PresentationSlides` gives the PowerPoint numbers of the visible slides, `SlideSnapshotter` renders each slide
/// (`SlideCache.maxLongSide` px long side) and reads its text and word rectangles. Page text is normalized like PDF text; word ranges are
/// mapped into it (words that vanish through normalization are dropped) and rectangles divided by the slide size.
/// The images go into `SlideCache` under the file's size and modification date, one by one right after each snapshot
/// (`SlideCacheWriter`), so memory does not grow with the slide count; the entry is published only after all slides
/// were rendered and their count matches the visible slides. On any error or cancellation the unfinished entry is
/// discarded (no partial or stale entry, no `.tmp` folder); an older complete entry of the same key stays.
///
/// Errors: a file that is no presentation package, a preview the generator cannot write or that took too long, and a
/// preview with another number of slides than the file's visible slides → `LayoutSourceError.unreadable`. A missing
/// Quick Look generator also counts as unreadable, with its own reason. `CancellationError` propagates; other I/O
/// errors (temporary folder, cache, a network block list that cannot be compiled) propagate unchanged, so the
/// `Indexer` retries next run. Every WebKit failure arrives as `SlideSnapshotterError` and is unreadable. The preview
/// never loads anything from the network (see `SnapshotWebView.networkBlockRules`). The temporary preview folder is removed on every exit.
/// There is no own time limit: the Indexer's per-file timeout and `QuickLookHTML`'s 60 s cover hangs.
public struct QuickLookSlideSource: PageLayoutSource {
    static let unreadableReason = "Vorschau nicht möglich"
    static let generatorMissingReason = "Office-Vorschau von macOS fehlt"
    static let maxPixel = SlideCache.maxLongSide

    private let cache: SlideCache
    private let generate: @Sendable (URL) async throws -> QuickLookOutput
    private let snapshotHook: SlideSnapshotter.Hook?

    public init(cache: SlideCache = .shared, html: QuickLookHTML = .init()) {
        self.init(cache: cache, generate: { try await html.generate(for: $0) })
    }

    /// For tests: another HTML generator (e.g. a fake preview) and a hook into the snapshot steps.
    init(cache: SlideCache, generate: @escaping @Sendable (URL) async throws -> QuickLookOutput,
         snapshotHook: SlideSnapshotter.Hook? = nil) {
        self.cache = cache
        self.generate = generate
        self.snapshotHook = snapshotHook
    }

    /// Cache key: the URL as given (standardized, like the index stores it) with size and date of the resolved file,
    /// as `Indexer` compares them, so readers that build the key from the index entry hit the same folder.
    static func cacheKey(for url: URL) throws -> SlideCacheKey {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SlideCacheKey(url: url, fileSize: Int64(values.fileSize ?? 0),
                             modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    public func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("quicklook", 1) }

    public func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let key = try Self.cacheKey(for: url)
        // Read and render the link target: `qlmanage` writes no preview for a symbolic link.
        let file = url.resolvingSymlinksInPath()
        let numbers: [Int]
        do { numbers = try PresentationSlides.visibleSlideNumbers(of: file) } catch LayoutSourceError.unreadable(_, let reason) {
            throw LayoutSourceError.unreadable(url, reason: reason) // report the URL the caller passed
        }
        try Task.checkCancellation()

        let output: QuickLookOutput
        do {
            output = try await generate(file)
        } catch QuickLookError.generatorMissing {
            throw LayoutSourceError.unreadable(url, reason: Self.generatorMissingReason)
        } catch is QuickLookError {
            throw LayoutSourceError.unreadable(url, reason: Self.unreadableReason)
        }
        defer { output.remove() }
        try Task.checkCancellation()

        let writer = try cache.beginEntry(for: key)
        defer { writer.discard() } // no effect after commit
        let slides: [SlideSnapshotter.Slide]
        do {
            slides = try await SlideSnapshotter(hook: snapshotHook).slides(
                fromHTML: output.html, readAccess: output.directory, maxPixel: Self.maxPixel, slideNumbers: numbers
            ) { _, image in
                #if DEBUG
                dispatchPrecondition(condition: .notOnQueue(.main)) // encoding must never block the main thread
                #endif
                try writer.append(image)
            }
        } catch is SlideSnapshotterError {
            throw LayoutSourceError.unreadable(url, reason: Self.unreadableReason)
        }
        try Task.checkCancellation()
        guard !slides.isEmpty, slides.count == numbers.count else {
            throw LayoutSourceError.unreadable(url, reason: Self.unreadableReason)
        }

        let pages = slides.map(Self.page)
        try writer.commit()
        return LayoutResult(pages: pages, renderer: "quicklook", layoutVersion: 1)
    }

    private static func page(_ slide: SlideSnapshotter.Slide) -> LaidOutPage {
        let mapped = TextNormalizer.normalizeMapped(slide.text)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var words: [OCRWord] = []
        words.reserveCapacity(slide.wordRects.count)
        for word in slide.wordRects {
            let range = mapped.normalizedRange(forOriginal: word.range)
            guard range.length > 0 else { continue }
            let box = CGRect(x: word.rect.minX / slide.size.width, y: word.rect.minY / slide.size.height,
                             width: word.rect.width / slide.size.width, height: word.rect.height / slide.size.height)
                .intersection(unit)
            guard !box.isNull, !box.isEmpty else { continue }
            words.append(OCRWord(range: range, box: box.standardized))
        }
        return LaidOutPage(text: mapped.text, words: words, size: slide.size)
    }
}
