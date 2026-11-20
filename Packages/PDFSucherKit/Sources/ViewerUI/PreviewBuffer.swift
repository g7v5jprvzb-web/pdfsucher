// PreviewBuffer.swift — 1.3.4 Vorschau-Puffer
import Foundation
import ImageIO
import Observation
import OutputKit
import PDFKit
import SearchKit

/// The large preview's prepared pages (spec 1.3.4): the focused page and its two neighbours (`PreviewNeighbors`),
/// each opened (`DetailDocument`) and drawn ahead as a picture in the size the PDFView will show it, with marks.
/// At most these three; everything else is dropped and its work cancelled. Pictures are drawn by the tile cache's
/// render threads (the focused page at `.visible`, neighbours at `.preview`) and kept only here.
/// Word/PowerPoint pages are not prepared (their stand-in is the tile).
@MainActor @Observable final class PreviewBuffer {
    /// The marks a picture shows; two marks are equal when key, colour and „marked at all“ are.
    struct Marks: Equatable {
        let highlightKey: String
        let ranges: HighlightRanges?
        let color: RGBA

        static func == (a: Marks, b: Marks) -> Bool {
            a.highlightKey == b.highlightKey && a.color.key == b.color.key && (a.ranges == nil) == (b.ranges == nil)
        }
    }

    /// What the picture's size depends on: zoom and the preview's size.
    struct Layout: Equatable {
        let mode: PreviewZoom.Mode
        let fractions: [Int]
        let reference: CGFloat?
        let beyondWidth: Bool
        let viewSize: CGSize
    }

    /// Identifies a picture: marks and its size in points (rounded to 2 pt).
    private struct PictureID: Equatable {
        let marks: Marks
        let width: Int, height: Int
    }

    /// What a preparation draws for: a running one with the same target is not started again.
    private struct Target: Equatable {
        let marks: Marks
        let layout: Layout
    }

    private struct Entry {
        var document: DetailDocument?
        var pageSize: CGSize?
        var image: CGImage?
        var picture: PictureID?
        var slow = false
        var task: Task<Void, Never>?
        /// The running preparation's target; nil when none runs.
        var running: Target?
    }

    /// Drawing a page took longer than this: PDFKit is slow on it too (the PDFView gets it later, spec 1.3.4).
    static let slowMillis = 120.0

    @ObservationIgnored private var cache: ThumbnailCache
    @ObservationIgnored private var foreign: (any ForeignPageProvider)?
    private var entries: [PageRef: Entry] = [:]
    /// Files being opened: pages of one file prepared at the same time share the document.
    @ObservationIgnored private var opening: [URL: Task<LoadBox, Never>] = [:]

    init(cache: ThumbnailCache, foreign: (any ForeignPageProvider)? = nil) {
        self.cache = cache
        self.foreign = foreign
    }

    /// Another tile cache (another PowerPoint renderer, 1.3 Teil B): pictures of the old one are dropped.
    func use(_ cache: ThumbnailCache, foreign: (any ForeignPageProvider)?) {
        guard cache !== self.cache else { return }
        for entry in entries.values { entry.task?.cancel() }
        entries = [:]
        self.cache = cache
        self.foreign = foreign
    }

    var count: Int { entries.count }
    /// Preparations started so far (tests).
    @ObservationIgnored private(set) var preparationsStarted = 0
    var refs: [PageRef] { Array(entries.keys) }

    /// `ref` is focused now (coming from `old`): keeps it and its neighbours, drops the rest and prepares what is
    /// missing or out of date (other marks or size).
    func focus(_ ref: PageRef, from old: PageRef?, hits: [DocumentHit], showAllPages: Bool, marks: Marks, layout: Layout,
               ocr: @escaping @MainActor (PageRef) async -> OCRPageText?) {
        let wanted = [ref] + PreviewNeighbors.pages(from: old, to: ref, hits: hits, showAllPages: showAllPages)
        for (key, entry) in entries where !wanted.contains(key) {
            entry.task?.cancel()
            entries.removeValue(forKey: key)
        }
        for (position, page) in wanted.enumerated() {
            guard foreign?.handles(page.url) != true else { continue }
            var entry = entries[page] ?? Entry()
            let target = Target(marks: marks, layout: layout)
            if let size = entry.pageSize, entry.image != nil, entry.picture == Self.picture(marks, layout, size) { continue }
            if entry.running == target { continue }      // already being drawn for this (held key: not restarted)
            entry.task?.cancel()
            entry.running = target
            preparationsStarted += 1
            entry.task = Task { [weak self] in
                await self?.prepare(page, marks: marks, layout: layout, ocr: ocr, priority: position == 0 ? .visible : .preview)
                self?.finished(page, target: target)
            }
            entries[page] = entry
        }
    }

    private func prepare(_ ref: PageRef, marks: Marks, layout: Layout, ocr: @MainActor (PageRef) async -> OCRPageText?,
                         priority: TileRenderQueue.Priority) async {
        let document: DetailDocument?
        let pageSize: CGSize
        if ImagePages.isImage(ref.url) {
            // No document for an image: the detail view decodes only the focused one (4,000 px, 48 MB for 12 MP).
            let url = ref.url
            guard let size = await Task.detached(operation: { Self.imagePageSize(url) }).value,
                  !Task.isCancelled, entries[ref] != nil else { return }
            document = nil
            pageSize = size
        } else {
            // One document per file: pages of the file shown or prepared already share it.
            let known = entries[ref]?.document ?? entries.values.lazy.compactMap(\.document).first { $0.url == ref.url && $0.singlePage == nil }
            guard case .ready(let loaded) = await open(ref, reusing: known),
                  !Task.isCancelled, entries[ref] != nil,
                  let page = loaded.pdf.page(at: loaded.documentPageIndex(for: ref)) else { return }
            document = loaded
            pageSize = PreviewGeometry.pageSize(page)
        }
        entries[ref]?.document = document
        entries[ref]?.pageSize = pageSize
        let scale = PreviewGeometry.scale(mode: layout.mode, fractions: layout.fractions, reference: layout.reference,
                                          beyondWidth: layout.beyondWidth, page: pageSize, view: layout.viewSize)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        let text = marks.ranges == nil ? nil : await ocr(ref)
        guard !Task.isCancelled else { return }
        let render = await cache.previewImage(for: ref, size: size, highlightKey: marks.highlightKey, highlightRanges: marks.ranges,
                                              highlightColor: marks.color, ocr: text, priority: priority)
        guard let render, !Task.isCancelled, entries[ref]?.document?.pdf === document?.pdf else { return }
        entries[ref]?.image = render.image
        entries[ref]?.picture = Self.picture(marks, layout, pageSize)
        entries[ref]?.slow = render.millis > Self.slowMillis
    }

    private func open(_ ref: PageRef, reusing known: DetailDocument?) async -> DetailLoad {
        if let running = opening[ref.url] {
            let load = await running.value.load
            // 1.4.4: a slow PDF opens as a one-page document of the page asked for; another page opens on its own.
            guard case .ready(let document) = load, let single = document.singlePage, single != ref.pageIndex else { return load }
        }
        let task = Task { LoadBox(load: await DetailDocument.load(ref, reusing: known)) }
        opening[ref.url] = task
        let result = await task.value
        if opening[ref.url] == task { opening[ref.url] = nil }
        return result.load
    }

    private func finished(_ ref: PageRef, target: Target) {
        if entries[ref]?.running == target { entries[ref]?.running = nil }
    }

    /// An image file's page as `ImageDocument` builds it (at most 4,000 px, EXIF orientation applied), from its header.
    nonisolated static func imagePageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let fit = min(1, 4_000 / max(width, height))
        let size = CGSize(width: (width * fit).rounded(), height: (height * fit).rounded())
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    private static func picture(_ marks: Marks, _ layout: Layout, _ pageSize: CGSize) -> PictureID {
        let scale = PreviewGeometry.scale(mode: layout.mode, fractions: layout.fractions, reference: layout.reference,
                                          beyondWidth: layout.beyondWidth, page: pageSize, view: layout.viewSize)
        return PictureID(marks: marks, width: Int((pageSize.width * scale / 2).rounded()), height: Int((pageSize.height * scale / 2).rounded()))
    }

    /// The prepared picture of `ref` if it shows these marks at this layout's size.
    func image(for ref: PageRef, marks: Marks, layout: Layout) -> CGImage? {
        guard let entry = entries[ref], let image = entry.image, let size = entry.pageSize,
              entry.picture == Self.picture(marks, layout, size) else { return nil }
        return image
    }

    func document(for ref: PageRef) -> DetailDocument? { entries[ref]?.document }
    func pageSize(for ref: PageRef) -> CGSize? { entries[ref]?.pageSize }
    /// Drawing `ref`'s picture was slow.
    func isSlow(_ ref: PageRef) -> Bool { entries[ref]?.slow ?? false }

    /// The preview loaded `document` for `ref` (it checked the file): a picture drawn from another version of the file
    /// is dropped. The same version opened twice (the preview pages on in the file it shows) keeps it.
    func documentLoaded(_ document: DetailDocument, for ref: PageRef) {
        guard let entry = entries[ref], let prepared = entry.document, prepared.pdf !== document.pdf,
              prepared.url != document.url || prepared.modifiedAt != document.modifiedAt else { return }
        entry.task?.cancel()
        entries[ref] = Entry(document: document, pageSize: entry.pageSize)
    }

    /// Waits for the running preparations (tests).
    func waitUntilIdle() async {
        while let task = entries.values.first(where: { $0.running != nil })?.task {
            await task.value
        }
    }
}

/// A load handed between tasks of the main actor (the document is only used there).
private struct LoadBox: @unchecked Sendable { let load: DetailLoad }
