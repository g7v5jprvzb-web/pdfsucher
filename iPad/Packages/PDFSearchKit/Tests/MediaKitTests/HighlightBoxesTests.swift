import CoreGraphics
import Foundation
import IndexKit
import MediaKit
import Testing

@Suite("HighlightBoxes")
struct HighlightBoxesTests {
    /// „Der Vertrag gilt“: words at 0..<3, 4..<11, 12..<16.
    let words = [
        OCRWord(range: NSRange(location: 0, length: 3), box: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.05)),
        OCRWord(range: NSRange(location: 4, length: 7), box: CGRect(x: 0.35, y: 0.2, width: 0.35, height: 0.05)),
        OCRWord(range: NSRange(location: 12, length: 4), box: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.05)),
    ]

    private func approx(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { l, r in
            abs(l.minX - r.minX) < 1e-9 && abs(l.minY - r.minY) < 1e-9
                && abs(l.width - r.width) < 1e-9 && abs(l.height - r.height) < 1e-9
        }
    }

    @Test func emptyInputs() {
        #expect(HighlightBoxes.rects(for: [], in: words).isEmpty)
        #expect(HighlightBoxes.rects(for: [NSRange(location: 0, length: 3)], in: []).isEmpty)
    }

    @Test func wholeWordGivesItsBox() {
        #expect(HighlightBoxes.rects(for: [NSRange(location: 4, length: 7)], in: words) == [words[1].box])
    }

    @Test func partOfWordIsProportional() {
        // *trag* in „Vertrag“: letters 3..<7 of 7 → x 0.35 + 0.35·3/7, width 0.35·4/7
        let r = HighlightBoxes.rects(for: [NSRange(location: 7, length: 4)], in: words)
        #expect(approx(r, [CGRect(x: 0.35 + 0.15, y: 0.2, width: 0.2, height: 0.05)]))
    }

    @Test func rangeOverSeveralWordsGivesOneRectPerWord() {
        // „Vertrag gi“ → whole „Vertrag“, first half of „gilt“ (on the next line)
        let r = HighlightBoxes.rects(for: [NSRange(location: 4, length: 10)], in: words)
        #expect(approx(r, [words[1].box, CGRect(x: 0.1, y: 0.3, width: 0.1, height: 0.05)]))
    }

    @Test func rangeOnlyOnSpaceGivesNothing() {
        #expect(HighlightBoxes.rects(for: [NSRange(location: 3, length: 1)], in: words).isEmpty)
    }

    @Test func rangePastTextEndIsClipped() {
        let r = HighlightBoxes.rects(for: [NSRange(location: 14, length: 50)], in: words)
        #expect(approx(r, [CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.05)]))
    }

    @Test func invalidRangesAndEmptyWordsAreIgnored() {
        let empty = OCRWord(range: NSRange(location: 5, length: 0), box: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = HighlightBoxes.rects(for: [NSRange(location: NSNotFound, length: 0), NSRange(location: 5, length: 0),
                                           NSRange(location: 4, length: 3)], in: [empty] + words)
        #expect(approx(r, [CGRect(x: 0.35, y: 0.2, width: 0.15, height: 0.05)]))
    }

    @Test func overlappingRangesGiveNoDuplicates() {
        let r = HighlightBoxes.rects(for: [NSRange(location: 4, length: 7), NSRange(location: 4, length: 7),
                                           NSRange(location: 0, length: 3)], in: words)
        #expect(r == [words[1].box, words[0].box])
    }

    @Test func orderFollowsRangesThenWords() {
        let r = HighlightBoxes.rects(for: [NSRange(location: 12, length: 4), NSRange(location: 0, length: 11)], in: words)
        #expect(r == [words[2].box, words[0].box, words[1].box])
    }
}
