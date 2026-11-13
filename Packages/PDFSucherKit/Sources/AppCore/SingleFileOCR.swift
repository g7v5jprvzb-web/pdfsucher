// SingleFileOCR.swift — 1.2 Task 3 (spec 1.2 §2: images and scanned PDFs as single sources)
import Foundation
import IndexKit
import OCRKit
import OutputKit
import SearchKit

/// Page texts of one single-file source: the PDF text layer with recognized pages laid over it, or the
/// recognized text of an image (one page). Recognized pages are kept in memory for the session.
/// Identifies one version of a file (recognized text belongs to the version it was made from).
struct FileStamp: Equatable, Sendable {
    let modifiedAt: Date?
    let size: Int?

    static func of(_ url: URL) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(modifiedAt: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.intValue)
    }
}

struct OverlayTextSource: TextSource {
    let isImage: Bool
    let recognized: [Int: OCRPageText]
    /// The file version `recognized` belongs to; a changed file uses its own text only.
    var stamp: FileStamp?
    private let base = PDFKitTextSource()

    init(isImage: Bool, recognized: [Int: OCRPageText], stamp: FileStamp? = nil) {
        self.isImage = isImage
        self.recognized = recognized
        self.stamp = stamp
    }

    func pages(of url: URL) throws -> [PageText] {
        let recognized = stamp == nil || FileStamp.of(url) == stamp ? self.recognized : [:]
        if isImage {
            guard ImagePages.isReadable(url) else { throw TextSourceError.unreadable(url) }
            return [PageText(pageIndex: 0, text: recognized[0]?.text ?? "")]
        }
        return try base.pages(of: url).map { page in
            guard let ocr = recognized[page.pageIndex] else { return page }
            return PageText(pageIndex: page.pageIndex, text: ocr.text)
        }
    }
}

/// What a single file still needs recognized, and the recognition of one page (off the main actor).
enum SingleFileOCR {
    /// Pages without text (fewer than `OCRPolicy.minimumTextLength` characters); an image is page 0.
    /// Throws for an unreadable file.
    static func pagesToRecognize(_ url: URL, isImage: Bool) throws -> [Int] {
        if isImage {
            guard ImagePages.isReadable(url) else { throw TextSourceError.unreadable(url) }
            return [0]
        }
        return try PDFKitTextSource().pages(of: url)
            .filter { $0.text.count < OCRPolicy.minimumTextLength }
            .map(\.pageIndex)
    }

    static func recognize(_ url: URL, pageIndex: Int, isImage: Bool, source: any OCRSource = VisionOCRSource()) throws -> OCRPageText {
        let result = try source.recognize(pageIndex: pageIndex, of: url, kind: isImage ? .image : .pdf)
        return OCRPageText(text: result.text, words: result.words)
    }

    /// `recognize` on a new utility thread (like the Indexer's phase 2): Vision blocks for up to a second
    /// per page and must not hold a thread of the cooperative pool.
    static func recognizeOnThread(_ url: URL, pageIndex: Int, isImage: Bool,
                                  source: any OCRSource = VisionOCRSource()) async throws -> OCRPageText {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try recognize(url, pageIndex: pageIndex, isImage: isImage, source: source) })
            }
            thread.qualityOfService = .utility
            thread.name = "PDFSucher OCR"
            thread.start()
        }
    }
}
