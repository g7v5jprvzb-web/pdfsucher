// HighlightBoxes.swift — OCR 1.2, package O2 (spec §5, §12)
import CoreGraphics
import Foundation
import IndexKit

/// Highlight rectangles for matches on an OCR page.
public enum HighlightBoxes {
    /// Rectangles (normalized 0…1, origin top left, like `OCRWord.box`) covering `ranges` of the stored
    /// page text. A range inside a word gives the matching horizontal slice of the word's box, its width
    /// proportional to the UTF-16 units covered; a range over several words gives one rectangle per word.
    /// Text between words (spaces, line breaks) has no box and is not highlighted.
    /// Order: ranges in the given order, within a range the words in the given order; exact duplicates
    /// (overlapping ranges) are dropped. Empty or `NSNotFound` ranges and empty words are ignored.
    public static func rects(for ranges: [NSRange], in words: [OCRWord]) -> [CGRect] {
        var result: [CGRect] = []
        var seen: Set<[CGFloat]> = []
        for range in ranges where range.location != NSNotFound && range.length > 0 {
            for word in words where word.range.location != NSNotFound && word.range.length > 0 {
                let overlap = NSIntersectionRange(range, word.range)
                guard overlap.length > 0 else { continue }
                let length = CGFloat(word.range.length)
                let start = CGFloat(overlap.location - word.range.location) / length
                let share = CGFloat(overlap.length) / length
                let box = word.box
                let rect = CGRect(x: box.minX + box.width * start, y: box.minY,
                                  width: box.width * share, height: box.height)
                if seen.insert([rect.minX, rect.minY, rect.width, rect.height]).inserted {
                    result.append(rect)
                }
            }
        }
        return result
    }
}
