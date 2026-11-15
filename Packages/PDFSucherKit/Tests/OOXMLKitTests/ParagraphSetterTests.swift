import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OOXMLKit

private let fonts = FontResolver(theme: nil)
private let setter = ParagraphSetter(fonts: fonts)
private let long = "The quick brown fox jumps over the lazy dog and keeps running across the field until the end."

private func hv(_ size: CGFloat = 12) -> RunStyle { RunStyle(typeface: "Helvetica", size: size) }

private func para(_ content: [RunContent], size: CGFloat = 12, style: ParagraphStyle = .default) -> Paragraph {
    Paragraph(runs: content.map { Run(content: $0, style: hv(size)) }, style: style)
}

private func text(_ s: String, size: CGFloat = 12, style: ParagraphStyle = .default) -> Paragraph {
    para([.text(s)], size: size, style: style)
}

/// Typographic width of `s` set alone in Helvetica.
private func measure(_ s: String, size: CGFloat = 12) -> CGFloat {
    let font = fonts.font(typeface: "Helvetica", size: size, bold: false, italic: false)
    let attr = NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): font])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
}

private func sub(_ sp: SetParagraph, _ r: Range<Int>) -> String {
    (sp.plainText as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count))
}

private func word(_ sp: SetParagraph, at location: Int) -> WordRect? {
    sp.wordRects(lines: 0..<sp.lines.count).first { $0.range.location == location }
}

private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

private func ink(_ c: Canvas, x: Range<Int>, y: Range<Int>) -> Int {
    var n = 0
    for yy in y where yy >= 0 && yy < c.height {
        for xx in x where xx >= 0 && xx < c.width && c.pixel(xx, yy).a > 128 { n += 1 }
    }
    return n
}

// MARK: line breaking and indents

@Test func wrapsAtWidth100Helvetica12() {
    var expected = 0
    var current = ""
    for w in long.split(separator: " ") {
        let candidate = current.isEmpty ? String(w) : current + " " + w
        if current.isEmpty || measure(candidate) <= 100 { current = candidate } else { expected += 1; current = String(w) }
    }
    expected += 1
    let sp = setter.set(text(long), width: 100)
    #expect(expected >= 4)
    #expect(sp.lines.count == expected)
    #expect(sp.lines.map { sub(sp, $0.range) }.joined() == long)
    #expect(sp.lines.first?.range.lowerBound == 0)
    #expect(sp.lines.last?.range.upperBound == (long as NSString).length)
    for l in sp.lines { #expect(l.width <= 100.01) }
    #expect(near(sp.height, sp.lines.reduce(0) { $0 + $1.height }))
}

@Test func hangingIndentSecondLineStartsAtMarginLeft() {
    let sp = setter.set(text(long, style: ParagraphStyle(marginLeft: 40, indentFirst: -40)), width: 150)
    #expect(sp.lines.count >= 2)
    #expect(near(sp.lines[0].origin.x, 0))
    #expect(near(sp.lines[1].origin.x, 40))
    for l in sp.lines.dropFirst() { #expect(l.width <= 110.01) }
}

@Test func firstLineIndentAndRightMargin() {
    let sp = setter.set(text(long, style: ParagraphStyle(marginLeft: 10, marginRight: 20, indentFirst: 15)), width: 150)
    #expect(near(sp.lines[0].origin.x, 25))
    #expect(sp.lines[0].width <= 105.01)
    #expect(near(sp.lines[1].origin.x, 10))
    for l in sp.lines.dropFirst() { #expect(l.width <= 120.01) }
}

@Test func lineBreakForcesNewLineAndPlainTextMapping() {
    let sp = setter.set(para([.text("a"), .tab, .text("b"), .lineBreak, .inline(id: 1, size: CGSize(width: 5, height: 5)),
                              .text("c")]), width: 300)
    #expect(sp.plainText == "a\tb\n\u{FFFC}c")
    #expect(sp.lines.map(\.range) == [0..<4, 4..<6])
}

@Test func trailingLineBreakAddsEmptyLine() {
    let sp = setter.set(para([.text("a"), .lineBreak]), width: 300)
    #expect(sp.lines.map(\.range) == [0..<2, 2..<2])
    #expect(near(sp.lines[1].height, 14.4))
}

// MARK: tabs

@Test func defaultTabAt72() {
    let sp = setter.set(para([.text("a"), .tab, .text("b")]), width: 300)
    #expect(sp.plainText == "a\tb")
    #expect(near(word(sp, at: 2)?.rect.minX ?? -1, 72))
}

@Test func tabPositionsAreMeasuredFromParagraphEdge() {
    let sp = setter.set(para([.text("a"), .tab, .text("b")], style: ParagraphStyle(marginLeft: 20)), width: 300)
    #expect(near(sp.lines[0].origin.x, 20))
    #expect(near(word(sp, at: 2)?.rect.minX ?? -1, 72))
}

@Test func explicitTabStops() {
    let left = setter.set(para([.text("a"), .tab, .text("b"), .tab, .text("c")],
                               style: ParagraphStyle(tabs: [TabStop(position: 30)])), width: 300)
    #expect(near(word(left, at: 2)?.rect.minX ?? -1, 30))
    #expect(near(word(left, at: 4)?.rect.minX ?? -1, 72))

    let right = setter.set(para([.tab, .text("12")], style: ParagraphStyle(tabs: [TabStop(position: 200, alignment: .right)])),
                           width: 300)
    #expect(near(word(right, at: 1)?.rect.maxX ?? -1, 200, 0.5))

    let center = setter.set(para([.tab, .text("abc")], style: ParagraphStyle(tabs: [TabStop(position: 150, alignment: .center)])),
                            width: 300)
    #expect(near(word(center, at: 1)?.rect.midX ?? -1, 150, 0.5))

    let sep = Locale.current.decimalSeparator ?? "."
    let decimal = setter.set(para([.tab, .text("12" + sep + "5")], style: ParagraphStyle(tabs: [TabStop(position: 200, alignment: .decimal)])),
                             width: 300)
    // Core Text centres the separator on the stop.
    let sepWidth = measure(sep)
    #expect(near(word(decimal, at: 1)?.rect.maxX ?? -1, 200 - sepWidth / 2, 0.5))
    #expect(near(word(decimal, at: 4)?.rect.minX ?? -1, 200 + sepWidth / 2, 0.5))
}

@Test func hangingIndentIsAnImplicitTabStop() {
    let sp = setter.set(para([.text("1."), .tab, .text("Text")], style: ParagraphStyle(marginLeft: 40, indentFirst: -40)),
                        width: 300)
    #expect(near(word(sp, at: 3)?.rect.minX ?? -1, 40))
}

// MARK: line spacing

@Test func exactLineSpacing20() {
    let sp = setter.set(text(long, style: ParagraphStyle(lineSpacing: .exact(20))), width: 100)
    #expect(sp.lines.count >= 3)
    for i in 1..<sp.lines.count { #expect(near(sp.lines[i].origin.y - sp.lines[i - 1].origin.y, 20)) }
    for l in sp.lines { #expect(near(l.height, 20)) }
    #expect(near(sp.height, 20 * CGFloat(sp.lines.count)))
}

@Test func multipleLineSpacingIsPowerPointsFontSizeRule() {
    #expect(near(setter.set(text("Hallo"), width: 300).lines[0].height, 14.4))
    let one = setter.set(text("Hallo"), width: 300).lines[0]
    #expect(near(one.origin.y, one.height - one.descent))
    #expect(near(setter.set(text("Hallo", style: ParagraphStyle(lineSpacing: .multiple(1.5))), width: 300).height, 21.6))
    #expect(near(setter.set(text("Hallo", style: ParagraphStyle(lineSpacing: .multiple(1.5))), width: 300,
                            lineSpaceReduction: 0.2).height, 14.4 * 1.3))
    #expect(near(setter.set(text("Hallo", size: 20), width: 300, fontScale: 0.5).height, 12))
    #expect(near(setter.set(text("Hallo", style: ParagraphStyle(lineSpacing: .atLeast(30))), width: 300).height, 30))
    #expect(near(setter.set(text("Hallo", style: ParagraphStyle(lineSpacing: .atLeast(5))), width: 300).height, 14.4))
    // Largest size on the line wins.
    let mixed = Paragraph(runs: [Run(content: .text("a"), style: hv(12)), Run(content: .text("B"), style: hv(30))])
    #expect(near(setter.set(mixed, width: 300).height, 36))
}

@Test func fontMetricsBaseUsesAscentDescentLeading() {
    let metrics = ParagraphSetter(fonts: fonts, lineHeightBase: .fontMetrics)
    let font = fonts.font(typeface: "Helvetica", size: 12, bold: false, italic: false)
    let expected = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    #expect(near(metrics.set(text("Hallo"), width: 300).height, expected))
}

@Test func spaceBeforeAfterResolvedSeparately() {
    let st = ParagraphStyle(spaceBefore: .points(6), spaceAfter: .percent(50))
    let sp = setter.set(text("Hallo", size: 20, style: st), width: 300)
    #expect(near(sp.spaceBefore, 6))
    #expect(near(sp.spaceAfter, 12))
    #expect(near(sp.height, 24))
}

// MARK: inline objects

@Test func inlineObjectRaisesLineAndIsPlaced() {
    let plain = setter.set(para([.text("ab")]), width: 300)
    let sp = setter.set(para([.text("a"), .inline(id: 7, size: CGSize(width: 50, height: 30)), .text("b")]), width: 300)
    #expect(sp.plainText == "a\u{FFFC}b")
    let line = sp.lines[0]
    #expect(line.height > plain.lines[0].height)
    #expect(line.ascent >= 30)
    #expect(near(line.height, 30 + line.descent))
    #expect(line.inlines.count == 1)
    let r = line.inlines[0]
    #expect(r.id == 7)
    #expect(near(r.rect.width, 50) && near(r.rect.height, 30))
    #expect(near(r.rect.maxY, line.origin.y))
    #expect(near(r.rect.minX, measure("a"), 0.5))
    #expect(near(word(sp, at: 2)?.rect.minX ?? -1, measure("a") + 50, 0.5))
}

// MARK: word rects

@Test func wordRectOfKuendigungsfristCoversGlyphs() {
    let sp = setter.set(text("Die Kündigungsfrist endet"), width: 400)
    let words = sp.wordRects(lines: 0..<1)
    #expect(words.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 15),
                                   NSRange(location: 20, length: 5)])
    guard words.count == 3 else { return }
    let r = words[1].rect
    let line = sp.lines[0]
    #expect(abs(r.width - measure("Kündigungsfrist")) <= 1)
    #expect(abs(r.minX - measure("Die ")) <= 1)
    #expect(near(r.minY, line.origin.y - line.ascent) && near(r.maxY, line.origin.y + line.descent))
    #expect(r.minY >= line.top - 0.01 && r.maxY <= line.top + line.height + 0.01)
}

@Test func wordRectsUmlautsApostrophesHyphens() {
    let sp = setter.set(text("Kündigungsfrist Müller"), width: 400)
    #expect(sp.wordRects(lines: 0..<1).map(\.range) == [NSRange(location: 0, length: 15), NSRange(location: 16, length: 6)])
    let other = setter.set(text("Peter's E-Mail, 'x' 2026"), width: 400)
    #expect(other.wordRects(lines: 0..<1).map(\.range) == [
        NSRange(location: 0, length: 7), NSRange(location: 8, length: 1), NSRange(location: 10, length: 4),
        NSRange(location: 17, length: 1), NSRange(location: 20, length: 4),
    ])
}

@Test func wordSplitAcrossLinesGivesOneRectPerLine() {
    let sp = setter.set(text("Kündigungsfrist"), width: 40)
    #expect(sp.lines.count >= 2)
    let rects = sp.wordRects(lines: 0..<sp.lines.count)
    #expect(rects.count == sp.lines.count)
    #expect(rects.map(\.range.length).reduce(0, +) == 15)
    #expect(rects.first?.range.location == 0)
    for (r, l) in zip(rects, sp.lines) {
        #expect(r.range.location == l.range.lowerBound)
        #expect(near(r.rect.minY, l.origin.y - l.ascent))
    }
    // A sub-range of lines only returns words of those lines.
    #expect(sp.wordRects(lines: 1..<2).count == 1)
}

// MARK: bullets

@Test func autoNumber3ArabicPeriod() {
    let st = ParagraphStyle(bullet: .autoNumber(scheme: "arabicPeriod", startAt: 1, typeface: nil, color: nil, sizePercent: nil))
    #expect(setter.set(text("Punkt", style: st), width: 300, autoNumber: 3).bullet?.text == "3.")
    #expect(setter.set(text("Punkt", style: st), width: 300).bullet?.text == "1.")
    #expect(setter.set(text("Punkt", style: st), width: 300, autoNumber: 3).plainText == "Punkt")
}

@Test func autoNumberSchemes() {
    let cases: [(String, Int, String)] = [
        ("arabicPeriod", 12, "12."), ("arabicParenR", 3, "3)"), ("arabicParenBoth", 3, "(3)"), ("arabicPlain", 3, "3"),
        ("alphaLcPeriod", 3, "c."), ("alphaUcPeriod", 28, "BB."), ("alphaLcParenR", 1, "a)"), ("alphaUcParenR", 26, "Z)"),
        ("alphaLcParenBoth", 2, "(b)"), ("romanLcPeriod", 4, "iv."), ("romanUcPeriod", 1994, "MCMXCIV."),
        ("romanLcParenR", 9, "ix)"), ("bogus", 5, "5."), ("romanUcPeriod", 0, "0."), ("alphaLcPeriod", -1, "-1."),
    ]
    for (scheme, n, expected) in cases { #expect(AutoNumber.text(scheme: scheme, number: n) == expected) }
}

@Test func bulletIsDrawnButNotInPlainText() {
    let st = ParagraphStyle(marginLeft: 30, indentFirst: -30, bullet: .char("•", typeface: nil, color: nil, sizePercent: nil))
    let sp = setter.set(text("Hallo Welt", size: 30, style: st), width: 200)
    #expect(sp.plainText == "Hallo Welt")
    #expect(sp.bullet?.text == "•")
    #expect(sp.wordRects(lines: 0..<1).first?.range == NSRange(location: 0, length: 5))
    let c = Canvas()
    sp.draw(lines: 0..<1, in: c.ctx, at: .zero, fonts: fonts)
    #expect(ink(c, x: 0..<29, y: 0..<100) > 10)
}

@Test func hangingBulletPosition() {
    let st = ParagraphStyle(marginLeft: 30, indentFirst: -30, bullet: .char("•", typeface: nil, color: nil, sizePercent: nil))
    let sp = setter.set(text(long, style: st), width: 150)
    guard let b = sp.bullet else { Issue.record("no bullet"); return }
    #expect(near(b.origin.x, 0))
    #expect(near(b.origin.y, sp.lines[0].origin.y))
    #expect(near(sp.lines[0].origin.x, 30))
    #expect(near(sp.lines[1].origin.x, 30))
    #expect(b.rect.maxX < 30)
}

@Test func bulletThatDoesNotFitPushesText() {
    let st = ParagraphStyle(bullet: .char("•", typeface: nil, color: nil, sizePercent: nil))
    let sp = setter.set(text("Hallo", style: st), width: 300)
    guard let b = sp.bullet else { Issue.record("no bullet"); return }
    #expect(near(b.origin.x, 0))
    #expect(sp.lines[0].origin.x > b.rect.maxX)
}

@Test func bulletSizeAndSymbolMapping() {
    func bullet(_ b: Bullet) -> SetBullet? { setter.set(text("x", style: ParagraphStyle(bullet: b)), width: 300).bullet }
    let normal = bullet(.char("•", typeface: nil, color: nil, sizePercent: nil))
    let big = bullet(.char("•", typeface: nil, color: nil, sizePercent: 200))
    #expect(near(big?.rect.height ?? 0, 2 * (normal?.rect.height ?? 0), 0.1))
    #expect(bullet(.char("\u{A7}", typeface: "Wingdings", color: nil, sizePercent: nil))?.text == "\u{25AA}")
    #expect(bullet(.char("\u{F0A7}", typeface: "Wingdings", color: nil, sizePercent: nil))?.text == "\u{25AA}")
    let pic = bullet(.picture(id: 4, size: CGSize(width: 8, height: 9)))
    #expect(pic?.pictureID == 4 && pic?.text == nil)
    #expect(near(pic?.rect.width ?? 0, 8) && near(pic?.rect.height ?? 0, 9))
}

@Test func emptyParagraphHeightFromEndRunStyle() {
    let sp = setter.set(Paragraph(runs: [], endRunStyle: hv(40)), width: 200)
    #expect(sp.lines.count == 1)
    #expect(sp.lines.first?.range == 0..<0)
    #expect(near(sp.height, 48))
    #expect(sp.plainText.isEmpty)
    let withEmptyRun = Paragraph(runs: [Run(content: .text(""), style: hv(12))],
                                 style: ParagraphStyle(bullet: .char("•", typeface: nil, color: nil, sizePercent: nil)),
                                 endRunStyle: hv(40))
    let sp2 = setter.set(withEmptyRun, width: 200)
    #expect(near(sp2.height, 48))
    #expect(sp2.bullet == nil)
}

// MARK: alignment

@Test func justifyStretchesAllButLastLine() {
    let sp = setter.set(text(long, style: ParagraphStyle(align: .justify)), width: 150)
    #expect(sp.lines.count >= 3)
    for l in sp.lines.dropLast() { #expect(near(l.width, 150, 0.5)) }
    #expect((sp.lines.last?.width ?? 150) < 149)

    let broken = setter.set(para([.text("short words"), .lineBreak, .text(long)], style: ParagraphStyle(align: .justify)),
                            width: 150)
    #expect(near(broken.lines[0].width, measure("short words"), 0.5))
}

@Test func centerAndRightAlignment() {
    let w = measure("Hallo")
    let c = setter.set(text("Hallo", style: ParagraphStyle(align: .center)), width: 300)
    #expect(near(c.lines[0].origin.x, (300 - w) / 2, 0.01))
    let r = setter.set(text("Hallo ", style: ParagraphStyle(align: .right, marginRight: 10)), width: 300)
    #expect(near(r.lines[0].origin.x + r.lines[0].width, 290, 0.01))
}

// MARK: caps

@Test func capsChangeDisplayOnly() {
    let all = Paragraph(runs: [Run(content: .text("straße"), style: RunStyle(typeface: "Helvetica", size: 12, caps: .all))])
    let sp = setter.set(all, width: 300)
    #expect(sp.plainText == "straße")
    #expect(abs((word(sp, at: 0)?.rect.width ?? 0) - measure("STRAßE")) <= 0.5)

    let small = Paragraph(runs: [Run(content: .text("Hallo"), style: RunStyle(typeface: "Helvetica", size: 12, caps: .small))])
    let ssp = setter.set(small, width: 300)
    #expect(ssp.plainText == "Hallo")
    let w = word(ssp, at: 0)?.rect.width ?? 0
    #expect(w < measure("HALLO") - 1 && w > measure("Hallo") + 1)
}

// MARK: drawing

@Test func drawPutsInkAboveBaselineInYDownContext() {
    let sp = setter.set(Paragraph(runs: [Run(content: .text("HH"), style: hv(40))]), width: 200)
    let c = Canvas()
    let before = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 1, ty: 1)
    c.ctx.textMatrix = before
    sp.draw(lines: 0..<1, in: c.ctx, at: CGPoint(x: 10, y: 5), fonts: fonts)
    #expect(c.ctx.textMatrix == before)
    let base = Int((5 + sp.lines[0].origin.y).rounded())
    let w = Int(measure("HH", size: 40))
    #expect(ink(c, x: 10..<(10 + w), y: (base - 26)..<(base - 2)) > 200)
    #expect(ink(c, x: 0..<200, y: (base + 2)..<100) == 0)
    #expect(ink(c, x: 0..<9, y: 0..<100) == 0)
    #expect(ink(c, x: 0..<200, y: 0..<(base - 31)) == 0)
}

@Test func drawUnderlineHighlightStrike() {
    let yellow = RGBA(r: 1, g: 1, b: 0)
    let st = RunStyle(typeface: "Helvetica", size: 40, underline: .single, strike: true, highlight: yellow)
    let sp = setter.set(Paragraph(runs: [Run(content: .text("a    a"), style: st)]), width: 200)
    let c = Canvas()
    sp.draw(lines: 0..<1, in: c.ctx, at: .zero, fonts: fonts)
    let line = sp.lines[0]
    let base = Int(line.origin.y.rounded())
    let gap = Int(((word(sp, at: 0)?.rect.maxX ?? 0) + 10).rounded())
    // Highlight above the glyphs, inside the line box.
    #expect(c.matches(gap, Int((line.origin.y - line.ascent + 2).rounded()), 255, 255, 0))
    // Underline just below the baseline, strike at about half the x-height, across the spaces.
    #expect(hasDark(c, x: gap, y: (base + 1)..<(base + 7)))
    #expect(hasDark(c, x: gap, y: (base - 15)..<(base - 6)))
    // Without decorations the same spot stays highlight-yellow / clear.
    #expect(!hasDark(c, x: gap, y: (base - 30)..<(base - 20)))
}

private func hasDark(_ c: Canvas, x: Int, y: Range<Int>) -> Bool {
    y.contains { let p = c.pixel(x, $0); return p.a > 200 && p.r < 100 && p.g < 100 && p.b < 100 }
}

@Test func drawLineRangePlacesTopAtOrigin() {
    let sp = setter.set(para([.text("HH"), .lineBreak, .text("HH")], size: 30), width: 200)
    #expect(sp.lines.count == 2)
    let c = Canvas()
    sp.draw(lines: 1..<2, in: c.ctx, at: .zero, fonts: fonts)
    let h = Int(sp.lines[1].height.rounded(.up))
    #expect(ink(c, x: 0..<200, y: 0..<h) > 100)
    #expect(ink(c, x: 0..<200, y: (h + 1)..<100) == 0)
    // Out-of-range line ranges draw nothing and do not trap.
    sp.draw(lines: 5..<9, in: c.ctx, at: .zero, fonts: fonts)
    #expect(sp.wordRects(lines: 7..<9).isEmpty)
}

@Test func garbageInputDoesNotTrap() {
    let st = ParagraphStyle(marginLeft: .nan, marginRight: 1e9, indentFirst: -.infinity, lineSpacing: .multiple(.nan),
                            tabs: [TabStop(position: .nan), TabStop(position: -5)], defaultTab: 0)
    let p = Paragraph(runs: [Run(content: .text(long), style: RunStyle(size: .nan)),
                             Run(content: .inline(id: 1, size: CGSize(width: -3, height: CGFloat.infinity))), Run(content: .tab)],
                      style: st)
    let sp = setter.set(p, width: .nan, fontScale: -1, lineSpaceReduction: .nan, autoNumber: .min)
    #expect(!sp.lines.isEmpty)
    #expect(sp.height.isFinite)
    #expect(sp.plainText.hasPrefix("The quick"))
}

@Test func baselineShiftRaisesDrawnTextAndLineAscent() {
    let plain = setter.set(Paragraph(runs: [Run(content: .text("HH"), style: hv(40))]), width: 200)
    let st = RunStyle(typeface: "Helvetica", size: 40, baselineShift: 50)
    let sp = setter.set(Paragraph(runs: [Run(content: .text("HH"), style: st)]), width: 200)
    #expect(near(sp.lines[0].ascent, plain.lines[0].ascent + 20))
    let c = Canvas()
    sp.draw(lines: 0..<1, in: c.ctx, at: .zero, fonts: fonts)
    let base = Int(sp.lines[0].origin.y.rounded())
    #expect(ink(c, x: 0..<200, y: (base - 18)..<(base + 3)) == 0)
    #expect(ink(c, x: 0..<200, y: (base - 40)..<(base - 22)) > 100)
}

@Test func negativeMarginLeftIsNotClamped() {
    let out = setter.set(text(long, style: ParagraphStyle(marginLeft: -10, indentFirst: 0)), width: 150)
    #expect(out.lines.count >= 2)
    #expect(near(out.lines[0].origin.x, -10))
    #expect(near(out.lines[1].origin.x, -10))
    let hang = setter.set(text(long, style: ParagraphStyle(marginLeft: -5, indentFirst: -20)), width: 150)
    #expect(near(hang.lines[0].origin.x, -25))
    #expect(near(hang.lines[1].origin.x, -5))
    // Tabs stay absolute from x = 0.
    let tab = setter.set(para([.text("a"), .tab, .text("b")], style: ParagraphStyle(marginLeft: -10)), width: 300)
    #expect(near(word(tab, at: 2)?.rect.minX ?? -1, 72))
}

@Test func bulletOnEmptyParagraph() {
    let st = ParagraphStyle(bullet: .autoNumber(scheme: "arabicPeriod", startAt: 1, typeface: nil, color: nil, sizePercent: nil))
    let p = Paragraph(runs: [], style: st, endRunStyle: hv(40))
    #expect(setter.set(p, width: 200, autoNumber: 2).bullet == nil)
    let sp = setter.set(p, width: 200, autoNumber: 2, bulletOnEmpty: true)
    guard let b = sp.bullet else { Issue.record("no bullet"); return }
    #expect(b.text == "2.")
    #expect(sp.plainText.isEmpty)
    #expect(near(b.origin.y, sp.lines[0].origin.y))
    #expect(near(b.rect.height, sp.lines[0].ascent + sp.lines[0].descent, 0.5))
    #expect(near(sp.height, 48))
    let c = Canvas()
    sp.draw(lines: 0..<1, in: c.ctx, at: .zero, fonts: fonts)
    #expect(ink(c, x: 0..<Int(b.rect.maxX.rounded(.up)) + 1, y: 0..<100) > 10)
}

@Test func lineBreakSetsLineHeightOption() {
    let p = Paragraph(runs: [Run(content: .text("A"), style: hv(20)), Run(content: .lineBreak, style: hv(36)),
                             Run(content: .text("B"), style: hv(20))])
    let word = setter.set(p, width: 300)
    let ppt = ParagraphSetter(fonts: fonts, lineBreakSetsLineHeight: false).set(p, width: 300)
    #expect(near(word.lines[0].height, 36 * 1.2))
    #expect(near(ppt.lines[0].height, 20 * 1.2))
    #expect(near(ppt.lines[1].height, 20 * 1.2))
}

@Test func fontMetricsGrowLinesOption() {
    let avenir = RunStyle(typeface: "Avenir", size: 16)
    let p = Paragraph(runs: [Run(content: .text("A"), style: avenir)])
    let word = setter.set(p, width: 300)
    let ppt = ParagraphSetter(fonts: fonts, fontMetricsGrowLines: false).set(p, width: 300)
    #expect(word.lines[0].height > 19.2 + 0.5)
    #expect(near(ppt.lines[0].height, 19.2))
}

@Test func inlineObjectsGrowLinesWithoutFontMetrics() {
    let p = Paragraph(runs: [Run(content: .text("A"), style: hv(16)),
                             Run(content: .inline(id: 1, size: CGSize(width: 40, height: 50)), style: hv(16))])
    let ppt = ParagraphSetter(fonts: fonts, fontMetricsGrowLines: false).set(p, width: 300)
    #expect(ppt.lines[0].height >= 50)
}
