// SearchService.swift — Task 2.3
import Foundation
import IndexKit
import os

/// Runs a parsed query against the index: FTS5 (or a full scan) yields candidate
/// pages, `PageMatcher` verifies and counts each one, pages are grouped per document.
///
/// What this relies on from `IndexReading` (Phase 1 `IndexStore`):
/// - `match` returns every matching page (no LIMIT), for documents of any status;
///   status filtering happens here, against `documents()`.
/// - `bm25` is FTS5's raw value: smaller (more negative) = more relevant, 0 for `allPages`.
/// - `text` is the stored, normalized page text, the same text FTS5 indexed; matching
///   and counting run on it (highlights on the live PDF page are mapped elsewhere).
/// - `match` and `documents()` are separate reads: a document re-indexed in between
///   can be missing from one result, which the next search corrects.
/// - A rejected FTS query (`SQLiteError`) falls back to a full scan; other errors are thrown.
public struct SearchService: Sendable {
    private static let log = Logger(subsystem: "local.pdfsucher", category: "search")

    private let index: any IndexReading
    private let root: URL

    public init(index: any IndexReading, root: URL) {
        self.index = index
        self.root = root
    }

    /// Candidate pages read before the first early result (spec 1.1 §5): a few thousand pages take some
    /// 10–30 ms to read and check, so even a search hitting nearly every page shows rows at once.
    public static let defaultBatchSize = 3_000

    /// - Parameter onPartial: called at most once, during the search, with the documents of the first
    ///   `batchSize` candidate pages that are complete (sorted by `sort`), when more candidates follow.
    ///   They are a subset of the final result, with the same page hits.
    public func search(_ q: ParsedQuery, sort: SortMode, batchSize: Int = SearchService.defaultBatchSize,
                       onPartial: (([DocumentHit]) -> Void)? = nil) throws -> [DocumentHit] {
        guard let plan = FTSQueryBuilder.plan(for: q) else { return [] }
        var documents: [Int64: StoredDocument] = [:]
        for doc in try index.documents() where doc.status == .ok {
            documents[doc.id] = doc
        }
        let matcher = PageMatcher(q)
        var verified: [(RawPageMatch, Int)] = []
        var pending: [RawPageMatch] = []
        var reported = false
        // Each full batch until the first early result: check the complete documents so far (the last one
        // may continue) and report them once there is at least one hit (retried batch by batch).
        let consume = { (batch: [RawPageMatch]) -> Bool in
            pending += batch.filter { documents[$0.docId] != nil }
            if !reported, let onPartial, batch.count == batchSize, let lastDoc = batch.last?.docId {
                let complete = pending.filter { $0.docId != lastDoc }
                pending.removeAll { $0.docId != lastDoc }
                verified += Self.check(complete, with: matcher)
                let early = hits(from: verified, documents: documents)
                if !early.isEmpty {
                    reported = true
                    onPartial(sortHits(early, by: sort))
                }
            }
            return !Task.isCancelled
        }
        switch plan {
        case .fts(let query, let table):
            do {
                try index.matchBatches(query, in: table, batchSize: batchSize, consume)
            } catch is SQLiteError {
                // FTSQueryBuilder only emits quoted terms, so this should never happen. If the
                // index still rejects the query, a full scan gives the same (verified) result.
                Self.log.error("FTS query rejected, scanning all pages: \(query, privacy: .private)")
                verified = []
                pending = []
                try index.allPagesBatches(batchSize: batchSize, consume)
            }
        case .scanAll:
            try index.allPagesBatches(batchSize: batchSize, consume)
        }
        if Task.isCancelled { throw CancellationError() }
        verified += Self.check(pending, with: matcher)
        return sortHits(hits(from: verified, documents: documents), by: sort)
    }

    /// Verified pages grouped into one hit per document.
    private func hits(from checked: [(RawPageMatch, Int)], documents: [Int64: StoredDocument]) -> [DocumentHit] {
        var pages: [Int64: [Int: (count: Int, bm25: Double)]] = [:]
        for (page, count) in checked {
            pages[page.docId, default: [:]][page.pageIndex] = (count, page.bm25)
        }
        return pages.compactMap { docId, byPage -> DocumentHit? in
            guard let doc = documents[docId] else { return nil }
            let pageHits = byPage.keys.sorted().map { PageHit(pageIndex: $0, matchCount: byPage[$0]!.count) }
            return DocumentHit(
                url: root.appendingPathComponent(doc.relativePath, isDirectory: false),
                relativePath: doc.relativePath,
                modifiedAt: doc.modifiedAt,
                pageHits: pageHits,
                totalMatches: pageHits.reduce(0) { $0 + $1.matchCount },
                relevance: -byPage.values.reduce(0) { $0 + $1.bm25 },
                sourceRoot: root,
                pageCount: doc.pageCount,
                isImage: doc.kind == .image)
        }
    }

    /// Verifies and counts every candidate page with the matcher, spread over all cores
    /// (this is where a broad query such as `ver*` spends its time).
    private static func check(_ candidates: [RawPageMatch], with matcher: PageMatcher) -> [(RawPageMatch, Int)] {
        let chunkSize = 64
        let chunks = (candidates.count + chunkSize - 1) / chunkSize
        let results = ChunkResults(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let slice = candidates[(c * chunkSize)..<min(candidates.count, (c + 1) * chunkSize)]
            results.set(c, slice.compactMap { page in matcher.matchCount(in: page.text).map { (page, $0) } })
        }
        return results.joined()
    }
}

/// Per-chunk results written from `concurrentPerform`; each slot is written once.
private final class ChunkResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[(RawPageMatch, Int)]]
    init(count: Int) { slots = Array(repeating: [], count: count) }
    func set(_ i: Int, _ value: [(RawPageMatch, Int)]) { lock.withLock { slots[i] = value } }
    func joined() -> [(RawPageMatch, Int)] { lock.withLock { slots.flatMap { $0 } } }
}
