// GridLayout.swift — Task 4.1
import CoreGraphics
import Foundation

public enum GridLayout {
    /// Height / width of an A4 portrait page.
    public static let pageAspect: CGFloat = 1.414
    /// Smallest tile width in automatic mode (height 80 × 1.414 ≈ 113 pt): tick and page number sit on
    /// the tile, top left (Chris, Task 5.6), and need checkbox ~14 + spacing ~4 + „S. 1234“ ~44 + padding
    /// 8 + inset 8 ≈ 78 pt. With many rows on little height the row count becomes an upper bound.
    public static let minTileWidth: CGFloat = 80
    /// „Automatisch“ shows at most this many pages per row (Chris, Task 5.6); when more would fit,
    /// this many fill the width and grow accordingly.
    public static let maxAutomaticColumns = 10

    /// Largest A4-portrait tile that fits one cell when `available` is split into
    /// `rows` × `columns` cells (`spacing` between columns, `rowHeader` + `spacing` per row).
    public static func tileSize(available: CGSize, rows: Int, columns: Int, spacing: CGFloat = 8, rowHeader: CGFloat = 24) -> CGSize {
        let rows = CGFloat(max(rows, 1))
        let columns = CGFloat(max(columns, 1))
        let cellWidth = (available.width - (columns - 1) * spacing) / columns
        let cellHeight = available.height / rows - rowHeader - spacing
        let width = min(cellWidth, cellHeight / pageAspect)
        guard width.isFinite, width > 0 else { return .zero }
        return CGSize(width: width, height: width * pageAspect)
    }

    /// Page shapes are clamped to this height ÷ width range (a strip or a banner would make tiles vanish).
    public static let pageAspectRange: ClosedRange<CGFloat> = 0.2...5

    /// The tile of one document row (1.3.4, Chris: landscape decks waste the space above and below an A4
    /// tile): the page shape (`pageAspect` = height ÷ width of its first page) fitted into the A4 portrait
    /// tile `base`. Wider pages keep the width and get lower (a 16:9 slide: 40 % of the height), so more
    /// rows fit; taller pages keep the height and get narrower. nil or nonsense keeps `base`.
    /// Pages within 2 % of the base shape keep `base`.
    public static func tileSize(base: CGSize, pageAspect aspect: CGFloat?) -> CGSize {
        guard let aspect, aspect.isFinite, aspect > 0, base.width > 0, base.height > 0,
              base.width.isFinite, base.height.isFinite else { return base }
        // Pages within 2 % of the base shape (A4 = 1.414) keep the base tile exactly: same size as before 1.3.4,
        // so the tiles already cached on disk stay valid.
        if abs(aspect / (base.height / base.width) - 1) < 0.02 { return base }
        let clamped = min(max(aspect, pageAspectRange.lowerBound), pageAspectRange.upperBound)
        let width = min(base.width, base.height / clamped)
        return CGSize(width: width, height: width * clamped)
    }

    /// How many tiles of `tileWidth` fit side by side into `width` (`spacing` between them); at least 1.
    public static func columns(available width: CGFloat, tileWidth: CGFloat, spacing: CGFloat) -> Int {
        let fitting = (width + spacing) / (tileWidth + spacing)
        guard fitting.isFinite, fitting >= 1 else { return 1 }
        return Int(fitting.rounded(.down))
    }

    /// Tile width when `columns` tiles fill `width` (`spacing` between them); height by the A4 ratio.
    public static func fillingTileSize(width: CGFloat, columns: Int, spacing: CGFloat = 8) -> CGSize {
        let columns = CGFloat(max(columns, 1))
        let tileWidth = (width - (columns - 1) * spacing) / columns
        guard tileWidth.isFinite, tileWidth > 0 else { return .zero }
        return CGSize(width: tileWidth, height: tileWidth * pageAspect)
    }

    /// Tile size and number of tiles per row (Chris, Task 5.4, option A).
    /// - fixed: exactly `columns` tiles fill the width; the tile size follows from that and the grid
    ///   scrolls vertically. `rows` and the available height do not matter.
    /// - automatic: the tile height follows from the row height (available height / rows − header −
    ///   spacing), the width from the A4 ratio (never wider than `available.width`), and the row shows
    ///   as many tiles as fit the width.
    ///   Tiles are at least `minTileWidth` wide (unless the window is narrower), so many rows on little
    ///   height never make them vanish. At most `maxAutomaticColumns` (default 10) per row: when more
    ///   would fit, that many fill the width (nil = no cap).
    public static func metrics(available: CGSize, rows: Int, columns: Int, mode: ColumnsMode,
                               spacing: CGFloat = 8, rowHeader: CGFloat = 24,
                               maxAutomaticColumns: Int? = GridLayout.maxAutomaticColumns) -> (tileSize: CGSize, columns: Int) {
        switch mode {
        case .fixed:
            return (fillingTileSize(width: available.width, columns: columns, spacing: spacing), max(columns, 1))
        case .automatic:
            let fitted = tileSize(available: available, rows: rows, columns: 1, spacing: spacing, rowHeader: rowHeader)
            var width = max(fitted.width, minTileWidth)
            if available.width.isFinite, available.width > 0 { width = min(width, available.width) }
            guard width.isFinite, width > 0, available.width.isFinite, available.width > 0 else { return (.zero, 1) }
            let count = Self.columns(available: available.width, tileWidth: width, spacing: spacing)
            if let cap = maxAutomaticColumns.map({ max($0, 1) }), count > cap {
                // More would fit: `cap` tiles fill the width (larger tiles, the grid scrolls vertically).
                return (fillingTileSize(width: available.width, columns: cap, spacing: spacing), cap)
            }
            return (CGSize(width: width, height: width * pageAspect), count)
        }
    }
}
