// ParagraphSetter.swift — Task 7 (OOXMLKit)
// Sets one paragraph on Core Text: one CTTypesetter per paragraph, lines by CTTypesetterSuggestLineBreak,
// PowerPoint line-height rules, bullets, tabs, inline placeholders, justification, word rects. Shared with
// WordKit (rationale: docs/decisions.md, "ParagraphSetter").
//
// Coordinates: points, origin top-left of the paragraph, y down (as DrawingRenderer).
// Indices: UTF-16 offsets into `SetParagraph.plainText` (NSString semantics). The bullet is not in plainText.
import CoreGraphics
import CoreText
import Foundation

// CTLine is an immutable CF object (thread-safe to read and draw from any thread) but is not annotated
// Sendable, so it is stored through this box (same reasoning as FontResolver's CTFont box).
struct LineBox: @unchecked Sendable {
    let line: CTLine
}

/// Per run (style segment) data that Core Text does not draw itself.
struct Decoration: Sendable {
    var color: RGBA
    var strike: Bool
    var highlight: RGBA?
    var baselineOffset: CGFloat
}

public struct SetParagraph: Sendable {
    public let lines: [SetLine]
    /// Sum of the line heights. spaceBefore/spaceAfter are NOT included: the caller applies them (and decides
    /// whether the first paragraph's spaceBefore counts).
    public let height: CGFloat
    /// Run texts concatenated; tab → "\t", lineBreak → "\n", inline → U+FFFC. Bullet/number text excluded.
    public let plainText: String
    /// Resolved to points (percent → of the first run's single line height, after fontScale).
    public let spaceBefore: CGFloat
    public let spaceAfter: CGFloat
    public let bullet: SetBullet?

    let ctLines: [LineBox?]
    let bulletLine: LineBox?
    let decorations: [Decoration]
    let words: [NSRange]

    /// Draws `lines` (clamped to the valid range) so that the top of the first of them is at `origin`. The
    /// context's CTM must be y-down (DrawingRenderer convention). Core Text draws y-up, so each line is drawn
    /// under a local flip (save/restore); the context's text matrix is restored afterwards (it is not part of
    /// the graphics state). The bullet is drawn with line 0. Picture bullets and inline objects are not
    /// drawn (see `bullet` / `SetLine.inlines`). `fonts` is unused today (fonts are resolved at set time);
    /// it is part of the agreed signature.
    public func draw(lines range: Range<Int>, in ctx: CGContext, at origin: CGPoint, fonts: FontResolver) {
        let r = range.clamped(to: 0..<lines.count)
        guard let first = r.first, origin.x.isFinite, origin.y.isFinite else { return }
        let dx = origin.x
        let dy = origin.y - lines[first].top
        let savedTextMatrix = ctx.textMatrix
        defer { ctx.textMatrix = savedTextMatrix }
        if r.contains(0), let b = bullet, let bl = bulletLine {
            Self.drawLine(bl.line, in: ctx, at: CGPoint(x: dx + b.origin.x, y: dy + b.origin.y))
        }
        for i in r {
            guard let ct = ctLines[i]?.line else { continue }
            let l = lines[i]
            let base = CGPoint(x: dx + l.origin.x, y: dy + l.origin.y)
            let runs = Self.glyphRuns(ct)
            for run in runs {
                guard let d = decoration(of: run), let h = d.highlight, let span = Self.span(of: run) else { continue }
                ctx.setFillColor(DrawingRenderer.cgColor(h))
                ctx.fill(CGRect(x: base.x + span.x, y: base.y - l.ascent, width: span.width, height: l.ascent + l.descent))
            }
            Self.drawLine(ct, in: ctx, at: base)
            for run in runs {
                guard let d = decoration(of: run), d.strike, let span = Self.span(of: run),
                      let font = Self.font(of: run) else { continue }
                let y = base.y - d.baselineOffset - CTFontGetXHeight(font) / 2
                ctx.setFillColor(DrawingRenderer.cgColor(d.color))
                let t = max(CTFontGetUnderlineThickness(font), 0.5)
                ctx.fill(CGRect(x: base.x + span.x, y: y - t / 2, width: span.width, height: t))
            }
        }
    }

    /// Boxes of the words on `lines` (clamped), in paragraph coordinates (y relative to the paragraph top,
    /// not to `lines.lowerBound`). A word = maximal run of letters, digits and combining marks; an apostrophe
    /// (' or ’) between two such characters belongs to the word; hyphens and other punctuation split
    /// ("E-Mail" → "E", "Mail"). A word broken across lines gives one rect per line, each with the sub-range
    /// on that line. Vertical extent = the line's ascent/descent box.
    public func wordRects(lines range: Range<Int>) -> [WordRect] {
        let r = range.clamped(to: 0..<lines.count)
        var out: [WordRect] = []
        var w = 0
        for i in r {
            guard let ct = ctLines[i]?.line else { continue }
            let l = lines[i]
            while w < words.count, NSMaxRange(words[w]) <= l.range.lowerBound { w += 1 }
            var k = w
            while k < words.count, words[k].location < l.range.upperBound {
                let lo = max(words[k].location, l.range.lowerBound)
                let hi = min(NSMaxRange(words[k]), l.range.upperBound)
                let x0 = CTLineGetOffsetForStringIndex(ct, lo, nil)
                let x1 = CTLineGetOffsetForStringIndex(ct, hi, nil)
                out.append(WordRect(range: NSRange(location: lo, length: hi - lo),
                                    rect: CGRect(x: l.origin.x + min(x0, x1), y: l.origin.y - l.ascent,
                                                 width: abs(x1 - x0), height: l.ascent + l.descent)))
                k += 1
            }
        }
        return out
    }

    // MARK: helpers

    private static func drawLine(_ line: CTLine, in ctx: CGContext, at p: CGPoint) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func glyphRuns(_ line: CTLine) -> [CTRun] {
        (CTLineGetGlyphRuns(line) as NSArray).compactMap { obj in
            CFGetTypeID(obj as CFTypeRef) == CTRunGetTypeID() ? (obj as! CTRun) : nil  // type checked above
        }
    }

    static func font(of run: CTRun) -> CTFont? {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let f = attrs[kCTFontAttributeName as String], CFGetTypeID(f as CFTypeRef) == CTFontGetTypeID()
        else { return nil }
        return (f as! CTFont)  // type checked above
    }

    /// x offset (from the line origin) and advance width of a run.
    private static func span(of run: CTRun) -> (x: CGFloat, width: CGFloat)? {
        guard CTRunGetGlyphCount(run) > 0 else { return nil }
        var p = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &p)
        let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
        return (p.x, w)
    }

    private func decoration(of run: CTRun) -> Decoration? {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let i = attrs[ParagraphSetter.styleKey.rawValue] as? Int, decorations.indices.contains(i) else { return nil }
        return decorations[i]
    }
}

public struct ParagraphSetter: Sendable {
    public let fonts: FontResolver
    public let lineHeightBase: LineHeightBase
    /// false (PowerPoint): a line break's own font does not count for the height of the line it ends, unless
    /// the line holds nothing else. true (default): every run on the line counts, the break included.
    public let lineBreakSetsLineHeight: Bool
    /// false (PowerPoint): the natural line height is max(single height, tallest inline object); a taller font's
    /// ascent + descent does not grow it. true (default): max(single, ascent + descent of the line).
    public let fontMetricsGrowLines: Bool

    static let styleKey = NSAttributedString.Key("OOXMLKit.ParagraphSetter.style")

    public init(fonts: FontResolver, lineHeightBase: LineHeightBase = .fontSize(factor: 1.2),
                lineBreakSetsLineHeight: Bool = true, fontMetricsGrowLines: Bool = true) {
        self.fonts = fonts
        self.lineHeightBase = lineHeightBase
        self.lineBreakSetsLineHeight = lineBreakSetsLineHeight
        self.fontMetricsGrowLines = fontMetricsGrowLines
    }

    /// Sets `p` into `width` points. `fontScale` (normAutofit) scales every font and bullet size;
    /// `lineSpaceReduction` (normAutofit lnSpcReduction as a fraction, 0.2 = 20 %) is subtracted from
    /// `LineSpacing.multiple`. `autoNumber`: the number of this paragraph for `.autoNumber` bullets (the caller
    /// counts); nil → the bullet's `startAt`. `bulletOnEmpty`: draw the bullet/number on an empty paragraph too
    /// (Word does for empty list items; PowerPoint does not, hence the default false). Never traps; non-finite
    /// values fall back to defaults.
    public func set(_ p: Paragraph, width: CGFloat, fontScale: Double = 1, lineSpaceReduction: Double = 0,
                    autoNumber: Int? = nil, bulletOnEmpty: Bool = false) -> SetParagraph {
        let env = Env(setter: self, p: p, width: width, fontScale: fontScale, reduction: lineSpaceReduction)
        let content = buildContent(p, env)
        let typesetter = CTTypesetterCreateWithAttributedString(content.attr)
        let n = content.attr.length
        let plain16 = Array(content.plain.utf16)

        // Bullet (on empty paragraphs only with bulletOnEmpty).
        let bulletSet = n > 0 || bulletOnEmpty ? makeBullet(p, env, firstStyle: n > 0 ? content.firstStyle : p.endRunStyle, autoNumber: autoNumber) : nil

        let firstX = env.marginLeft + env.indent
        var firstTextX = firstX
        if let b = bulletSet {
            firstTextX = firstX + b.width <= env.marginLeft + 0.01 ? env.marginLeft
                : firstX + b.width + 0.25 * env.size(content.firstStyle ?? p.endRunStyle)
        }

        var lines: [SetLine] = []
        var boxes: [LineBox?] = []
        var top: CGFloat = 0
        var start = 0
        while start < n {
            let x = lines.isEmpty ? firstTextX : env.marginLeft
            let avail = env.right - x
            var count = avail > 0 ? CTTypesetterSuggestLineBreakWithOffset(typesetter, start, Double(avail), Double(x + env.tabBias)) : 0
            if count <= 0 {
                count = CTTypesetterSuggestClusterBreakWithOffset(typesetter, start, Double(max(avail, 0)), Double(x + env.tabBias))
            }
            count = min(max(count, 1), n - start)
            let range = start..<(start + count)
            var line = CTTypesetterCreateLineWithOffset(typesetter, CFRange(location: start, length: count),
                                                       Double(x + env.tabBias))
            let isLast = range.upperBound == n
            let endsWithBreak = range.upperBound <= plain16.count && plain16[range.upperBound - 1] == 0x0A
            let justify = (p.style.align == .justify && !isLast && !endsWithBreak)
                || (p.style.align == .distributed && !endsWithBreak)
            if justify, avail > 0, let j = CTLineCreateJustifiedLine(line, 1.0, Double(avail)) { line = j }

            var m = metrics(of: line, content: content, env: env)
            if lines.isEmpty, let b = bulletSet { m.include(b.metrics) }
            let height = env.lineHeight(m)
            let width = Self.visibleWidth(line)
            let shift = env.alignShift(p.style.align, avail: avail, width: width)
            let origin = CGPoint(x: x + shift, y: top + height - m.descent)
            var inlines: [InlinePlacement] = []
            for i in range {
                guard let obj = content.inlines[i] else { continue }
                let off = CTLineGetOffsetForStringIndex(line, i, nil)
                inlines.append(InlinePlacement(id: obj.id, rect: CGRect(x: origin.x + off, y: origin.y - obj.size.height,
                                                                         width: obj.size.width, height: obj.size.height)))
            }
            lines.append(SetLine(range: range, origin: origin, ascent: m.ascent, descent: m.descent, height: height,
                                 top: top, width: width, inlines: inlines))
            boxes.append(LineBox(line: line))
            top += height
            start += count
        }
        // Empty paragraph, or the empty line after a trailing line break: metrics from endRunStyle.
        if n == 0 || plain16.last == 0x0A {
            var m = env.metrics(of: env.font(p.endRunStyle))
            if lines.isEmpty, let b = bulletSet { m.include(b.metrics) }
            let height = env.lineHeight(m)
            let x = n == 0 ? firstTextX : env.marginLeft
            let shift = env.alignShift(p.style.align, avail: env.right - x, width: 0)
            lines.append(SetLine(range: n..<n, origin: CGPoint(x: x + shift, y: top + height - m.descent),
                                 ascent: m.ascent, descent: m.descent, height: height, top: top, width: 0, inlines: []))
            boxes.append(nil)
            top += height
        }

        var bullet: SetBullet?
        if let b = bulletSet, let l0 = lines.first {
            let shift = l0.origin.x - firstTextX
            let origin = CGPoint(x: firstX + shift, y: l0.origin.y)
            let rect = CGRect(x: origin.x, y: origin.y - b.metrics.ascent, width: b.width,
                              height: b.metrics.ascent + b.metrics.descent)
            bullet = SetBullet(text: b.text, pictureID: b.pictureID, origin: origin, rect: rect)
        }

        let firstForSpacing = content.firstStyle ?? p.endRunStyle
        return SetParagraph(lines: lines, height: top, plainText: content.plain,
                            spaceBefore: env.resolve(p.style.spaceBefore, firstForSpacing),
                            spaceAfter: env.resolve(p.style.spaceAfter, firstForSpacing),
                            bullet: bullet, ctLines: boxes, bulletLine: bulletSet?.line.map(LineBox.init),
                            decorations: content.decorations, words: Self.wordRanges(content.plain))
    }

    // MARK: environment (sanitized inputs and line-height rules)

    struct LineMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        /// Single line height of the largest font on the line (LineHeightBase).
        var single: CGFloat = 0
        /// Height of the tallest inline object on the line.
        var inline: CGFloat = 0

        mutating func include(_ o: LineMetrics) {
            ascent = max(ascent, o.ascent)
            descent = max(descent, o.descent)
            single = max(single, o.single)
            inline = max(inline, o.inline)
        }
    }

    struct Env {
        let setter: ParagraphSetter
        let scale: CGFloat
        let reduction: Double
        let marginLeft: CGFloat
        let indent: CGFloat
        let right: CGFloat
        let lineSpacing: LineSpacing
        /// Core Text mishandles negative line offsets (tab positions go wrong), so when a line starts left of
        /// x = 0 the tab coordinate system is shifted right by this amount (offsets and stops alike).
        let tabBias: CGFloat

        init(setter: ParagraphSetter, p: Paragraph, width: CGFloat, fontScale: Double, reduction: Double) {
            func len(_ v: CGFloat) -> CGFloat { v.isFinite ? min(max(v, -1e6), 1e6) : 0 }
            self.setter = setter
            scale = fontScale.isFinite && fontScale > 0 ? CGFloat(fontScale) : 1
            self.reduction = reduction.isFinite ? max(reduction, 0) : 0
            marginLeft = len(p.style.marginLeft)
            // No clamping: negative x (outdent into the margin, Word w:ind w:left < 0) is legal. Callers that
            // need marL + indent ≥ 0 (PowerPoint) clamp before calling.
            indent = len(p.style.indentFirst)
            right = (width.isFinite ? min(max(width, 0), 1e6) : 0) - len(p.style.marginRight)
            lineSpacing = p.style.lineSpacing
            tabBias = max(0, -min(marginLeft, marginLeft + indent))
        }

        /// Font size after fontScale, clamped to 0.5…4000 pt (non-finite → 18).
        func size(_ s: RunStyle, factor: CGFloat = 1) -> CGFloat {
            let base = s.size.isFinite && s.size > 0 ? s.size : 18
            let v = base * scale * factor
            return v.isFinite ? min(max(v, 0.5), 4000) : 18
        }

        func font(_ s: RunStyle, factor: CGFloat = 1) -> CTFont {
            setter.fonts.font(typeface: s.typeface, size: size(s, factor: factor), bold: s.bold, italic: s.italic)
        }

        func single(_ font: CTFont) -> CGFloat {
            switch setter.lineHeightBase {
            case .fontSize(let factor): (factor.isFinite && factor > 0 ? factor : 1.2) * CTFontGetSize(font)
            case .fontMetrics: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            }
        }

        func metrics(of font: CTFont, baselineOffset: CGFloat = 0) -> LineMetrics {
            LineMetrics(ascent: CTFontGetAscent(font) + max(baselineOffset, 0),
                        descent: CTFontGetDescent(font) - min(baselineOffset, 0), single: single(font))
        }

        /// natural = max(single line height, ascent + descent); multiple → natural × (factor − reduction),
        /// exact → the value, atLeast → max(value, natural). See docs/decisions.md.
        func lineHeight(_ m: LineMetrics) -> CGFloat {
            let natural = setter.fontMetricsGrowLines ? max(m.single, m.ascent + m.descent) : max(m.single, m.inline)
            switch lineSpacing {
            case .multiple(let f): return natural * CGFloat(f.isFinite ? max(f - reduction, 0) : 1)
            case .exact(let pt): return pt.isFinite && pt > 0 ? min(pt, 1e5) : natural
            case .atLeast(let pt): return max(pt.isFinite ? min(pt, 1e5) : 0, natural)
            }
        }

        func alignShift(_ align: Align, avail: CGFloat, width: CGFloat) -> CGFloat {
            switch align {
            case .center: (avail - width) / 2
            case .right: avail - width
            case .left, .justify, .distributed: 0
            }
        }

        /// Spacing.percent: percent / 100 × single line height of the first run's font.
        func resolve(_ s: Spacing, _ style: RunStyle) -> CGFloat {
            switch s {
            case .points(let pt): return pt.isFinite ? min(max(pt, 0), 1e5) : 0
            case .percent(let pc):
                guard pc.isFinite else { return 0 }
                return min(max(CGFloat(pc) / 100 * single(font(style)), 0), 1e5)
            }
        }
    }

    // MARK: attributed string

    final class InlineMetrics: Sendable {
        let width: CGFloat
        let height: CGFloat
        init(width: CGFloat, height: CGFloat) {
            self.width = width
            self.height = height
        }
    }

    struct Content {
        var attr = NSMutableAttributedString()
        var plain = ""
        var decorations: [Decoration] = []
        var inlines: [Int: (id: Int, size: CGSize)] = [:]
        /// First run with non-empty text (bullet and spacing follow it); else the first run.
        var firstStyle: RunStyle?
    }

    /// `kCTLigatureAttributeName` value: only ligatures the script requires. Office draws without standard
    /// ligatures by default, and a ligature glyph (Calibri "tt", "ff", "fi") has no text of its own in a PDF that
    /// PDFKit saves from our drawing ("Dritte" read back as "Dri$e"), so search in merged PDFs missed such words.
    static let noLigatures = 0

    private func buildContent(_ p: Paragraph, _ env: Env) -> Content {
        var c = Content()
        let paraStyle = makeParagraphStyle(p.style, env)
        var firstAny: RunStyle?
        for run in p.runs {
            let s = run.style
            firstAny = firstAny ?? s
            let font = env.font(s)
            let shift = s.baselineShift.isFinite ? CGFloat(s.baselineShift) / 100 * CTFontGetSize(font) : 0
            var attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): DrawingRenderer.cgColor(s.color),
                .init(kCTParagraphStyleAttributeName as String): paraStyle,
                .init(kCTLigatureAttributeName as String): Self.noLigatures,
                Self.styleKey: c.decorations.count,
            ]
            if s.spacing.isFinite, s.spacing != 0 { attrs[.init(kCTKernAttributeName as String)] = s.spacing }
            if shift != 0 { attrs[.init(kCTBaselineOffsetAttributeName as String)] = shift }
            switch s.underline {
            case .none: break
            case .single: attrs[.init(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            case .double: attrs[.init(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.double.rawValue
            }
            c.decorations.append(Decoration(color: s.color, strike: s.strike, highlight: s.highlight, baselineOffset: shift))

            switch run.content {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if c.firstStyle == nil { c.firstStyle = s }
                c.plain += text
                switch s.caps {
                case .none: c.attr.append(NSAttributedString(string: text, attributes: attrs))
                case .all: c.attr.append(NSAttributedString(string: Self.upper(text).text, attributes: attrs))
                case .small:
                    // Lowercase letters as capitals at 80 % size; groups of equal size share one append.
                    var small = attrs
                    small[.init(kCTFontAttributeName as String)] = env.font(s, factor: 0.8)
                    for (part, lowered) in Self.smallCapsGroups(text) {
                        c.attr.append(NSAttributedString(string: part, attributes: lowered ? small : attrs))
                    }
                }
            case .tab:
                c.plain += "\t"
                c.attr.append(NSAttributedString(string: "\t", attributes: attrs))
            case .lineBreak:
                // U+2028 (line separator) breaks the line without starting a new Core Text paragraph.
                c.plain += "\n"
                c.attr.append(NSAttributedString(string: "\u{2028}", attributes: attrs))
            case .inline(let id, let size):
                func dim(_ v: CGFloat) -> CGFloat { v.isFinite ? min(max(v, 0), 1e5) : 0 }
                let sz = CGSize(width: dim(size.width), height: dim(size.height))
                c.inlines[c.attr.length] = (id, sz)
                c.plain += "\u{FFFC}"
                if let delegate = Self.runDelegate(sz) {
                    attrs[.init(kCTRunDelegateAttributeName as String)] = delegate
                }
                c.attr.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            }
        }
        if c.firstStyle == nil { c.firstStyle = firstAny }
        return c
    }

    private static func runDelegate(_ size: CGSize) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<InlineMetrics>.fromOpaque($0).release() },
            getAscent: { Unmanaged<InlineMetrics>.fromOpaque($0).takeUnretainedValue().height },
            getDescent: { _ in 0 },
            getWidth: { Unmanaged<InlineMetrics>.fromOpaque($0).takeUnretainedValue().width })
        let ref = Unmanaged.passRetained(InlineMetrics(width: size.width, height: size.height))
        guard let d = CTRunDelegateCreate(&callbacks, ref.toOpaque()) else {
            ref.release()
            return nil
        }
        return d
    }

    /// Uppercase per character, keeping characters whose uppercase has another UTF-16 length (ß → SS), so
    /// display and plainText offsets stay identical. `lowered[i]`: character i was changed.
    static func upper(_ s: String) -> (text: String, changed: [Bool]) {
        var out = ""
        var changed: [Bool] = []
        for ch in s {
            let o = String(ch)
            let u = o.uppercased()
            let use = u.utf16.count == o.utf16.count && u != o
            out += use ? u : o
            changed.append(use)
        }
        return (out, changed)
    }

    static func smallCapsGroups(_ s: String) -> [(String, Bool)] {
        let (text, changed) = upper(s)
        var groups: [(String, Bool)] = []
        for (ch, low) in zip(text, changed) {
            if let last = groups.last, last.1 == low { groups[groups.count - 1].0.append(ch) } else { groups.append((String(ch), low)) }
        }
        return groups
    }

    private func makeParagraphStyle(_ st: ParagraphStyle, _ env: Env) -> CTParagraphStyle {
        var stops = st.tabs.filter { $0.position.isFinite && $0.position > 0 && $0.position < 1e6 }
        // Hanging indent: marginLeft acts as a tab stop for the first line (PowerPoint and Word).
        if env.indent < 0, env.marginLeft > 0, !stops.contains(where: { abs($0.position - env.marginLeft) < 0.01 }) {
            stops.append(TabStop(position: env.marginLeft))
        }
        stops.sort { $0.position < $1.position }
        let interval: CGFloat = st.defaultTab.isFinite && st.defaultTab >= 1 ? min(st.defaultTab, 1e5) : 72
        // Default stops are multiples of the interval from the paragraph edge (PowerPoint/Word). Core Text would
        // put them at lastExplicitStop + k × interval, so the ones after the last explicit stop are added
        // explicitly up to one interval past the right edge (at most 256); always so with a tab bias, since
        // CT's own default stops would then be measured from the shifted origin.
        if let last = stops.last?.position ?? (env.tabBias > 0 ? 0 : nil) {
            var pos = (floor(last / interval) + 1) * interval
            var added = 0
            while pos <= max(env.right, 0) + interval, added < 256 {
                stops.append(TabStop(position: pos))
                pos += interval
                added += 1
            }
        }
        let decimal = NSCharacterSet(charactersIn: Locale.current.decimalSeparator ?? ".")
        let ctTabs: [CTTextTab] = stops.map { t in
            let pos = Double(t.position + env.tabBias)
            switch t.alignment {
            case .left: return CTTextTabCreate(.left, pos, nil)
            case .center: return CTTextTabCreate(.center, pos, nil)
            case .right: return CTTextTabCreate(.right, pos, nil)
            case .decimal:
                let options = [kCTTabColumnTerminatorsAttributeName: decimal] as CFDictionary
                return CTTextTabCreate(.right, pos, options)
            }
        }
        var tabs = ctTabs as CFArray
        var defaultInterval = interval
        var direction: CTWritingDirection = st.rtl ? .rightToLeft : .leftToRight
        return withUnsafePointer(to: &tabs) { t in
            withUnsafePointer(to: &defaultInterval) { i in
                withUnsafePointer(to: &direction) { d in
                    let settings = [
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: t),
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: i),
                        CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                                value: d),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    // MARK: bullet

    struct BulletSet {
        var text: String?
        var pictureID: Int?
        var line: CTLine?
        var width: CGFloat
        var metrics: LineMetrics
    }

    private func makeBullet(_ p: Paragraph, _ env: Env, firstStyle: RunStyle?, autoNumber: Int?) -> BulletSet? {
        guard let bullet = p.style.bullet else { return nil }
        let fs = firstStyle ?? p.endRunStyle
        var text: String
        var typeface: String?
        var color: RGBA?
        var percent: Double?
        switch bullet {
        case .char(let s, let tf, let c, let pc):
            (text, typeface, color, percent) = (s, tf, c, pc)
        case .autoNumber(let scheme, let startAt, let tf, let c, let pc):
            (text, typeface, color, percent) = (AutoNumber.text(scheme: scheme, number: autoNumber ?? startAt), tf, c, pc)
        case .picture(let id, let size):
            func dim(_ v: CGFloat) -> CGFloat { v.isFinite ? min(max(v, 0), 1e5) : 0 }
            let h = dim(size.height)
            return BulletSet(text: nil, pictureID: id, line: nil, width: dim(size.width),
                             metrics: LineMetrics(ascent: h, descent: 0, single: 0))
        }
        guard !text.isEmpty else { return nil }
        var style = fs
        if let tf = typeface {
            let mapped = FontResolver.mapSymbolText(text, typeface: tf)
            // Mapped symbol text is drawn in the text font; anything else keeps the bullet typeface.
            style.typeface = mapped.text != text ? fs.typeface : tf
            style.bold = false
            style.italic = false
            text = mapped.text
        }
        let factor = percent.map { $0.isFinite && $0 > 0 ? CGFloat($0) / 100 : 1 } ?? 1
        let font = env.font(style, factor: factor)
        let attr = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): DrawingRenderer.cgColor(color ?? fs.color),
            .init(kCTLigatureAttributeName as String): Self.noLigatures,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        return BulletSet(text: text, pictureID: nil, line: line,
                         width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), metrics: env.metrics(of: font))
    }

    // MARK: line metrics

    private func metrics(of line: CTLine, content: Content, env: Env) -> LineMetrics {
        var m = LineMetrics()
        var runs = SetParagraph.glyphRuns(line)
        if !lineBreakSetsLineHeight {
            // Runs made only of line separators (U+2028) do not count when the line has anything else.
            let text = content.attr.string as NSString
            let kept = runs.filter { run in
                let r = CTRunGetStringRange(run)
                guard r.location >= 0, r.length > 0, r.location + r.length <= text.length else { return true }
                return text.substring(with: NSRange(location: r.location, length: r.length))
                    .unicodeScalars.contains { $0 != "\u{2028}" }
            }
            if !kept.isEmpty { runs = kept }
        }
        for run in runs {
            guard let font = SetParagraph.font(of: run) else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let offset = (attrs[Self.styleKey.rawValue] as? Int).flatMap {
                content.decorations.indices.contains($0) ? content.decorations[$0].baselineOffset : nil
            } ?? 0
            if attrs[kCTRunDelegateAttributeName as String] != nil {
                var ascent: CGFloat = 0
                _ = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, nil, nil)
                var fm = env.metrics(of: font)
                fm.ascent = ascent
                fm.inline = ascent
                m.include(fm)
            } else {
                m.include(env.metrics(of: font, baselineOffset: offset))
            }
        }
        return m
    }

    static func visibleWidth(_ line: CTLine) -> CGFloat {
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        return max(w, 0)
    }

    // MARK: words

    static func wordRanges(_ s: String) -> [NSRange] {
        func isWord(_ c: Unicode.Scalar) -> Bool {
            let p = c.properties
            switch p.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return p.isAlphabetic || p.numericType != nil
            }
        }
        let scalars = Array(s.unicodeScalars)
        var out: [NSRange] = []
        var start: Int?
        var offset = 0
        for (i, c) in scalars.enumerated() {
            defer { offset += c.utf16.count }
            if isWord(c) {
                if start == nil { start = offset }
            } else if c == "'" || c == "\u{2019}", start != nil, i + 1 < scalars.count, isWord(scalars[i + 1]) {
                continue
            } else if let st = start {
                out.append(NSRange(location: st, length: offset - st))
                start = nil
            }
        }
        if let st = start { out.append(NSRange(location: st, length: offset - st)) }
        return out
    }
}
