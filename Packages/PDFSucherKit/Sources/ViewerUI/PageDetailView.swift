// PageDetailView.swift — Task 4.3
import AppKit
import OutputKit
import PDFKit
import SearchKit
import SwiftUI

/// The focused page, large, with matches highlighted; ‹ › step through all hit pages in grid order.
struct PageDetailView: View {
    let model: any ViewerModel
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    @State private var load: DetailLoad?
    /// Recognized text of the focused page (spec 1.2 §5); nil for pages with a text layer.
    @State private var ocr: DetailOCR?

    var body: some View {
        let ref = model.focusedPage
        ZStack {
            if let ref {
                switch load {
                case nil:
                    ProgressView()
                case .missing:
                    ContentUnavailableView(ViewerText.tilePlaceholder(fileExists: false, folderUnreachable: model.indexStatus == .unreachable),
                                           systemImage: "doc.questionmark")
                case .unavailable:
                    ContentUnavailableView(ViewerText.previewUnavailable, systemImage: "exclamationmark.triangle")
                case .ready(let document):
                    PDFPageView(document: document.pdf, pageIndex: ref.pageIndex, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                zoom: model.previewZoom, fractions: model.settings.zoomLevelFractions,
                                color: model.settings.highlightColor, ocr: ocr?.ref == ref ? ocr : nil)
                }
            } else {
                ContentUnavailableView("Keine Seite gewählt", systemImage: "doc.text.magnifyingglass",
                                       description: Text(ViewerText.noFocusedPage))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { if ref != nil { navigation(ref) } }
        .overlay(alignment: .topTrailing) { if ref != nil { ZoomBar(zoom: model.previewZoom).padding(8) } }
        .task(id: ref) {
            guard let ref else { return }
            let current: DetailDocument? = if case .ready(let d) = load, d.url == ref.url { d } else { nil }
            if current == nil { load = nil }
            let result = await DetailDocument.load(ref.url, reusing: current)
            guard !Task.isCancelled else { return }
            let recognized = await model.ocrText(for: ref)
            guard !Task.isCancelled else { return }
            ocr = recognized.map { DetailOCR(ref: ref, text: $0) }
            load = result
        }
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
                Button { model.openInPreview(ref) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("In Vorschau öffnen")
                    .accessibilityLabel("In Vorschau öffnen")
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
                .disabled(zoom.shownPercent >= PreviewZoom.steps[PreviewZoom.steps.count - 1])
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

/// Outcome of loading the document for the detail view.
enum DetailLoad: Equatable {
    case missing, unavailable
    case ready(DetailDocument)
}

/// A document opened for the detail view, tagged with the file version it was read from.
struct DetailDocument: Equatable {
    let url: URL
    let modifiedAt: Date?
    let pdf: PDFDocument

    static func == (a: DetailDocument, b: DetailDocument) -> Bool { a.pdf === b.pdf }

    /// Checks and reads the file off the main actor (a hung network volume must not freeze the UI)
    /// and reuses `current` when the file has not changed since it was read.
    @MainActor static func load(_ url: URL, reusing current: DetailDocument? = nil) async -> DetailLoad {
        let probe = await Task.detached { () -> (exists: Bool, modifiedAt: Date?) in
            var fresh = url
            fresh.removeAllCachedResourceValues()   // URL caches resource values; we need the current file state
            let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey])
            return (values != nil, values?.contentModificationDate)
        }.value
        guard probe.exists else { return .missing }
        if let current, current.url == url, current.modifiedAt == probe.modifiedAt { return .ready(current) }
        if ImagePages.isImage(url) {
            // Decoded off the main actor; 4,000 px keep zooming sharp.
            // The page is built off the main actor too (PDFPage(image:) of a large image takes 100+ ms).
            let built = await Task.detached { DocumentBox(ImageDocument.make(url, maxPixel: 4_000)) }.value
            guard let pdf = built.document else { return .unavailable }
            return .ready(DetailDocument(url: url, modifiedAt: probe.modifiedAt, pdf: pdf))
        }
        let data = await Task.detached { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
        guard let data, let pdf = PDFDocument(data: data), !pdf.isLocked else { return .unavailable }
        return .ready(DetailDocument(url: url, modifiedAt: probe.modifiedAt, pdf: pdf))
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
    var color: RGBA = .yellow
    var ocr: DetailOCR?

    @MainActor final class Coordinator {
        var shownKey: String?
        var applied: (PreviewZoom.Mode, [Int], Int)?
        var zoom: PreviewZoom?
        var fractions: [Int] = []
        weak var view: PDFView?
        var observers: [NSObjectProtocol] = []

        /// Re-applies a mode that depends on the view size and reports the shown scale.
        func viewChanged() {
            guard let view, let zoom, let page = view.currentPage else { return }
            if case .pageWidth = zoom.mode {          // levels follow the width; percent stays as it is
                PDFPageView.apply(zoom.mode, fractions: fractions, to: view, page: page)
            }
            report(view)
        }

        func report(_ view: PDFView) {
            let scale = view.autoScales ? view.scaleFactorForSizeToFit : view.scaleFactor
            let percent = Int((scale * 100).rounded())
            guard let zoom, percent > 0, zoom.currentPercent != percent else { return }
            Task { @MainActor in zoom.currentPercent = percent }   // not during a view update
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
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        coordinator.observers.removeAll()
    }

    /// Sets the view's scale for `mode` (§2, §13). Levels: a share of the view width over the displayed
    /// page width (rotation applied).
    static func apply(_ mode: PreviewZoom.Mode, fractions: [Int], to view: PDFView, page: PDFPage) {
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
        if view.document !== document {
            view.document = document
            context.coordinator.shownKey = nil
        }
        let coordinator = context.coordinator
        coordinator.zoom = zoom
        coordinator.fractions = fractions
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
        if coordinator.applied.map({ $0.0 != zoom.mode || $0.1 != fractions || $0.2 != pageIndex }) ?? true {
            coordinator.applied = (zoom.mode, fractions, pageIndex)
            Self.apply(zoom.mode, fractions: fractions, to: view, page: page)
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
