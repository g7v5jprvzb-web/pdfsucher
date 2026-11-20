// SearchService.swift — Task 2.3
import Foundation
import Synchronization
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
    private let metrics: IndexMetrics

    public init(index: any IndexReading, root: URL, metrics: IndexMetrics = .shared) {
        self.index = index
        self.root = root
        self.metrics = metrics
    }

    /// Candidate pages read before the first early result (spec 1.1 §5): a few thousand pages take some
    /// 10–30 ms to read and check, so even a search hitting nearly every page shows rows at once.
    public static let defaultBatchSize = 3_000

    /// - Parameter onPartial: called at most once, during the search, with the documents of the first
    ///   `batchSize` candidate pages that are complete (sorted by `sort`), when more candidates follow.
    ///   They are a subset of the final result, with the same page hits – except documents found by their name
    ///   alone so far (spec 1.3.2 §5: names go out with the first early rows), whose content hits may still follow.
    /// - Parameter searchNames: also the file names (spec 1.3.2 §1): a document matches by its name OR its content.
    /// - Parameter nameWithExtension: the file name search includes the extension.
    public func search(_ q: ParsedQuery, sort: SortMode, searchNames: Bool = false, nameWithExtension: Bool = false, batchSize: Int = SearchService.defaultBatchSize,
                       onPartial: (([DocumentHit]) -> Void)? = nil) throws -> [DocumentHit] {
        guard let plan = FTSQueryBuilder.plan(for: q) else { return [] }
        // 1.4.3: `search_source` in the measurement log (candidates = candidate pages read; db = reading them).
        let started = ContinuousClock.now
        var candidates = 0, checkTime = Duration.zero, consumeTime = Duration.zero, namesTime = Duration.zero
        var readTime = Duration.zero, firstPartialMs: Double?, hitCount: Int?
        // 1.5.0: per file type: candidate pages, hits; Office documents not laid out yet (no page text to search).
        var candidatesByKind: [String: Int] = [:], hitsByKind: [String: Int] = [:], officePending = 0
        var stored: [StoredDocument] = []
        var kinds: [Int64: String] = [:]
        defer {
            if metrics.isEnabled {
                var fields: [String: Any] = [
                    "source": IndexMetrics.hash(root), "candidates": candidates, "db_ms": IndexMetrics.ms(readTime - consumeTime),
                    "check_ms": IndexMetrics.ms(checkTime), "names_ms": IndexMetrics.ms(namesTime),
                    "total_ms": IndexMetrics.ms(since: started), "cancelled": hitCount == nil]
                if let hitCount { fields["hits"] = hitCount }
                if let firstPartialMs { fields["first_partial_ms"] = firstPartialMs }
                fields["candidates_by_kind"] = candidatesByKind
                fields["hits_by_kind"] = hitsByKind
                fields["documents"] = stored.count
                fields["office_pending"] = officePending
                metrics.log("search_source", fields)
            }
        }
        try Self.timed(&readTime) { stored = try index.documents() }
        if metrics.isEnabled {
            for doc in stored {
                kinds[doc.id] = doc.kind.rawValue
                if doc.kind.isOffice, doc.pageCount == 0, doc.status != .error { officePending += 1 }
            }
        }
        // Content only of readable documents; names of every document (Chris, 2026-11-14: unreadable, locked and
        // not yet read ones too, shown like when browsing).
        var documents: [Int64: StoredDocument] = [:]
        for doc in stored where doc.status == .ok {
            documents[doc.id] = doc
        }
        let matcher = PageMatcher(q)
        // Names first: a few milliseconds for 10,000 files, so they are in the first early rows too.
        var names: Set<Int64> = []
        if searchNames { Self.timed(&namesTime) { names = Self.nameMatches(stored, matcher: matcher, withExtension: nameWithExtension) } }
        let named = names.isEmpty ? [:] : Dictionary(stored.filter { names.contains($0.id) }.map { ($0.id, $0) }) { a, _ in a }
        let hits = { (checked: [(RawPageMatch, Int)]) in self.withNames(self.hits(from: checked, documents: documents), names, named) }
        var verified: [(RawPageMatch, Int)] = []
        var pending: [RawPageMatch] = []
        var reported = false
        // Each full batch until the first early result: check the complete documents so far (the last one
        // may continue) and report them once there is at least one hit (retried batch by batch).
        // After it, or without `onPartial`, every batch is checked as it comes: a page's hit count does not
        // depend on the rest of its document, so no candidate text outlives its batch (audit 2026-11-15:
        // `pending` used to collect every later batch, i.e. nearly the whole index for `*ab*` or `ver*`).
        let consume = { (batch: [RawPageMatch]) -> Bool in
            let consumeStart = ContinuousClock.now
            defer { consumeTime += ContinuousClock.now - consumeStart }
            candidates += batch.count
            if !kinds.isEmpty { for page in batch { candidatesByKind[kinds[page.docId] ?? "?", default: 0] += 1 } }
            pending += batch.filter { documents[$0.docId] != nil }
            if !reported, let onPartial {
                if batch.count == batchSize, let lastDoc = batch.last?.docId {
                    let complete = pending.filter { $0.docId != lastDoc }
                    pending.removeAll { $0.docId != lastDoc }
                    Self.timed(&checkTime) { verified += Self.check(complete, with: matcher) }
                    let early = hits(verified)
                    if !early.isEmpty {
                        reported = true
                        firstPartialMs = IndexMetrics.ms(since: started)
                        onPartial(sortHits(early, by: sort))
                    }
                }
            } else {
                Self.timed(&checkTime) { verified += Self.check(pending, with: matcher) }
                pending.removeAll(keepingCapacity: true)
            }
            return !Task.isCancelled
        }
        switch plan {
        case .fts(let query, let table):
            do {
                try Self.timed(&readTime) { try index.matchBatches(query, in: table, batchSize: batchSize, consume) }
            } catch is SQLiteError {
                // FTSQueryBuilder only emits quoted terms, so this should never happen. If the
                // index still rejects the query, a full scan gives the same (verified) result.
                Self.log.error("FTS query rejected, scanning all pages: \(query, privacy: .private)")
                verified = []
                pending = []
                try Self.timed(&readTime) { try index.allPagesBatches(batchSize: batchSize, consume) }
            }
        case .scanAll:
            try Self.timed(&readTime) { try index.allPagesBatches(batchSize: batchSize, consume) }
        }
        if Task.isCancelled { throw CancellationError() }
        Self.timed(&checkTime) { verified += Self.check(pending, with: matcher) }
        let result = sortHits(hits(verified), by: sort)
        hitCount = result.count
        if metrics.isEnabled { for hit in result { hitsByKind[hit.kind.rawValue, default: 0] += 1 } }
        return result
    }

    /// Runs `work`, adding its time to `duration`.
    private static func timed(_ duration: inout Duration, _ work: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        defer { duration += ContinuousClock.now - start }
        try work()
    }

    /// The ids of the documents whose file name (without extension) matches, checked on all cores.
    static func nameMatches(_ documents: [StoredDocument], matcher: PageMatcher, withExtension: Bool = false) -> Set<Int64> {
        let chunkSize = 256
        let chunks = (documents.count + chunkSize - 1) / chunkSize
        let found = Mutex<Set<Int64>>([])
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let slice = documents[(c * chunkSize)..<min(documents.count, (c + 1) * chunkSize)]
            let ids = slice.filter { matcher.matchCount(in: DocumentHit.searchableName(of: $0.relativePath, withExtension: withExtension)) != nil }.map(\.id)
            if !ids.isEmpty { found.withLock { $0.formUnion(ids) } }
        }
        return found.withLock { $0 }
    }

    /// Content hits marked where the name matches too, plus the documents whose name alone matches (no page
    /// hits, no matches, relevance 0: the relevance sort puts name hits first by `nameMatch`).
    private func withNames(_ content: [DocumentHit], _ names: Set<Int64>, _ documents: [Int64: StoredDocument]) -> [DocumentHit] {
        guard !names.isEmpty else { return content }
        var byPath: [String: Int64] = [:]
        for id in names { if let doc = documents[id] { byPath[doc.relativePath] = id } }
        var result = content.map { hit -> DocumentHit in
            byPath.removeValue(forKey: hit.relativePath) != nil ? hit.withNameMatch() : hit
        }
        for id in byPath.values {
            guard let doc = documents[id] else { continue }
            result.append(DocumentHit(url: root.appendingPathComponent(doc.relativePath, isDirectory: false), relativePath: doc.relativePath,
                                      modifiedAt: doc.modifiedAt, pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: root,
                                      pageCount: doc.status == .error ? 0 : doc.pageCount, isUnreadable: doc.status == .error,
                                      kind: doc.kind, isSimplified: doc.isSimplified, nameMatch: true, fileSize: doc.fileSize))
        }
        return result
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
                kind: doc.kind,
                isSimplified: doc.isSimplified,
                fileSize: doc.fileSize)
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
            // Only id, page and bm25 are needed from here on; dropping the text keeps verified pages small.
            results.set(c, slice.compactMap { page in
                matcher.matchCount(in: page.text).map {
                    (RawPageMatch(docId: page.docId, pageIndex: page.pageIndex, bm25: page.bm25, text: ""), $0)
                }
            })
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
