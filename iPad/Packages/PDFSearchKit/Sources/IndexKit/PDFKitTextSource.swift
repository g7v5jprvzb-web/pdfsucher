// PDFKitTextSource.swift — Task 1.2
import Foundation
import PDFKit

public enum TextSourceError: Error, Equatable {
    case unreadable(URL)
    case locked(URL)
}

/// Reads the text layer of every page with PDFKit (`PDFPage.string`) and normalizes it with
/// `TextNormalizer`. A file PDFKit cannot open, or one with no pages, is `.unreadable`;
/// a file that needs a password to open is `.locked`. (A PDF with only an owner password
/// opens without one and is read normally.)
/// Each call opens its own `PDFDocument`, so concurrent calls on different files are fine.
/// Throws `CancellationError` between pages when the calling task is cancelled.
public struct PDFKitTextSource: TextSource {
    public init() {}

    public func pages(of url: URL) throws -> [PageText] {
        try autoreleasepool {
            guard let document = PDFDocument(url: url) else { throw TextSourceError.unreadable(url) }
            if document.isLocked, !document.unlock(withPassword: "") {
                throw TextSourceError.locked(url)
            }
            let count = document.pageCount
            guard count > 0 else { throw TextSourceError.unreadable(url) }
            var result: [PageText] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                // Long documents: let a cancelled indexing run stop between pages.
                if Task.isCancelled { throw CancellationError() }
                let text: String = autoreleasepool {
                    TextNormalizer.normalize(document.page(at: index)?.string ?? "")
                }
                result.append(PageText(pageIndex: index, text: text))
            }
            return result
        }
    }
}
