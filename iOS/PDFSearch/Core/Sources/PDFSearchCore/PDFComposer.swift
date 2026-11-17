import CoreGraphics
import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One page of the selection: a PDF page or a photo.
public struct ComposeItem: Sendable, Hashable {
    public let url: URL
    public let kind: FileKind
    /// 1-based; ignored for photos.
    public let pageNumber: Int

    public init(url: URL, kind: FileKind, pageNumber: Int) {
        self.url = url
        self.kind = kind
        self.pageNumber = pageNumber
    }
}

public enum ComposeError: Error, Sendable, Equatable {
    case nothingToWrite
    case writeFailed
}

/// Builds one PDF from selected PDF pages and photos (each photo becomes its own page).
public enum PDFComposer {
    public struct Outcome: Sendable, Hashable {
        public let pageCount: Int
        /// Items that could not be read (file gone, damaged …).
        public let skipped: Int
    }

    @discardableResult
    public static func compose(_ items: [ComposeItem], to destination: URL) throws -> Outcome {
        let output = PDFDocument()
        var documents: [URL: PDFDocument] = [:]
        var skipped = 0
        for item in items {
            switch item.kind {
            case .pdf:
                let source = documents[item.url] ?? PDFDocument(url: item.url)
                documents[item.url] = source
                guard let source, !source.isLocked,
                      let page = source.page(at: item.pageNumber - 1)?.copy() as? PDFPage else {
                    skipped += 1
                    continue
                }
                output.insert(page, at: output.pageCount)
            case .jpeg:
                guard let image = try? ImageLoading.cgImage(at: item.url, maxPixelSize: 3000),
                      let page = makePage(from: image) else {
                    skipped += 1
                    continue
                }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.pageCount > 0 else { throw ComposeError.nothingToWrite }
        try? FileManager.default.removeItem(at: destination)
        guard output.write(to: destination) else { throw ComposeError.writeFailed }
        return Outcome(pageCount: output.pageCount, skipped: skipped)
    }

    private static func makePage(from image: CGImage) -> PDFPage? {
        #if canImport(UIKit)
        return PDFPage(image: UIImage(cgImage: image))
        #elseif canImport(AppKit)
        return PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        #endif
    }

    /// A file name like "Vertrag – 6 Seiten.pdf" for the given search text.
    public static func suggestedFileName(searchText: String, pageCount: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = searchText.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Auswahl" : String(cleaned.prefix(60))
        let pages = pageCount == 1 ? "1 Seite" : "\(pageCount) Seiten"
        return "\(base) – \(pages).pdf"
    }
}
