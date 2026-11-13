// PageSelection.swift — Task 0.3 (PageRef) / Task 3.1 (PageSelection)
import Foundation

public struct PageRef: Sendable, Hashable {
    public let url: URL
    public let pageIndex: Int

    public init(url: URL, pageIndex: Int) {
        self.url = url
        self.pageIndex = pageIndex
    }
}

/// The set of pages the user ticked, across documents and searches.
public struct PageSelection: Sendable, Equatable {
    private var refs: Set<PageRef> = []

    public init() {}

    public var count: Int { refs.count }

    public func contains(_ r: PageRef) -> Bool { refs.contains(r) }

    public mutating func toggle(_ r: PageRef) {
        if refs.remove(r) == nil { refs.insert(r) }
    }

    public mutating func clear() { refs.removeAll() }

    /// Unticks the given pages (pages not in the selection are ignored).
    public mutating func remove(_ pages: Set<PageRef>) { refs.subtract(pages) }

    /// Docs in the given order, unknown docs last by path, pages ascending.
    public func ordered(documentOrder: [URL]) -> [PageRef] {
        var rank: [URL: Int] = [:]
        for (i, url) in documentOrder.enumerated() where rank[url] == nil { rank[url] = i }
        return refs.sorted { l, r in
            if l.url != r.url {
                switch (rank[l.url], rank[r.url]) {
                case let (li?, ri?): return li < ri
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    // Finder-like order: "2.pdf" before "10.pdf", case-insensitive.
                    switch l.url.path.localizedStandardCompare(r.url.path) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame:
                        if l.url.absoluteString != r.url.absoluteString {
                            return l.url.absoluteString < r.url.absoluteString
                        }
                        // Different URL objects, identical spelling: fall through to page order.
                    }
                }
            }
            return l.pageIndex < r.pageIndex
        }
    }
}
