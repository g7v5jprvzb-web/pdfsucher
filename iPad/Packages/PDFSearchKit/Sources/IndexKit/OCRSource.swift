// OCRSource.swift — 1.2 OCR (O1): what the Indexer needs from text recognition.
import Foundation

/// Recognized text of one page or image: `text` normalized like stored page text, `words` with
/// UTF-16 ranges in `text` and boxes normalized 0…1, origin top left.
public struct OCRResult: Sendable, Equatable {
    public let text: String
    public let words: [OCRWord]

    public init(text: String, words: [OCRWord]) {
        self.text = text
        self.words = words
    }
}

public enum OCRSourceError: Error, Equatable {
    /// The file (or the page) cannot be read as an image: the document is marked `error`
    /// (spec 1.2 §8). Any other error counts as a passing failure and is retried next run.
    case unreadable(URL)
}

/// Text recognition for phase 2 (implemented with Vision in OCRKit). Called off the main
/// thread, at most two calls at once, each for one page; must be safe to call concurrently.
public protocol OCRSource: Sendable {
    /// Recognizes page `pageIndex` of the PDF at `url`, or the image at `url` (`pageIndex` 0).
    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult
}

public enum OCRPolicy {
    /// A PDF page whose normalized text has fewer characters counts as „ohne Text“ (spec 1.2 §2).
    public static let minimumTextLength = 20
}
