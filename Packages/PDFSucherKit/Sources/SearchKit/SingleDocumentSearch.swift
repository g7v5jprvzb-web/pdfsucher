// SingleDocumentSearch.swift — Task 2.4
import Foundation
import IndexKit

public enum SingleDocumentSearchError: Error, Equatable {
    /// The PDF has no extractable text on any page (e.g. a scan). Not the same as
    /// "no matches": the UI shows the scan hint (spec §6).
    case noText(URL)
}

/// Searches one PDF without an index (spec §4.2 "Einzel-PDF-Modus"): text comes straight
/// from the `TextSource`, every page is checked with the same `PageMatcher` as the
/// index search, so both modes find and highlight exactly the same things.
///
/// The extracted text of the last document is kept while its modification date is
/// unchanged, so search-as-you-type does not re-read a large PDF on every keystroke.
/// Matching checks for Task cancellation between pages.
public struct SingleDocumentSearch: Sendable {
    private let source: any TextSource
    private let cache = PageCache()
    /// The kind of the document (spec 1.2 §5, 1.3 §8: symbol in the row header).
    private let kind: DocumentKind
    /// Laid out by the simplified renderer (spec 1.3: „vereinfacht“).
    private let isSimplified: Bool

    public init(source: any TextSource = PDFKitTextSource(), kind: DocumentKind = .pdf, isSimplified: Bool = false) {
        self.source = source
        self.kind = kind
        self.isSimplified = isSimplified
    }

    /// nil for an empty query or when nothing matches. Throws `SingleDocumentSearchError.noText`
    /// for a PDF without text (unless its name matches), `CancellationError` when the surrounding Task is
    /// cancelled, and passes on errors of the text source (unreadable or locked file).
    /// - Parameter searchNames: the file name (without extension) counts too (spec 1.3.2 §1).
    /// - Parameter nameWithExtension: the file name search includes the extension.
    public func search(url: URL, query: ParsedQuery, searchNames: Bool = false, nameWithExtension: Bool = false) throws -> DocumentHit? {
        guard !query.isEmpty else { return nil }
        // Not `url.resourceValues`: URL caches those, and a changed file would look unchanged.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let pages = try cache.pages(for: url, modifiedAt: modifiedAt) { try source.pages(of: url) }
        let matcher = PageMatcher(query)
        let nameMatch = searchNames
            && matcher.matchCount(in: DocumentHit.searchableName(of: url.lastPathComponent, withExtension: nameWithExtension)) != nil
        if pages.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) {
            guard nameMatch else { throw SingleDocumentSearchError.noText(url) }
            return hit(url, modifiedAt: modifiedAt, fileSize: fileSize, pageHits: [], pageCount: pages.count, nameMatch: true)
        }

        var pageHits: [PageHit] = []
        for page in pages {
            try Task.checkCancellation()
            if let count = matcher.matchCount(in: page.text) {
                pageHits.append(PageHit(pageIndex: page.pageIndex, matchCount: count))
            }
        }
        guard !pageHits.isEmpty || nameMatch else { return nil }
        pageHits.sort { $0.pageIndex < $1.pageIndex }
        return hit(url, modifiedAt: modifiedAt, fileSize: fileSize, pageHits: pageHits, pageCount: pages.count, nameMatch: nameMatch)
    }

    /// Whether the file name (without extension) matches `query` (spec 1.3.2 §1). For a file whose text cannot be
    /// read: the caller shows it by its name and still handles the error `search` threw.
    public static func nameMatches(_ url: URL, _ query: ParsedQuery, withExtension: Bool = false) -> Bool {
        !query.isEmpty
            && PageMatcher(query).matchCount(in: DocumentHit.searchableName(of: url.lastPathComponent, withExtension: withExtension)) != nil
    }

    private func hit(_ url: URL, modifiedAt: Date?, fileSize: Int64?, pageHits: [PageHit], pageCount: Int, nameMatch: Bool) -> DocumentHit {
        let total = pageHits.reduce(0) { $0 + $1.matchCount }
        return DocumentHit(
            url: url,
            relativePath: url.lastPathComponent,
            modifiedAt: modifiedAt ?? Date(timeIntervalSince1970: 0),
            pageHits: pageHits,
            totalMatches: total,
            relevance: Double(total),
            sourceRoot: url,
            pageCount: pageCount,
            kind: kind,
            isSimplified: isSimplified,
            nameMatch: nameMatch,
            fileSize: fileSize)
    }
}

/// Holds the pages of the most recently read document.
private final class PageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: (url: URL, modifiedAt: Date?)?
    private var pages: [PageText] = []

    func pages(for url: URL, modifiedAt: Date?, load: () throws -> [PageText]) throws -> [PageText] {
        if let cached = lock.withLock({ key.map { $0.url == url && $0.modifiedAt == modifiedAt } == true ? pages : nil }) {
            return cached
        }
        let loaded = try load()  // outside the lock: reading can take seconds
        lock.withLock {
            key = (url, modifiedAt)
            pages = loaded
        }
        return loaded
    }
}
