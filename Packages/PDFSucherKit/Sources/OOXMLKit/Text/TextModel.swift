// TextModel.swift — Task 7 (OOXMLKit)
// Input and output types of ParagraphSetter. Shared with WordKit: keep these stable.
//
// Units: points. Coordinates: origin top-left of the paragraph, y down (same convention as DrawingRenderer).
// Anything named "percent" is on a 0…100 scale (30 = 30 %); `LineSpacing.multiple` is a factor (1 = single).
// Character indices are UTF-16 offsets (NSString semantics) into `SetParagraph.plainText`.
import CoreGraphics
import Foundation

public enum Align: Sendable, Equatable {
    case left, center, right, justify, distributed
}

public enum Caps: Sendable, Equatable {
    /// `small`: approximated (lowercase letters drawn as capitals at 80 % size; see docs/decisions.md).
    case none, small, all
}

/// Underline kind. PowerPoint has many more (`dotted`, `wavy`, `heavy`, …): callers map them to `single`,
/// `dbl` to `double`. Drawn by Core Text in the text color.
public enum Underline: Sendable, Equatable {
    case none, single, double
}

public enum Spacing: Sendable, Equatable {
    case points(CGFloat)
    /// Percent (100 = one single line) of the first run's font size, as in `a:spcPct` (50000 → 50).
    /// Resolved as `percent / 100 × single line height` (PowerPoint: 1.2 × size).
    case percent(Double)
}

public enum LineSpacing: Sendable, Equatable {
    /// Factor of the single line height (1 = single, 1.5, 2, …).
    case multiple(Double)
    case exact(CGFloat)
    case atLeast(CGFloat)
}

public enum TabAlignment: Sendable, Equatable {
    case left, center, right, decimal
}

public struct TabStop: Sendable, Equatable {
    /// Points from the paragraph's left edge (x = 0, the text box inset / page margin), the same origin as
    /// `marginLeft` — not from `marginLeft`.
    public var position: CGFloat
    public var alignment: TabAlignment

    public init(position: CGFloat, alignment: TabAlignment = .left) {
        self.position = position
        self.alignment = alignment
    }
}

public enum Bullet: Sendable, Equatable {
    /// `typeface`/`color`/`sizePercent` nil → follow the first run (buFontTx / buClrTx / buSzTx).
    /// Symbol typefaces (Wingdings, Symbol, …) are mapped through `FontResolver.mapSymbolText`.
    case char(String, typeface: String?, color: RGBA?, sizePercent: Double?)
    /// `scheme` is the DrawingML `a:buAutoNum@type` (arabicPeriod, alphaLcParenR, romanUcPeriod, …).
    /// The number drawn is `set(autoNumber:)`, or `startAt` when that is nil.
    case autoNumber(scheme: String, startAt: Int, typeface: String?, color: RGBA?, sizePercent: Double?)
    /// Picture bullet: not drawn by the setter; its place is reported in `SetParagraph.bullet`.
    case picture(id: Int, size: CGSize)
}

public struct RunStyle: Sendable, Equatable {
    /// nil → theme minor font (FontResolver).
    public var typeface: String?
    public var size: CGFloat
    public var bold: Bool
    public var italic: Bool
    public var underline: Underline
    public var strike: Bool
    public var color: RGBA
    /// Percent of the font size; positive raises (superscript), negative lowers. The size is not reduced.
    public var baselineShift: Double
    /// `all`/`small` change the drawn text only; plainText keeps the original characters.
    public var caps: Caps
    /// Extra space after each character in points (callers convert `a:rPr@spc`, 1/100 pt). Not scaled by
    /// fontScale.
    public var spacing: CGFloat
    /// Drawn as a rectangle behind the run, covering the line's ascent/descent box.
    public var highlight: RGBA?

    public init(typeface: String? = nil, size: CGFloat = 18, bold: Bool = false, italic: Bool = false,
                underline: Underline = .none, strike: Bool = false, color: RGBA = RGBA(r: 0, g: 0, b: 0),
                baselineShift: Double = 0, caps: Caps = .none, spacing: CGFloat = 0, highlight: RGBA? = nil) {
        self.typeface = typeface
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.color = color
        self.baselineShift = baselineShift
        self.caps = caps
        self.spacing = spacing
        self.highlight = highlight
    }

    /// Minor theme font, 18 pt, black (PowerPoint's default body text).
    public static let `default` = RunStyle()
}

/// Each case maps to characters of `SetParagraph.plainText`: text as is, tab → "\t", lineBreak → "\n",
/// inline → U+FFFC (one UTF-16 unit each).
public enum RunContent: Sendable, Equatable {
    case text(String)
    case tab
    case lineBreak
    /// Placeholder of `size` (width × height above the baseline, nothing below). Placement is reported in
    /// `SetLine.inlines`; the caller draws it.
    case inline(id: Int, size: CGSize)
}

public struct Run: Sendable, Equatable {
    public var content: RunContent
    public var style: RunStyle

    public init(content: RunContent, style: RunStyle = .default) {
        self.content = content
        self.style = style
    }
}

public struct ParagraphStyle: Sendable, Equatable {
    public var align: Align
    /// All measured from the paragraph's left/right edge. Hanging indent = negative `indentFirst`.
    public var marginLeft: CGFloat
    public var marginRight: CGFloat
    public var indentFirst: CGFloat
    public var spaceBefore: Spacing
    public var spaceAfter: Spacing
    public var lineSpacing: LineSpacing
    public var tabs: [TabStop]
    /// Interval of the default tab stops after the explicit ones (DrawingML default 914400 EMU = 72 pt).
    public var defaultTab: CGFloat
    public var bullet: Bullet?
    /// Sets Core Text's base writing direction only; indents and alignment are not mirrored.
    public var rtl: Bool

    public init(align: Align = .left, marginLeft: CGFloat = 0, marginRight: CGFloat = 0, indentFirst: CGFloat = 0,
                spaceBefore: Spacing = .points(0), spaceAfter: Spacing = .points(0),
                lineSpacing: LineSpacing = .multiple(1), tabs: [TabStop] = [], defaultTab: CGFloat = 72,
                bullet: Bullet? = nil, rtl: Bool = false) {
        self.align = align
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.indentFirst = indentFirst
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.lineSpacing = lineSpacing
        self.tabs = tabs
        self.defaultTab = defaultTab
        self.bullet = bullet
        self.rtl = rtl
    }

    public static let `default` = ParagraphStyle()
}

public struct Paragraph: Sendable, Equatable {
    public var runs: [Run]
    public var style: ParagraphStyle
    /// Style of the paragraph mark (`a:endParaRPr`): height of an empty paragraph and of the empty line after
    /// a trailing line break.
    public var endRunStyle: RunStyle

    /// `endRunStyle` nil → the last run's style, or `RunStyle.default` without runs.
    public init(runs: [Run], style: ParagraphStyle = .default, endRunStyle: RunStyle? = nil) {
        self.runs = runs
        self.style = style
        self.endRunStyle = endRunStyle ?? runs.last?.style ?? .default
    }
}

// MARK: - output

/// An inline object's placement, in paragraph coordinates (y down, paragraph top = 0).
public struct InlinePlacement: Sendable, Equatable {
    public var id: Int
    public var rect: CGRect

    public init(id: Int, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// A word (or the part of it on one line) and its box in paragraph coordinates.
public struct WordRect: Sendable, Equatable {
    /// UTF-16 range in `SetParagraph.plainText`.
    public var range: NSRange
    public var rect: CGRect

    public init(range: NSRange, rect: CGRect) {
        self.range = range
        self.rect = rect
    }
}

public struct SetLine: Sendable, Equatable {
    /// UTF-16 offsets into `plainText`, including trailing spaces and the line break character.
    public var range: Range<Int>
    /// Start of the baseline (after indent and alignment), relative to the paragraph's top-left, y down.
    public var origin: CGPoint
    /// Largest ascent/descent on the line (fonts incl. baseline shift, inline objects, the bullet).
    public var ascent: CGFloat
    public var descent: CGFloat
    /// Line pitch from the line-spacing rule. The line occupies `top ..< top + height`;
    /// `origin.y == top + height − descent` (extra space goes above the text, as in PowerPoint).
    public var height: CGFloat
    /// Distance from the paragraph top to the line top (sum of the previous lines' heights).
    public var top: CGFloat
    /// Typographic width without trailing whitespace (after justification).
    public var width: CGFloat
    public var inlines: [InlinePlacement]

    public init(range: Range<Int>, origin: CGPoint, ascent: CGFloat, descent: CGFloat, height: CGFloat,
                top: CGFloat, width: CGFloat, inlines: [InlinePlacement]) {
        self.range = range
        self.origin = origin
        self.ascent = ascent
        self.descent = descent
        self.height = height
        self.top = top
        self.width = width
        self.inlines = inlines
    }
}

/// The bullet or number of a paragraph. Not part of `plainText`.
public struct SetBullet: Sendable, Equatable {
    /// Drawn text ("•", "3.", "iv)"); nil for a picture bullet.
    public var text: String?
    /// `Bullet.picture` id (the caller draws the picture into `rect`); nil for text bullets.
    public var pictureID: Int?
    /// Baseline start, on the first line's baseline.
    public var origin: CGPoint
    /// Typographic box (text) or picture box (bottom on the baseline), paragraph coordinates.
    public var rect: CGRect

    public init(text: String?, pictureID: Int?, origin: CGPoint, rect: CGRect) {
        self.text = text
        self.pictureID = pictureID
        self.origin = origin
        self.rect = rect
    }
}

/// What `LineSpacing.multiple(1)` (and `Spacing.percent(100)`) means.
public enum LineHeightBase: Sendable, Equatable {
    /// factor × largest font size on the line (PowerPoint: 1.2, measured against its PDF export, docs/decisions.md).
    case fontSize(factor: CGFloat)
    /// ascent + descent + leading of the largest font on the line (Word's "auto").
    case fontMetrics
}
