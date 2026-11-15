// ViewState.swift — 1.2.1 §2: window, splitter and settings tab remembered between launches
import CoreGraphics
import Foundation

/// Reiter des Einstellungsfensters (der zuletzt gewählte wird gemerkt).
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, preview, appearance, ocr, office, storage, keyboard, shortcuts
}

/// Size of the settings window (1.2.4): one size in which every tab fits without scrolling, at most 85 % of the
/// visible screen height. „Index“ and „Kachel-Cache“ live in „Speicher“: in „Allgemein“ they made it 985 pt.
public enum SettingsLayout {
    public static let defaultContentSize = CGSize(width: 680, height: 920)
    public static let minContentSize = CGSize(width: 640, height: 420)
    /// Room the tab bar takes inside the content in a plain window (the settings window puts it in the toolbar).
    static let tabChrome: CGFloat = 40

    public static func contentSize(forVisibleScreen screen: CGSize) -> CGSize {
        CGSize(width: min(defaultContentSize.width, screen.width),
               height: min(defaultContentSize.height, (screen.height * 0.85).rounded(.down)))
    }
}

/// Where a remembered window goes when it is opened again (pure).
public enum WindowPlacement {
    /// Smallest remembered window size that is used at all (anything smaller is a broken value).
    public static let minimumSize = CGSize(width: 400, height: 300)
    /// The window stays where it was when at least this much of its title bar is on a screen.
    static let visibleTitleBar = CGSize(width: 120, height: 24)

    /// `frame` if enough of its title bar is visible on one of `visibleFrames` (AppKit coordinates,
    /// origin bottom-left); otherwise moved into the first (main) screen, shrunk to it if needed.
    /// - Parameter minSize: the window's minimum (a smaller remembered frame grows down from its title bar).
    public static func fitted(_ frame: CGRect, visibleFrames: [CGRect], minSize: CGSize = .zero) -> CGRect {
        var frame = frame
        if frame.width < minSize.width || frame.height < minSize.height {
            let size = CGSize(width: max(frame.width, minSize.width), height: max(frame.height, minSize.height))
            frame = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
        guard let main = visibleFrames.first else { return frame }
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - visibleTitleBar.height, width: frame.width, height: visibleTitleBar.height)
        if let screen = visibleFrames.first(where: { screen in
            let shown = screen.intersection(titleBar)
            return !shown.isNull && shown.width >= visibleTitleBar.width && shown.height >= visibleTitleBar.height - 0.5
        }) {
            // Taller or wider than this screen (it came from a larger one): shrunk into it (review I4).
            guard frame.width > screen.width || frame.height > screen.height else { return frame }
            let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
            let x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
            let y = min(max(frame.maxY - size.height, screen.minY), screen.maxY - size.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        let x = min(max(frame.minX, main.minX), main.maxX - size.width)
        let y = min(max(frame.minY, main.minY), main.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// „x y w h“ (the form stored in UserDefaults); nil for anything else or a size below `minimumSize`.
    static func parseFrame(_ text: String?) -> CGRect? {
        guard let numbers = numbers(text), numbers.count == 4,
              numbers[2] >= minimumSize.width, numbers[3] >= minimumSize.height else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    static func parsePoint(_ text: String?) -> CGPoint? {
        guard let numbers = numbers(text), numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    static func format(_ rect: CGRect) -> String { [rect.minX, rect.minY, rect.width, rect.height].map { "\(Double($0))" }.joined(separator: " ") }
    static func format(_ point: CGPoint) -> String { "\(Double(point.x)) \(Double(point.y))" }

    private static func numbers(_ text: String?) -> [CGFloat]? {
        guard let parts = text?.split(separator: " ") else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy(\.isFinite) else { return nil }
        return values.map { CGFloat($0) }
    }
}

/// Share of the preview in the split between preview and grid (pure).
public enum SplitMath {
    public static let minFraction = 0.1
    public static let maxFraction = 0.9

    /// 1.1 ideal sizes: 340 of 760 pt with the preview on top, 480 of 1,240 pt beside the grid.
    public static func defaultFraction(_ position: PreviewPosition) -> Double { position == .top ? 0.45 : 0.39 }

    public static func clampFraction(_ value: Double, for position: PreviewPosition) -> Double {
        value.isFinite ? min(max(value, minFraction), maxFraction) : defaultFraction(position)
    }

    /// The preview's length along the split axis; both panes keep their minimum (the preview first when
    /// there is not room for both).
    public static func previewLength(fraction: Double, total: CGFloat, minPreview: CGFloat, minGrid: CGFloat) -> CGFloat {
        let wanted = (total * CGFloat(fraction)).rounded()
        return max(min(wanted, total - minGrid), minPreview)
    }

    public static func fraction(previewLength: CGFloat, total: CGFloat) -> Double {
        total > 0 ? Double(previewLength / total) : 0.5
    }
}
