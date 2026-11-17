import CoreGraphics
import Foundation
import IndexKit
@testable import OCRKit
import Testing
import TestSupport

@Suite("OCRRecognizer")
struct OCRRecognizerTests {
    let recognizer = OCRRecognizer()

    private func word(_ needle: String, in result: (text: String, words: [OCRWord])) -> OCRWord? {
        result.words.first { (result.text as NSString).substring(with: $0.range) == needle }
    }

    @Test func recognizesGermanUmlautWord() throws {
        let (image, _) = try OCRFixtures.textImage(["Das Prüfungsergebnis liegt vor"])
        let result = try recognizer.recognize(image)
        #expect(result.text.contains("Prüfungsergebnis"), "\(result.text)")
    }

    @Test func wordBoxCoversRenderedWord() throws {
        let (image, rects) = try OCRFixtures.textImage(["Das Prüfungsergebnis liegt vor", "zweite Zeile hier"])
        let result = try recognizer.recognize(image)
        for needle in ["Prüfungsergebnis", "Zeile"] {
            let expected = try #require(rects[needle])
            let found = try #require(word(needle, in: result), "\(needle) not a word of \(result.text)")
            // Tolerance 10 % of the image (spec 1.2 §10).
            #expect(abs(found.box.midX - expected.midX) < 0.1, "\(needle) \(found.box) vs \(expected)")
            // Lines are 0.1 apart: a tighter limit proves the word sits on the right line.
            #expect(abs(found.box.midY - expected.midY) < 0.03, "\(needle) \(found.box) vs \(expected)")
            #expect(abs(found.box.width - expected.width) < 0.1, "\(needle) \(found.box) vs \(expected)")
        }
    }

    @Test func textIsNormalized() throws {
        let (image, _) = try OCRFixtures.textImage(["erste Zeile", "zweite Zeile"])
        let result = try recognizer.recognize(image)
        #expect(!result.text.contains("\n"))
        #expect(Array(result.text.utf16) == Array(TextNormalizer.normalize(result.text).utf16))
        #expect(result.text.contains("erste Zeile zweite Zeile"), "\(result.text)")
    }

    @Test func wordRangesPointIntoText() throws {
        let (image, _) = try OCRFixtures.textImage(["Rechnung über 120 Euro", "fällig am Montag"])
        let result = try recognizer.recognize(image)
        let ns = result.text as NSString
        #expect(result.words.count >= 7)
        var previousEnd = 0
        for w in result.words {
            #expect(w.range.location >= previousEnd)
            #expect(w.range.location + w.range.length <= ns.length)
            let s = ns.substring(with: w.range)
            #expect(!s.isEmpty && !s.contains(" "), "\(s.debugDescription)")
            #expect(w.box.minX >= 0 && w.box.maxX <= 1 && w.box.minY >= 0 && w.box.maxY <= 1)
            previousEnd = w.range.location + w.range.length
        }
    }

    @Test func blankImageGivesEmptyText() throws {
        let (image, _) = try OCRFixtures.textImage([])
        let result = try recognizer.recognize(image)
        #expect(result.text.isEmpty)
        #expect(result.words.isEmpty)
    }

    @Test func tinyImageGivesNoTextOrThrows() throws {
        let (image, _) = try OCRFixtures.textImage([], size: CGSize(width: 2, height: 2), fontSize: 1)
        if let result = try? recognizer.recognize(image) {
            #expect(result.text.isEmpty && result.words.isEmpty)
        }
    }

    @Test func hyphenatedLineEndJoinsIntoOneSearchableWord() throws {
        let (image, _) = try OCRFixtures.textImage(["Der Kündigungs-", "frist beträgt drei Monate"])
        let result = try recognizer.recognize(image)
        #expect(result.text.contains("Kündigungsfrist"), "\(result.text)")
        let ns = result.text as NSString
        let parts = result.words.map { ns.substring(with: $0.range) }
        #expect(parts.contains("Kündigungs") && parts.contains("frist"), "\(parts)")
    }

    @Test func boxOutsideImageIsDropped() {
        #expect(OCRRecognizer.topLeft(CGRect(x: 1.2, y: 0.5, width: 0.1, height: 0.1)) == nil)
        #expect(OCRRecognizer.topLeft(CGRect(x: .nan, y: 0.5, width: 0.1, height: 0.1)) == nil)
        let clamped = OCRRecognizer.topLeft(CGRect(x: 0.9, y: 0.0, width: 0.2, height: 0.1))
        #expect(clamped.map { abs($0.width - 0.1) < 1e-9 && abs($0.minY - 0.9) < 1e-9 } == true)
    }
}
