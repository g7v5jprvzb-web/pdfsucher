// ToolbarLayout.swift — 1.2.2 §2: toolbar font size and a toolbar line that wraps instead of cutting off
import SwiftUI

/// Font and control size of the toolbar for a font size in pt.
public enum ToolbarScale {
    public static let range: ClosedRange<Double> = 10...20
    /// The system size (`NSFont.systemFontSize`).
    public static let systemSize: Double = 13

    /// Controls (steppers, checkboxes, segmented symbols) grow with the font.
    public static func controlSize(_ fontSize: Double) -> ControlSize {
        fontSize < 12 ? .small : fontSize <= 15 ? .regular : .large
    }
}

/// Lays its items out left to right and starts a new line when the next one does not fit. Every item
/// keeps its ideal size, so nothing is cut off; an item wider than the line gets a line of its own.
/// New toolbar items (e.g. a file type filter) are simply added to the line that uses it.
public struct ToolbarFlow: Layout {
    public var spacing: CGFloat = 12
    public var lineSpacing: CGFloat = 6

    public init(spacing: CGFloat = 12, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    /// Item indices per line (pure).
    static func rows(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let needed = current.isEmpty ? size.width : used + spacing + size.width
            if !current.isEmpty, needed > width {
                rows.append(current)
                current = [i]
                used = size.width
            } else {
                current.append(i)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func size(for sizes: [CGSize], width: CGFloat) -> CGSize {
        let rows = Self.rows(sizes, width: width, spacing: spacing)
        let widths = rows.map { row in row.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)) }
        let heights = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }
        return CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0)))
    }

    /// Ideal sizes; an item wider than the line is offered the line's width (text then wraps).
    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return size(for: sizes(subviews, width: width), width: width)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews, width: bounds.width)
        var y = bounds.minY
        for row in Self.rows(sizes, width: bounds.width, spacing: spacing) {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (height - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += height + lineSpacing
        }
    }
}
