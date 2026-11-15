// PreviewWidth.swift — 1.3.2 Teil B: the preview's width follows the zoom (spec §8–§13)
import CoreGraphics
import Foundation

/// Scale and width of the large preview beside the grid (pure). Everything is measured against the reference
/// width B: the width the user set by dragging the divider. The width shown right now never feeds into the
/// scale, so a narrower pane cannot make the page smaller and the pane narrower again.
public enum PreviewWidthMath {
    /// The scale for `mode` with the page fitted into `reference` (B minus the margin, and the preview's height):
    /// a percentage as it is, a level as a share of B, „Ganze Seite“ the whole page in B × height.
    public static func scale(_ mode: PreviewZoom.Mode, fractions: [Int], page: CGSize, reference: CGSize) -> CGFloat {
        let width = max(page.width, 1), height = max(page.height, 1)
        switch mode {
        case .percent(let p):
            return CGFloat(p) / 100
        case .pageWidth(let level):
            let fraction = fractions.indices.contains(level - 1) ? fractions[level - 1] : 100
            return ZoomMath.pageWidthScale(fraction: fraction, viewWidth: reference.width, page: page)
        case .fitPage:
            let s = min(max(reference.width, 1) / width, max(reference.height, 1) / height)
            return s.isFinite && s > 0 ? s : 0.01
        }
    }

    /// The page's width at `scale` plus `margin`, at least `minimum` and at most B (`reference`); B without a page.
    public static func paneWidth(page: CGSize?, scale: CGFloat, margin: CGFloat, minimum: CGFloat, reference: CGFloat) -> CGFloat {
        guard let page else { return reference }
        let wanted = (page.width * scale + margin).rounded()
        return min(max(wanted, minimum), max(reference, minimum))
    }

    /// The largest scale without zooming beyond the width: the page fills B.
    public static func maxScale(page: CGSize, referenceWidth: CGFloat) -> CGFloat {
        let s = max(referenceWidth, 1) / max(page.width, 1)
        return s.isFinite && s > 0 ? s : 1
    }

    /// `maxScale` in whole percent (rounded down, so the limit is never above the page width).
    public static func maxPercent(page: CGSize, referenceWidth: CGFloat) -> Int {
        max(Int((maxScale(page: page, referenceWidth: referenceWidth) * 100).rounded(.down)), 1)
    }
}

/// Bundles width changes: only the last one of a quick series is applied, once `delay` has passed without a new
/// one (zoom steps from the trackpad or the scroll wheel; spec §10: no flicker).
@MainActor final class WidthBundler {
    private let delay: Duration
    private let apply: @MainActor (CGFloat) -> Void
    private var pending: Task<Void, Never>?

    init(delay: Duration = .milliseconds(120), apply: @escaping @MainActor (CGFloat) -> Void) {
        self.delay = delay
        self.apply = apply
    }

    func request(_ width: CGFloat) {
        pending?.cancel()
        pending = Task { [delay, apply] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            apply(width)
        }
    }

    func cancel() { pending?.cancel(); pending = nil }
}
