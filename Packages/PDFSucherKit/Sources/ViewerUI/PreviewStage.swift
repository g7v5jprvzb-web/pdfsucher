// PreviewStage.swift — 1.3.4 Vorschau-Puffer
import Foundation
import Observation
import OutputKit
import PDFKit

/// What the large preview's PDFView shows, and whether it has drawn it sharply (spec 1.3.4).
///
/// The PDFView stays when the focused page changes; it gets the new page (`shown`) as soon as it is loaded, a heavy
/// page (big scans: PDFKit blocks the main thread ~250 ms in `go(to:)`) only after `rest` without another change.
/// Until the PDFView has drawn `shown` sharply – a sharp draw of that page, then `quiet` without another one –
/// the stand-in covers it. Documents without a draw tracker count as sharp after `untracked`; every page after
/// `timeout` at the latest, so the stand-in never stays.
@MainActor @Observable final class PreviewStage {
    struct Shown {
        let document: DetailDocument
        let ref: PageRef
        let ocr: DetailOCR?
    }

    private(set) var shown: Shown?
    /// `shown`'s page once the PDFView has drawn it sharply.
    private(set) var sharpRef: PageRef?

    @ObservationIgnored private let rest: Duration
    @ObservationIgnored private let quiet: Duration
    @ObservationIgnored private let untracked: Duration
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var handover: Task<Void, Never>?
    /// The page `handover` is for.
    @ObservationIgnored private var pendingRef: PageRef?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    init(rest: Duration = .milliseconds(150), quiet: Duration = .milliseconds(30), untracked: Duration = .milliseconds(100),
         timeout: Duration = .seconds(2)) {
        self.rest = rest
        self.quiet = quiet
        self.untracked = untracked
        self.timeout = timeout
    }

    /// Whether the stand-in covers the PDFView for the focused page `ref`.
    func needsStandIn(for ref: PageRef) -> Bool { !(shown?.ref == ref && sharpRef == ref) }

    /// The preview loaded `document` for the focused page `ref`. A pending handover of another page is dropped.
    func loaded(_ document: DetailDocument, ref: PageRef, ocr: DetailOCR?, heavy: Bool) {
        handover?.cancel()
        handover = nil
        pendingRef = nil
        guard heavy, !(shown?.ref == ref && shown?.document == document) else {
            show(document, ref: ref, ocr: ocr)
            return
        }
        pendingRef = ref
        handover = Task { [weak self, rest] in
            try? await Task.sleep(for: rest)
            guard !Task.isCancelled else { return }
            self?.show(document, ref: ref, ocr: ocr)
        }
    }

    private func show(_ document: DetailDocument, ref: PageRef, ocr: DetailOCR?) {
        let same = shown?.ref == ref && shown?.document == document
        shown = Shown(document: document, ref: ref, ocr: ocr)
        guard !same else { return }
        sharpRef = nil
        settle?.cancel()
        settle = document.tracker == nil ? sharpLater(ref, after: untracked) : nil
        deadline?.cancel()
        deadline = sharpLater(ref, after: timeout)
    }

    /// The focus moved to `ref`: a heavy page waiting for its rest is not handed over any more (the user left it;
    /// `go(to:)` would block the main thread for a page no longer wanted).
    func focusMoved(to ref: PageRef?) {
        guard let pendingRef, pendingRef != ref else { return }
        handover?.cancel()
        handover = nil
        self.pendingRef = nil
    }

    /// The PDFView drew page `pageIndex` of `document` at full resolution.
    func drewSharp(pageIndex: Int, document: PDFDocument) {
        guard let shown, sharpRef != shown.ref, shown.document.pdf === document,
              shown.document.documentPageIndex(for: shown.ref) == pageIndex else { return }
        settle?.cancel()             // more tiles come: wait until they are drawn
        settle = sharpLater(shown.ref, after: quiet)
    }

    /// Nothing to show (no page, missing or unreadable file, a page still being prepared).
    func cleared() {
        handover?.cancel()
        settle?.cancel()
        deadline?.cancel()
        shown = nil
        sharpRef = nil
    }

    private func sharpLater(_ ref: PageRef, after delay: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.shown?.ref == ref else { return }
            self.sharpRef = ref
            self.settle?.cancel()
            self.deadline?.cancel()
        }
    }
}
