import Foundation

/// Runs a search against the index and groups the hit pages by document.
public struct SearchService: Sendable {
    private let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public func search(_ request: SearchRequest) async throws -> SearchResult {
        let terms = TextFolding.terms(of: request.text)
        guard !terms.isEmpty else { return .empty }
        let candidates = try await store.candidatePages(terms: terms, scope: request.scope, kinds: request.kinds)
        return SearchResult(documents: Self.group(candidates, terms: terms, sort: request.sort), terms: terms)
    }

    /// Every readable file without hits: the list shown while the search field is empty.
    /// The result has no terms; each document has an empty `pages` list.
    public func allFiles(scope: SearchScope = .everywhere, kinds: Set<FileKind> = Set(FileKind.allCases),
                         sort: SortOrder = .name) async throws -> SearchResult {
        let files = try await store.indexedFiles(scope: scope, kinds: kinds)
        let documents = files.map { file in
            DocumentHit(fileID: file.id, folderID: file.folderID, relativePath: file.relativePath, kind: file.kind,
                        modified: file.modified, pageCount: file.pageCount, pages: [])
        }
        return SearchResult(documents: Self.sorted(documents, by: sort), terms: [])
    }

    static func group(_ candidates: [CandidatePage], terms: [String], sort: SortOrder) -> [DocumentHit] {
        var pagesByFile: [Int64: [PageHit]] = [:]
        var firstByFile: [Int64: CandidatePage] = [:]
        for page in candidates {
            let count = terms.reduce(0) { $0 + TextFolding.occurrences(of: $1, in: page.body) }
            guard count > 0 else { continue }
            pagesByFile[page.fileID, default: []].append(PageHit(number: page.pageNumber, count: count))
            if firstByFile[page.fileID] == nil { firstByFile[page.fileID] = page }
        }
        let documents = firstByFile.values.map { first in
            DocumentHit(
                fileID: first.fileID,
                folderID: first.folderID,
                relativePath: first.relativePath,
                kind: first.kind,
                modified: first.modified,
                pageCount: first.pageCount,
                pages: (pagesByFile[first.fileID] ?? []).sorted { $0.number < $1.number }
            )
        }
        return sorted(documents, by: sort)
    }

    public static func sorted(_ documents: [DocumentHit], by order: SortOrder) -> [DocumentHit] {
        documents.sorted { a, b in
            func byName() -> Bool {
                let c = a.name.localizedStandardCompare(b.name)
                return c == .orderedSame ? a.fileID < b.fileID : c == .orderedAscending
            }
            switch order {
            case .hits:
                if a.totalHits != b.totalHits { return a.totalHits > b.totalHits }
                return byName()
            case .name:
                return byName()
            case .modified:
                if a.modified != b.modified { return a.modified > b.modified }
                return byName()
            }
        }
    }
}
