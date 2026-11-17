import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum ExtractionError: Error, Sendable, Equatable {
    case cannotOpen
    case locked
    case cannotDecodeImage
}

/// Reads the text of one file, page by page. A protocol so tests can count or fake reads.
public protocol PageTextExtracting: Sendable {
    func pages(of file: ScannedFile) throws -> [String]
}

/// PDF text via PDFKit; scanned PDF pages and JPEGs via on-device text recognition (Vision).
public struct DefaultTextExtractor: PageTextExtracting {
    /// Pages with less text than this are treated as scans and recognized.
    public var minimumTextLength = 12
    public var recognizesScannedPages = true

    public init() {}

    public func pages(of file: ScannedFile) throws -> [String] {
        switch file.kind {
        case .pdf: try pdfPages(at: file.url)
        case .jpeg: [try OCR.text(in: ImageLoading.cgImage(at: file.url, maxPixelSize: 3000))]
        }
    }

    func pdfPages(at url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.cannotOpen }
        if document.isLocked { throw ExtractionError.locked }
        var result: [String] = []
        result.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { result.append(""); continue }
            let text = page.string ?? ""
            if recognizesScannedPages,
               text.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumTextLength,
               let image = PageRendering.cgImage(of: page, maxPixelSize: 2200),
               let recognized = try? OCR.text(in: image) {
                result.append(recognized.count > text.count ? recognized : text)
            } else {
                result.append(text)
            }
        }
        return result
    }
}

/// On-device text recognition.
public enum OCR {
    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        return request
    }

    static func observations(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Recognized lines, top to bottom, joined with line breaks.
    public static func text(in image: CGImage) throws -> String {
        try observations(in: image)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// Where a search term was found in a photo.
public struct ImageTextMatch: Sendable, Equatable {
    /// Normalized rectangle (0…1), origin at the TOP left (ready for SwiftUI overlays).
    public let rect: CGRect
    /// The recognized line that contains the term.
    public let line: String
}

public struct ImageTextAnalysis: Sendable, Equatable {
    public let matches: [ImageTextMatch]
    /// All recognized lines.
    public let lines: [String]

    public init(matches: [ImageTextMatch], lines: [String]) {
        self.matches = matches
        self.lines = lines
    }
}

/// Finds the boxes of search terms in an image, for highlighting a JPEG hit.
public enum ImageTextLocator {
    public static func analyze(_ image: CGImage, terms: [String]) throws -> ImageTextAnalysis {
        var matches: [ImageTextMatch] = []
        var lines: [String] = []
        for observation in try OCR.observations(in: image) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            lines.append(line)
            for term in terms where !term.isEmpty {
                var searchRange = line.startIndex..<line.endIndex
                while let found = line.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                    if let box = try? candidate.boundingBox(for: found)?.boundingBox {
                        // Vision: origin bottom left. Flip to top left.
                        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                        matches.append(ImageTextMatch(rect: rect, line: line))
                    }
                    searchRange = found.upperBound..<line.endIndex
                }
            }
        }
        return ImageTextAnalysis(matches: matches, lines: lines)
    }
}

/// Loads images downsampled and upright.
public enum ImageLoading {
    public static func cgImage(at url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ExtractionError.cannotDecodeImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExtractionError.cannotDecodeImage
        }
        return image
    }
}

/// Renders a PDF page to a bitmap (white background, page rotation applied).
public enum PageRendering {
    public static func cgImage(of page: PDFPage, maxPixelSize: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longSide = max(bounds.width, bounds.height)
        let scale = min(maxPixelSize / longSide, 4)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        #if canImport(UIKit)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}
