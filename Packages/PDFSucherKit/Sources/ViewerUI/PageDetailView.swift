// PageDetailView.swift — Task 4.3
import AppKit
import IndexKit
import OutputKit
import PDFKit
import SearchKit
import SwiftUI

/// The focused page, large, with matches highlighted; ‹ › step through all hit pages in grid order.
struct PageDetailView: View {
    let model: any ViewerModel
    let cache: ThumbnailCache
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    /// Prepared pages and what the PDFView shows (1.3.4 Vorschau-Puffer).
    @State private var buffer: PreviewBuffer
    @State private var stage = PreviewStage()
    @State private var previousRef: PageRef?
    /// The page the buffer last prepared for: other marks, zoom or size for it wait for a rest (live resize).
    @State private var preparedFor: PageRef?
    @State private var viewSize: CGSize = .zero
    @State private var load: DetailLoad?
    /// The file `load` belongs to (keeps „Vorschau wird vorbereitet …“ while paging within it).
    @State private var loadedURL: URL?
    /// Bumped when a Word/PowerPoint page still being prepared should be tried again (layout progress).
    @State private var retry = 0
    /// The task whose load is running (nil = none); layout progress does not restart it.
    @State private var loadingKey: DetailTaskKey?
    /// Recognized text of the focused page (spec 1.2 §5); nil for pages with a text layer.
    @State private var ocr: DetailOCR?
    /// 1.5.0: the page asked for and since when, until its first sharp draw (`preview_visible` in the measurement log).
    @State private var visibleClock: (ref: PageRef, since: ContinuousClock.Instant)?

    init(model: any ViewerModel, cache: ThumbnailCache, highlightKey: String, highlightRanges: HighlightRanges?) {
        self.model = model
        self.cache = cache
        self.highlightKey = highlightKey
        self.highlightRanges = highlightRanges
        _buffer = State(initialValue: PreviewBuffer(cache: cache, foreign: model.foreignPages))
    }

    private var marks: PreviewBuffer.Marks {
        PreviewBuffer.Marks(highlightKey: highlightKey, ranges: highlightRanges, color: model.settings.highlightColor)
    }

    private var layout: PreviewBuffer.Layout {
        PreviewBuffer.Layout(mode: model.previewZoom.mode, fractions: model.settings.zoomLevelFractions,
                             reference: model.previewZoom.referenceWidth, beyondWidth: model.settings.previewZoomBeyondWidth,
                             viewSize: viewSize)
    }

    private func standIn(_ ref: PageRef) -> some View {
        PreviewStandIn(ref: ref, buffer: buffer, cache: cache, marks: marks, layout: layout)
    }

    var body: some View {
        let ref = model.focusedPage
        ZStack {
            if let ref {
                switch load {
                case nil:
                    standIn(ref)      // never a spinner while paging (1.3.4)
                case .missing:
                    ContentUnavailableView(ViewerText.tilePlaceholder(fileExists: false, folderUnreachable: model.indexStatus == .unreachable),
                                           systemImage: "doc.questionmark")
                case .unavailable:
                    ContentUnavailableView(ViewerText.previewUnavailable, systemImage: "exclamationmark.triangle")
                case .preparing:
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(ViewerText.previewPreparing).foregroundStyle(.secondary)
                    }
                case .ready:
                    // The PDFView stays and shows `stage.shown`; until it has drawn the focused page sharply the
                    // stand-in covers it (1.3.4).
                    if let shown = stage.shown {
                        let pdf = shown.document.pdf
                        PDFPageView(document: pdf, pageIndex: shown.document.documentPageIndex(for: shown.ref),
                                    highlightKey: highlightKey, highlightRanges: highlightRanges,
                                    zoom: model.previewZoom, fractions: model.settings.zoomLevelFractions,
                                    beyondWidth: model.settings.previewZoomBeyondWidth,
                                    color: model.settings.highlightColor, ocr: shown.ocr?.ref == shown.ref ? shown.ocr : nil,
                                    tracker: shown.document.tracker,
                                    onDraw: { pageIndex, sharp in
                                        PreviewTiming.event("draw", shown.ref)
                                        if sharp {
                                            PreviewTiming.event("sharp", shown.ref)
                                            if let clock = visibleClock, clock.ref == shown.ref {
                                                visibleClock = nil
                                                IndexMetrics.shared.log("preview_visible", [
                                                    "file": IndexMetrics.hash(shown.ref.url), "ext": shown.ref.url.pathExtension.lowercased(),
                                                    "page": shown.ref.pageIndex, "ms": IndexMetrics.ms(since: clock.since)])
                                            }
                                            stage.drewSharp(pageIndex: pageIndex, document: pdf)
                                        }
                                    })
                    }
                    if stage.needsStandIn(for: ref) { standIn(ref) }
                }
            } else {
                ContentUnavailableView("Keine Seite gewählt", systemImage: "doc.text.magnifyingglass",
                                       description: Text(ViewerText.noFocusedPage))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .onChange(of: ref) { old, new in
            previousRef = old
            stage.focusMoved(to: new)
        }
        // Prepares the focused page and its neighbours; again for other marks, zoom or size (1.3.4).
        .task(id: BufferKey(ref: ref, marks: marks, layout: layout)) {
            guard let ref, viewSize.width >= 1, viewSize.height >= 1 else { return }
            if preparedFor == ref {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            preparedFor = ref
            buffer.use(cache, foreign: model.foreignPages)
            buffer.focus(ref, from: previousRef, hits: model.hits, showAllPages: model.settings.showAllPages,
                         marks: marks, layout: layout, ocr: { [model] in await model.ocrText(for: $0) })
        }
        .overlay(alignment: .bottom) { if ref != nil { navigation(ref) } }
        .overlay(alignment: .topTrailing) { if ref != nil { ZoomBar(zoom: model.previewZoom).padding(8) } }
        // Another PowerPoint renderer: a shown Word/PowerPoint page is drawn again by the new provider (not reused).
        .onChange(of: model.foreignPagesRevision) {
            if isForeign(ref) { load = nil; stage.cleared(); retry += 1 }
        }
        .onChange(of: model.layoutRevision) {
            if Self.retriesOnLayout(load: load, isForeign: isForeign(ref), loading: loadingKey != nil) { retry += 1 }
        }
        .task(id: DetailTaskKey(ref: ref, retry: retry)) {
            let key = DetailTaskKey(ref: ref, retry: retry)
            guard let ref else { loadingKey = nil; stage.cleared(); return }
            if isForeign(ref) { model.officeDocumentShown(ref.url) }   // Office's fonts for the preview (1.3.2)
            loadingKey = key
            // A cancelled task leaves `loadingKey` to the task that replaced it.
            defer { if loadingKey == key { loadingKey = nil } }
            let startRevision = model.layoutRevision
            if visibleClock?.ref != ref { visibleClock = (ref, .now) }
            let current = Self.reusable(load: load, for: ref)
            if current == nil {
                load = Self.placeholder(load: load, loadedURL: loadedURL, for: ref)
                loadedURL = ref.url
            }
            let result = await DetailDocument.load(ref, reusing: current ?? buffer.document(for: ref), foreign: model.foreignPages)
            guard !Task.isCancelled else { return }
            let recognized = await model.ocrText(for: ref)
            guard !Task.isCancelled else { return }
            let detailOCR = recognized.map { DetailOCR(ref: ref, text: $0) }
            ocr = detailOCR
            load = result
            loadedURL = ref.url
            if case .ready(let document) = result {
                buffer.documentLoaded(document, for: ref)
                stage.loaded(document, ref: ref, ocr: detailOCR, heavy: buffer.isSlow(ref) || Self.isHeavy(document, ref))
            } else {
                stage.cleared()
            }
            // Layout progress while this load ran was not acted on (the page was not `.preparing` yet).
            if model.layoutRevision != startRevision, Self.retriesOnLayout(load: result, isForeign: isForeign(ref), loading: false) {
                retry += 1
            }
        }
    }

    /// Whether the provider draws `ref`'s page (Word, PowerPoint). Called on the main actor: `handles` only checks
    /// the extension.
    private func isForeign(_ ref: PageRef?) -> Bool {
        guard let ref, let foreign = model.foreignPages else { return false }
        return foreign.handles(ref.url)
    }

    /// Whether layout progress (`layoutRevision`, up to 1×/s) loads the page again: only a Word/PowerPoint page
    /// that is not laid out yet (`.preparing`) and not loading right now. A load in flight – also one showing
    /// `.preparing` as its placeholder – is not restarted (a detached render cannot be cancelled, and a slow one
    /// would never finish); the check after the load catches up on progress made meanwhile. Triggered via `retry`,
    /// not via the task key, so the task's own changes to `load` never restart it.
    static func retriesOnLayout(load: DetailLoad?, isForeign: Bool, loading: Bool) -> Bool {
        isForeign && load == .preparing && !loading
    }

    /// The loaded document if it still fits `ref`: same file and, for a one-page Office document, the same page.
    static func reusable(load: DetailLoad?, for ref: PageRef) -> DetailDocument? {
        guard case .ready(let d) = load, d.url == ref.url, d.singlePage == nil || d.singlePage == ref.pageIndex else { return nil }
        return d
    }

    /// Shown while `ref` loads: a loaded document stays (the PDFView stays, covered by the stand-in until it has
    /// drawn the new page, 1.3.4); „Vorschau wird vorbereitet …“ stays when it was shown for the same file;
    /// otherwise nil, the stand-in alone (never the previous page, never a spinner).
    static func placeholder(load: DetailLoad?, loadedURL: URL?, for ref: PageRef) -> DetailLoad? {
        if case .ready = load { return load }
        return load == .preparing && loadedURL == ref.url ? .preparing : nil
    }

    /// A page PDFKit draws slowly (big scans): the PDFView gets it only after a rest (1.3.4).
    static func isHeavy(_ document: DetailDocument, _ ref: PageRef) -> Bool {
        document.pdf.page(at: document.documentPageIndex(for: ref))?.pageRef.map(PreviewGeometry.isHeavy) ?? false
    }

    private func navigation(_ ref: PageRef?) -> some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!FocusNavigator.canStep(from: ref, by: -1, hits: model.hits))
                .help("Vorherige Trefferseite")
                .accessibilityLabel("Vorherige Trefferseite")
                .keyboardShortcut("[", modifiers: .command)
            if let ref {
                Text("\(ref.url.lastPathComponent) · \(ViewerText.pageLabel(ref.pageIndex))")
                    .lineLimit(1)
                    .monospacedDigit()
                let openLabel = ViewerText.openOriginal(kind: DocumentKind(fileExtension: ref.url.pathExtension) ?? .pdf)
                Button { model.openInPreview(ref) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(openLabel)
                    .accessibilityLabel(openLabel)
            }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!FocusNavigator.canStep(from: ref, by: 1, hits: model.hits))
                .help("Nächste Trefferseite")
                .accessibilityLabel("Nächste Trefferseite")
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }

    private func step(_ offset: Int) {
        model.focusedPage = FocusNavigator.step(from: model.focusedPage, by: offset, hits: model.hits)
    }
}

/// −, percent, +, „Ganze Seite“ (spec 1.1 §2).
struct ZoomBar: View {
    let zoom: PreviewZoom

    var body: some View {
        HStack(spacing: 8) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom.shownPercent <= PreviewZoom.steps[0])
                .help("Verkleinern")
                .accessibilityLabel("Verkleinern")
                .accessibilityIdentifier("zoomOut")
            Text("\(zoom.shownPercent) %")
                .monospacedDigit()
                .frame(minWidth: 52)
                .accessibilityIdentifier("zoomPercent")
            Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(!zoom.canZoomIn)      // the last step, or the page width without zoom beyond it (1.3.2 §11)
                .help("Vergrößern")
                .accessibilityLabel("Vergrößern")
                .accessibilityIdentifier("zoomIn")
            Button("Ganze Seite") { zoom.fitPage() }
                .disabled(zoom.mode == .fitPage)
                .accessibilityIdentifier("zoomFit")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

/// What the preview buffer prepares for (1.3.4).
private struct BufferKey: Equatable {
    let ref: PageRef?
    let marks: PreviewBuffer.Marks
    let layout: PreviewBuffer.Layout
}

/// What the detail view reloads on: the page, and `retry` for a Word/PowerPoint page still being prepared.
private struct DetailTaskKey: Equatable {
    let ref: PageRef?
    let retry: Int
}

/// Outcome of loading the document for the detail view.
enum DetailLoad: Equatable {
    case missing, unavailable
    /// A Word/PowerPoint page that is not laid out yet (1.3 Teil B).
    case preparing
    case ready(DetailDocument)
}

/// A document opened for the detail view, tagged with the file version it was read from.
struct DetailDocument: Equatable {
    let url: URL
    let modifiedAt: Date?
    let pdf: PDFDocument
    /// nil = the whole file; otherwise `pdf` holds only this page (Word/PowerPoint, 1.3 Teil B).
    let singlePage: Int?
    /// Reports the PDFView's draws of `pdf`'s pages (1.3.4); nil for documents built from pages (images, Office).
    let tracker: PreviewDrawTracker?

    init(url: URL, modifiedAt: Date?, pdf: PDFDocument, singlePage: Int? = nil, tracker: PreviewDrawTracker? = nil) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.pdf = pdf
        self.singlePage = singlePage
        self.tracker = tracker
    }

    static func == (a: DetailDocument, b: DetailDocument) -> Bool { a.pdf === b.pdf }

    /// Index of `ref`'s page in `pdf`.
    func documentPageIndex(for ref: PageRef) -> Int { singlePage == nil ? ref.pageIndex : 0 }

    /// Checks and reads the file off the main actor (a hung network volume must not freeze the UI)
    /// and reuses `current` when the file has not changed since it was read. Pages of files `foreign` handles
    /// (Word, PowerPoint) come from it as one-page documents in full quality; nil from it = not laid out yet.
    /// - Parameter slowPages: 1.4.4: finding pages in some PDFs takes seconds (page tree in compressed object streams,
    ///   unpacked again and again), and PDFView computes every page's size on the main thread when it gets the
    ///   document (20 s hangs). A probe longer than this (finding the shown and the last page, off the main thread)
    ///   shows only that page, as a one-page document.
    @MainActor static func load(_ ref: PageRef, reusing current: DetailDocument? = nil,
                                foreign: (any ForeignPageProvider)? = nil, slowPages: Duration = .milliseconds(100),
                                metrics: IndexMetrics = .shared) async -> DetailLoad {
        let url = ref.url
        let probe = await Task.detached { () -> (exists: Bool, modifiedAt: Date?) in
            var fresh = url
            fresh.removeAllCachedResourceValues()   // URL caches resource values; we need the current file state
            let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey])
            return (values != nil, values?.contentModificationDate)
        }.value
        guard probe.exists else { return .missing }
        if let foreign, foreign.handles(url) {
            if let current, current.url == url, current.singlePage == ref.pageIndex, current.modifiedAt == probe.modifiedAt {
                return .ready(current)
            }
            let started = ContinuousClock.now
            let built = await Task.detached { DocumentBox(foreign.pageDocument(ref, maxPixel: nil)) }.value
            metrics.log("preview_open", ["file": IndexMetrics.hash(url), "ext": url.pathExtension.lowercased(), "page": ref.pageIndex,
                                         "way": built.document == nil ? "office_not_laid_out" : "office", "ms": IndexMetrics.ms(since: started)])
            guard let pdf = built.document, pdf.pageCount > 0 else { return .preparing }
            return .ready(DetailDocument(url: url, modifiedAt: probe.modifiedAt, pdf: pdf, singlePage: ref.pageIndex))
        }
        if let current, current.url == url, current.singlePage == nil || current.singlePage == ref.pageIndex,
           current.modifiedAt == probe.modifiedAt { return .ready(current) }
        if ImagePages.isImage(url) {
            // Decoded off the main actor; 4,000 px keep zooming sharp.
            // The page is built off the main actor too (PDFPage(image:) of a large image takes 100+ ms).
            let built = await Task.detached { DocumentBox(ImageDocument.make(url, maxPixel: 4_000)) }.value
            guard let pdf = built.document else { return .unavailable }
            return .ready(DetailDocument(url: url, modifiedAt: probe.modifiedAt, pdf: pdf))
        }
        let opened = await Task.detached { openPDF(ref, slowPages: slowPages, metrics: metrics) }.value
        guard let opened else { return .unavailable }
        return .ready(DetailDocument(url: url, modifiedAt: probe.modifiedAt, pdf: opened.document.document!,
                                     singlePage: opened.singlePage ? ref.pageIndex : nil, tracker: opened.tracker))
    }

    private struct OpenedPDF: @unchecked Sendable {
        let document: DocumentBox
        let tracker: PreviewDrawTracker
        let singlePage: Bool
    }

    /// Reads and opens the PDF off the main actor. A slow one becomes a one-page document of `ref`'s page.
    /// Writes `preview_open` (hash, pages, way, ms) to the measurement log.
    private nonisolated static func openPDF(_ ref: PageRef, slowPages: Duration, metrics: IndexMetrics) -> OpenedPDF? {
        let start = ContinuousClock.now
        guard let data = try? Data(contentsOf: ref.url, options: .mappedIfSafe), let pdf = PDFDocument(data: data),
              !pdf.isLocked else { return nil }
        // Before any page is read: the pages become `TrackedPage`s (1.3.4).
        let tracker = PreviewDrawTracker()
        pdf.delegate = tracker
        let probeStart = ContinuousClock.now
        let page = pdf.page(at: ref.pageIndex)
        _ = pdf.page(at: pdf.pageCount - 1)
        let probe = ContinuousClock.now - probeStart
        var opened = OpenedPDF(document: DocumentBox(pdf), tracker: tracker, singlePage: false)
        if probe > slowPages, let one = page?.dataRepresentation.flatMap(PDFDocument.init(data:)), one.pageCount == 1 {
            let oneTracker = PreviewDrawTracker()
            one.delegate = oneTracker
            opened = OpenedPDF(document: DocumentBox(one), tracker: oneTracker, singlePage: true)
        }
        metrics.log("preview_open", ["file": IndexMetrics.hash(ref.url), "ext": "pdf", "page": ref.pageIndex, "pages": pdf.pageCount,
                                                 "way": opened.singlePage ? "single_page" : "normal",
                                                 "probe_ms": IndexMetrics.ms(probe), "ms": IndexMetrics.ms(since: start)])
        return opened
    }
}

/// PDFView showing one page of a loaded document with highlighted selections.
struct PDFPageView: NSViewRepresentable {
    /// Large preview: always exact marks (spec 1.1 §14), in the chosen colour at 45 %.
    static func highlightColor(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * HighlightGeometry.exactOpacity)
    }

    let document: PDFDocument
    let pageIndex: Int
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    let zoom: PreviewZoom
    let fractions: [Int]
    /// „Zoom über die Fensterbreite hinaus erlauben“ (1.3.2 §11); off: the page width is the largest zoom.
    var beyondWidth = true
    var color: RGBA = .yellow
    var ocr: DetailOCR?
    /// Reports the draws of `document`'s pages (1.3.4); nil = not tracked (images, Word/PowerPoint pages).
    var tracker: PreviewDrawTracker?
    /// The view drew the page at `pageIndex`; `sharp` = at full resolution (1.3.4).
    var onDraw: ((_ pageIndex: Int, _ sharp: Bool) -> Void)?

    /// A draw at 90 % of the device scale or more is the sharp one, not PDFKit's coarse first picture (1.3.4).
    static func isSharp(drawScale: CGFloat, viewScale: CGFloat, backing: CGFloat) -> Bool {
        drawScale >= 0.9 * viewScale * backing
    }

    @MainActor final class Coordinator {
        var onDraw: ((Int, Bool) -> Void)?
        weak var tracker: PreviewDrawTracker?

        /// Listens to the draws of `document`'s pages and reports those of the page shown.
        func track(_ tracker: PreviewDrawTracker?, document: PDFDocument) {
            self.tracker?.onDraw = nil
            self.tracker = tracker
            let documentID = ObjectIdentifier(document)
            tracker?.onDraw = { [weak self] pageID, scale in
                Task { @MainActor in self?.drew(pageID, scale: scale, documentID: documentID) }
            }
        }

        private func drew(_ pageID: ObjectIdentifier, scale: CGFloat, documentID: ObjectIdentifier) {
            guard let view, let document = view.document, ObjectIdentifier(document) == documentID,
                  let page = view.currentPage, ObjectIdentifier(page) == pageID else { return }
            let viewScale = view.autoScales ? view.scaleFactorForSizeToFit : view.scaleFactor
            let sharp = PDFPageView.isSharp(drawScale: scale, viewScale: viewScale, backing: view.window?.backingScaleFactor ?? 2)
            onDraw?(document.index(for: page), sharp)
        }

        var shownKey: String?
        var applied: (PreviewZoom.Mode, [Int], Int, CGFloat?, Bool)?
        var zoom: PreviewZoom?
        var fractions: [Int] = []
        var beyondWidth = true
        weak var view: PDFView?
        var observers: [NSObjectProtocol] = []

        /// Re-applies a mode that depends on the view size and reports the shown scale.
        func viewChanged() {
            guard let view, let zoom, let page = view.currentPage else { return }
            // Levels follow the width (B when the width follows the zoom), „Ganze Seite“ too with B; percent stays.
            if case .pageWidth = zoom.mode {
                PDFPageView.apply(zoom.mode, fractions: fractions, reference: zoom.referenceWidth, beyondWidth: beyondWidth, to: view, page: page)
            } else if zoom.mode == .fitPage, zoom.referenceWidth != nil {
                PDFPageView.apply(zoom.mode, fractions: fractions, reference: zoom.referenceWidth, beyondWidth: beyondWidth, to: view, page: page)
            } else {
                PDFPageView.limit(view, page: page, reference: zoom.referenceWidth, beyondWidth: beyondWidth)
            }
            report(view)
        }

        func report(_ view: PDFView) {
            let scale = view.autoScales ? view.scaleFactorForSizeToFit : view.scaleFactor
            let percent = Int((scale * 100).rounded())
            guard let zoom, percent > 0 else { return }
            let size = view.currentPage.map { ZoomMath.rotatedSize($0.bounds(for: view.displayBox).size, rotation: $0.rotation) }
            let limit = PDFPageView.maxPercent(view, page: view.currentPage, reference: zoom.referenceWidth, beyondWidth: beyondWidth)
            guard zoom.currentPercent != percent || zoom.pageSize != size || zoom.maxPercent != limit else { return }
            Task { @MainActor in      // not during a view update
                if zoom.currentPercent != percent { zoom.currentPercent = percent }
                if zoom.pageSize != size { zoom.pageSize = size }
                if zoom.maxPercent != limit { zoom.maxPercent = limit }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = .underPageBackgroundColor
        view.postsFrameChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
                MainActor.assumeIsolated { coordinator.viewChanged() }
            })
        return view
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.tracker?.onDraw = nil
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        coordinator.observers.removeAll()
    }

    /// The width the page may fill: B (minus the scroller) when the preview's width follows the zoom, else the view's.
    static func fillWidth(_ view: PDFView, reference: CGFloat?) -> CGFloat {
        let scrollerAllowance = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return (reference ?? view.bounds.width) - scrollerAllowance
    }

    /// The zoom limit without zooming beyond the width (1.3.2 §11); nil when it is allowed or nothing is shown.
    static func maxPercent(_ view: PDFView, page: PDFPage?, reference: CGFloat?, beyondWidth: Bool) -> Int? {
        guard !beyondWidth, let page else { return nil }
        let size = ZoomMath.rotatedSize(page.bounds(for: view.displayBox).size, rotation: page.rotation)
        return PreviewWidthMath.maxPercent(page: size, referenceWidth: fillWidth(view, reference: reference))
    }

    /// Without zoom beyond the width the view itself (pinch, ⌘+) stops at the page width.
    static func limit(_ view: PDFView, page: PDFPage, reference: CGFloat?, beyondWidth: Bool) {
        let size = ZoomMath.rotatedSize(page.bounds(for: view.displayBox).size, rotation: page.rotation)
        view.maxScaleFactor = beyondWidth ? CGFloat(PreviewZoom.steps[PreviewZoom.steps.count - 1]) / 100
            : max(PreviewWidthMath.maxScale(page: size, referenceWidth: fillWidth(view, reference: reference)), view.minScaleFactor)
        if view.scaleFactor > view.maxScaleFactor { view.scaleFactor = view.maxScaleFactor }
    }

    /// Sets the view's scale for `mode` (§2, §13) and the zoom limit (1.3.2 §11). With `reference` (B, the
    /// preview's width follows the zoom) levels and „Ganze Seite“ are measured against B, never against the width
    /// shown right now (spec 1.3.2 §9: nothing feeds back).
    static func apply(_ mode: PreviewZoom.Mode, fractions: [Int], reference: CGFloat? = nil, beyondWidth: Bool = true,
                      to view: PDFView, page: PDFPage) {
        limit(view, page: page, reference: reference, beyondWidth: beyondWidth)
        if let reference {
            let size = ZoomMath.rotatedSize(page.bounds(for: view.displayBox).size, rotation: page.rotation)
            let scale = PreviewWidthMath.scale(mode, fractions: fractions, page: size,
                                               reference: CGSize(width: fillWidth(view, reference: reference), height: view.bounds.height))
            view.autoScales = false
            view.scaleFactor = min(scale, view.maxScaleFactor)
            return
        }
        switch mode {
        case .fitPage:
            view.autoScales = true
        case .percent(let p):
            view.autoScales = false
            view.scaleFactor = CGFloat(p) / 100
        case .pageWidth(let level):
            view.autoScales = false
            let fraction = fractions.indices.contains(level - 1) ? fractions[level - 1] : 100
            let size = ZoomMath.rotatedSize(page.bounds(for: view.displayBox).size, rotation: page.rotation)
            let scrollerAllowance = NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            view.scaleFactor = ZoomMath.pageWidthScale(fraction: fraction, viewWidth: view.bounds.width - scrollerAllowance, page: size)
        }
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onDraw = onDraw
        if view.document !== document {
            context.coordinator.track(tracker, document: document)
            view.document = document
            context.coordinator.shownKey = nil
            context.coordinator.applied = nil   // a new document in this view (another Office page, a reloaded file) gets the zoom again
        }
        let coordinator = context.coordinator
        coordinator.zoom = zoom
        coordinator.fractions = fractions
        coordinator.beyondWidth = beyondWidth
        let key = Self.key(pageIndex: pageIndex, highlightKey: highlightRanges == nil ? "-" : highlightKey, color: color, ocr: ocr)
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return }
        if coordinator.shownKey != key {
            // Only a page change moves the view; a new query or colour just redraws the marks.
            if coordinator.shownKey?.split(separator: "|").first != key.split(separator: "|").first || view.currentPage != page {
                view.go(to: page)
            }
            coordinator.shownKey = key
            // OCR pages have no text layer to select: highlight annotations instead (spec 1.2 §5).
            for p in (0..<document.pageCount).compactMap(document.page(at:)) {
                for a in p.annotations where a.userName == Self.annotationUserName { p.removeAnnotation(a) }
            }
            if let ocr = OCRHighlights.usable(ocr?.text) {
                view.highlightedSelections = []
                for a in Self.ocrAnnotations(on: page, ocr: ocr, highlightRanges: highlightRanges, color: color) { page.addAnnotation(a) }
            } else {
                view.highlightedSelections = Self.selections(on: page, highlightRanges: highlightRanges, color: color)
            }
        }
        // The zoom stays when the page changes (spec §2); re-applied for a new mode, level shares or page.
        if coordinator.applied.map({ $0.0 != zoom.mode || $0.1 != fractions || $0.2 != pageIndex
                                         || $0.3 != zoom.referenceWidth || $0.4 != beyondWidth }) ?? true {
            coordinator.applied = (zoom.mode, fractions, pageIndex, zoom.referenceWidth, beyondWidth)
            Self.apply(zoom.mode, fractions: fractions, reference: zoom.referenceWidth, beyondWidth: beyondWidth, to: view, page: page)
        }
        coordinator.report(view)
    }

    /// What the shown marks depend on: page, query, colour and the page the OCR words belong to.
    static func key(pageIndex: Int, highlightKey: String, color: RGBA, ocr: DetailOCR?) -> String {
        "\(pageIndex)|\(highlightKey)|\(color.key)|\(ocr.map { "ocr\($0.ref.pageIndex)" } ?? "")"
    }

    /// Marks on an OCR page (no text layer to select): highlight annotations at the recognized words.
    static let annotationUserName = "pdfsucher.ocr-highlight"

    static func ocrAnnotations(on page: PDFPage, ocr: OCRPageText, highlightRanges: HighlightRanges?, color: RGBA) -> [PDFAnnotation] {
        guard let highlightRanges else { return [] }
        return OCRHighlights.pageRects(ocr, highlightRanges: highlightRanges, page: page).map { rect in
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = highlightColor(color)
            annotation.userName = annotationUserName
            return annotation
        }
    }

    static func selections(on page: PDFPage, highlightRanges: HighlightRanges?, color: RGBA = .yellow) -> [PDFSelection] {
        guard let highlightRanges, let text = page.string, !text.isEmpty else { return [] }
        return highlightRanges(text).compactMap { range in
            guard range.upperBound <= text.endIndex else { return nil }
            let nsRange = NSRange(range, in: text)
            guard nsRange.length > 0, let selection = page.selection(for: nsRange) else { return nil }
            selection.color = highlightColor(color)
            return selection
        }
    }
}

/// Hands a document built off the main actor over to it (it is not used anywhere else meanwhile).
private struct DocumentBox: @unchecked Sendable {
    let document: PDFDocument?
    init(_ document: PDFDocument?) { self.document = document }
}
