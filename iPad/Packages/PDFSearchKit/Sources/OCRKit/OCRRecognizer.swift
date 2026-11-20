// OCRRecognizer.swift — 1.2 OCR (O1), spec §2, §12
import CoreGraphics
import Foundation
import IndexKit
import Vision

/// Recognizes text in an image with Apple Vision, locally (spec 1.2 §2: German and English,
/// accurate mode, language correction on).
///
/// API choice (R1, docs/decisions.md): the classic `VNRecognizeTextRequest` (revision 3). On
/// macOS 26 it returned the same text as `RecognizeTextRequest` and `RecognizeDocumentsRequest`
/// on all test images, was the fastest, and has a synchronous API that matches this type's
/// synchronous contract. A call blocks its thread for the whole recognition (0.1–1 s per
/// page), so callers must not run many of them on the cooperative pool; the `Indexer` runs at
/// most two, on their own threads.
///
/// Result: the recognized lines (in Vision's reading order) joined with line breaks and then
/// normalized with `TextNormalizer` exactly like PDF text, so `text` is what gets stored and
/// searched. `words` holds every whitespace-separated word of the raw lines whose characters
/// survive normalization, in text order: `range` is its UTF-16 range in `text`, `box` its
/// rectangle normalized to 0…1 with the origin top left. A word split by a hyphen at a line
/// end yields two adjacent entries (`Ver` and `trag` in `Vertrag`). Words are split where the
/// normalizer puts spaces (whitespace, control and private-use characters). A word whose box lies
/// completely outside the image is dropped.
///
/// Thread-safe: every call uses its own request.
public struct OCRRecognizer: Sendable {
    public static let languages = ["de-DE", "en-US"]

    public init() {}

    public func recognize(_ image: CGImage) throws -> (text: String, words: [OCRWord]) {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        var raw = ""
        var rawWords: [(range: NSRange, box: CGRect)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            if !raw.isEmpty { raw += "\n" }
            let lineStart = (raw as NSString).length
            raw += line
            let lineBox = observation.boundingBox
            let lineLength = max((line as NSString).length, 1)
            var index = line.startIndex
            while index < line.endIndex {
                guard !Self.isSeparator(line[index]) else { index = line.index(after: index); continue }
                var end = index
                while end < line.endIndex, !Self.isSeparator(line[end]) { end = line.index(after: end) }
                let local = NSRange(index..<end, in: line)
                let visionBox = (try? candidate.boundingBox(for: index..<end))?.boundingBox
                    ?? Self.slice(of: lineBox, from: local.location, length: local.length, of: lineLength)
                if let box = Self.topLeft(visionBox) {
                    rawWords.append((NSRange(location: lineStart + local.location, length: local.length), box))
                }
                index = end
            }
        }

        let mapped = TextNormalizer.normalizeMapped(raw)
        var words: [OCRWord] = []
        words.reserveCapacity(rawWords.count)
        for word in rawWords {
            let range = mapped.normalizedRange(forOriginal: word.range)
            guard range.length > 0 else { continue }
            words.append(OCRWord(range: range, box: word.box))
        }
        return (mapped.text, words)
    }

    /// Part of a line box proportional to the characters (used when Vision gives no word box).
    private static func slice(of line: CGRect, from start: Int, length: Int, of total: Int) -> CGRect {
        let unit = line.width / CGFloat(total)
        return CGRect(x: line.minX + unit * CGFloat(start), y: line.minY, width: unit * CGFloat(length), height: line.height)
    }

    /// Vision's normalized rectangle (origin bottom left) → origin top left, clamped to 0…1;
    /// nil when nothing of it lies inside the image (or it is not finite).
    static func topLeft(_ box: CGRect) -> CGRect? {
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite else { return nil }
        let flipped = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        let clamped = flipped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, !clamped.isEmpty else { return nil }
        return clamped.standardized
    }

    /// Where `TextNormalizer` puts a space: whitespace, control and private-use characters.
    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .privateUse
        }
    }
}
