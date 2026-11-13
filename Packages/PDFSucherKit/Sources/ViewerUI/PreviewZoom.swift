// PreviewZoom.swift — 1.1 Task 6 (spec 1.1 §2 zoom in the large preview, §13 zoom levels)
import CoreGraphics
import Foundation
import Observation

/// Zoom of the large page view; a page change keeps it (also „Ganze Seite“ and levels). Remembered
/// between launches when made with `defaults` (1.2.1 §2).
@MainActor @Observable public final class PreviewZoom {
    public enum Mode: Equatable, Sendable {
        /// „Ganze Seite“: the page fits the view.
        case fitPage
        case percent(Int)
        /// §13: a fraction of the page width (level 1 = „Seitenbreite“), follows the view's width.
        case pageWidth(level: Int)
    }

    public static let steps = [25, 50, 75, 100, 125, 150, 200, 300, 400, 600, 800]

    public var mode: Mode = .fitPage {
        didSet { defaults?.set(Self.format(mode), forKey: Self.key) }
    }
    @ObservationIgnored private let defaults: UserDefaults?
    static let key = "preview.zoom"
    /// The scale the view shows right now, in percent (reported by the view; for `.percent` equal to it).
    public var currentPercent = 100

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let stored = defaults?.string(forKey: Self.key), let mode = Self.parse(stored) { self.mode = mode }
    }

    /// „fit“, „percent:150“, „level:2“.
    static func format(_ mode: Mode) -> String {
        switch mode {
        case .fitPage: "fit"
        case .percent(let p): "percent:\(p)"
        case .pageWidth(let level): "level:\(level)"
        }
    }

    /// nil for anything unknown or out of range (falls back to „Ganze Seite“).
    static func parse(_ text: String) -> Mode? {
        if text == "fit" { return .fitPage }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "percent" where (steps.first!...steps.last!).contains(value): return .percent(value)
        case "level" where (1...4).contains(value): return .pageWidth(level: value)
        default: return nil
        }
    }

    /// Percent shown in the zoom bar.
    public var shownPercent: Int {
        if case .percent(let p) = mode { return p }
        return currentPercent
    }

    /// Next step above what is shown (from „Ganze Seite“ or a level: above the current scale).
    public func zoomIn() {
        if let next = Self.steps.first(where: { $0 > shownPercent }) { mode = .percent(next) }
    }

    public func zoomOut() {
        if let next = Self.steps.last(where: { $0 < shownPercent }) { mode = .percent(next) }
    }

    public func fitPage() { mode = .fitPage }

    /// §13: level 1…4.
    public func setLevel(_ level: Int) {
        guard (1...4).contains(level) else { return }
        mode = .pageWidth(level: level)
    }
}

/// Scale arithmetic for the zoom levels (pure, testable).
public enum ZoomMath {
    /// Page size as displayed (rotation 90/270 swaps width and height).
    public static func rotatedSize(_ size: CGSize, rotation: Int) -> CGSize {
        let quarter = ((rotation % 360) + 360) % 360
        return quarter == 90 || quarter == 270 ? CGSize(width: size.height, height: size.width) : size
    }

    /// Scale at which the page shows `fraction` % of the view's width: fraction × view width / page width.
    /// Never 0, NaN or infinite (a tiny view gives a small positive scale).
    public static func pageWidthScale(fraction: Int, viewWidth: CGFloat, page: CGSize) -> CGFloat {
        let scale = CGFloat(fraction) / 100 * max(viewWidth, 1) / max(page.width, 1)
        return scale.isFinite && scale > 0 ? scale : 0.01
    }
}
