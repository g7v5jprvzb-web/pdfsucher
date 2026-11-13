// SearchModels.swift — Task 0.3 (shared types)
import Foundation
import IndexKit

public struct PageHit: Sendable, Hashable {
    public let pageIndex: Int
    public let matchCount: Int

    public init(pageIndex: Int, matchCount: Int) {
        self.pageIndex = pageIndex
        self.matchCount = matchCount
    }
}

public struct DocumentHit: Sendable, Equatable, Identifiable {
    /// The full file path: unique across sources (spec 1.1 §4 „Eindeutigkeit“).
    public var id: String { url.path }
    public let url: URL
    public let relativePath: String
    public let modifiedAt: Date
    public let pageHits: [PageHit]          // ascending pageIndex
    public let totalMatches: Int
    public let relevance: Double            // higher = better
    /// The source this hit came from: the folder root, or the PDF itself for a single-PDF source.
    public let sourceRoot: URL
    /// Pages of the document; 0 = unknown.
    public let pageCount: Int
    /// The file could not be read (index status `error`): shown with „nicht lesbar“, without tiles.
    public let isUnreadable: Bool
    /// An image file (spec 1.2): one page, shown from the image, printed and saved as an A4 page.
    public let isImage: Bool

    public init(url: URL, relativePath: String, modifiedAt: Date, pageHits: [PageHit], totalMatches: Int, relevance: Double,
                sourceRoot: URL, pageCount: Int, isUnreadable: Bool = false, isImage: Bool = false) {
        self.url = url
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.pageHits = pageHits
        self.totalMatches = totalMatches
        self.relevance = relevance
        self.sourceRoot = sourceRoot
        self.pageCount = pageCount
        self.isUnreadable = isUnreadable
        self.isImage = isImage
    }
}

/// One loaded source (spec 1.1 §4): a folder (searched through its index) or a single PDF.
/// `url` is a standardized file URL (directory form for folders), however it was spelled, also after decoding.
public struct LoadedSourceRef: Hashable, Codable, Sendable {
    public let url: URL
    public let isFolder: Bool

    public init(url: URL, isFolder: Bool) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: isFolder)
        self.isFolder = isFolder
    }

    private enum CodingKeys: String, CodingKey { case url, isFolder }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try c.decode(URL.self, forKey: .url), isFolder: try c.decode(Bool.self, forKey: .isFolder))
    }
}

public enum SortMode: String, CaseIterable, Sendable {
    case matchCount, relevance, modifiedDate, fileName, folder
}

public enum QueryTerm: Sendable, Equatable {
    case word(String), prefix(String), suffix(String), infix(String), phrase([String])
}

public struct ParsedQuery: Sendable, Equatable {
    public let terms: [QueryTerm]
    public var isEmpty: Bool { terms.isEmpty }

    public init(terms: [QueryTerm]) {
        self.terms = terms
    }
}

/// Stored text and recognized word boxes of one OCR page (spec 1.2 §4/§5): highlights on scans and images
/// are drawn from these.
public struct OCRPageText: Sendable, Equatable {
    public let text: String
    public let words: [OCRWord]

    public init(text: String, words: [OCRWord]) {
        self.text = text
        self.words = words
    }
}
