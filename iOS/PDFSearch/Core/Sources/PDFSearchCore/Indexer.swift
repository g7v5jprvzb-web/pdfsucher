import Foundation

public struct IndexProgress: Sendable, Hashable {
    public let folderID: Int64
    /// Files checked so far (including unchanged ones).
    public let processed: Int
    public let total: Int
    public let currentFile: String?

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
}

public struct IndexSummary: Sendable, Hashable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var notDownloaded = 0
    public var failed = 0
}

/// Brings the index of one folder up to date: new and changed files are read, deleted ones removed,
/// unchanged ones (same size and modification date) skipped. Cloud placeholders are recorded as
/// "not downloaded" without reading them.
public actor Indexer {
    private let store: IndexStore
    private let extractor: any PageTextExtracting

    public init(store: IndexStore, extractor: any PageTextExtracting = DefaultTextExtractor()) {
        self.store = store
        self.extractor = extractor
    }

    /// `root` must be accessible (security scope started by the caller). Cancellable between files.
    @discardableResult
    public func index(
        folderID: Int64,
        root: URL,
        progress: @Sendable (IndexProgress) -> Void = { _ in }
    ) async throws -> IndexSummary {
        var summary = IndexSummary()
        let scanned = FolderScanner.scan(root: root)
        try Task.checkCancellation()

        let existing = try await store.files(inFolder: folderID)
        var byPath: [String: StoredFile] = [:]
        for file in existing { byPath[file.relativePath] = file }

        let scannedPaths = Set(scanned.map(\.relativePath))
        let gone = existing.filter { !scannedPaths.contains($0.relativePath) }.map(\.id)
        try await store.removeFiles(ids: gone)
        summary.removed = gone.count

        progress(IndexProgress(folderID: folderID, processed: 0, total: scanned.count, currentFile: nil))
        for (index, file) in scanned.enumerated() {
            try Task.checkCancellation()
            let old = byPath[file.relativePath]
            defer {
                progress(IndexProgress(folderID: folderID, processed: index + 1, total: scanned.count, currentFile: file.relativePath))
            }

            if !file.isDownloaded {
                if let old, old.state == .indexed {
                    summary.unchanged += 1   // keep what was read while the file was on the device
                } else if old?.state != .notDownloaded {
                    try await store.store(file.entry, folderID: folderID, pages: [], state: .notDownloaded)
                    summary.notDownloaded += 1
                } else {
                    summary.notDownloaded += 1
                }
                continue
            }

            if let old, old.state != .notDownloaded, old.size == file.size, abs(old.modified - file.modified) < 0.001 {
                summary.unchanged += 1
                continue
            }

            do {
                let pages = try extractor.pages(of: file)
                try await store.store(file.entry, folderID: folderID, pages: pages, state: .indexed)
                if old == nil { summary.added += 1 } else { summary.updated += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await store.store(file.entry, folderID: folderID, pages: [], state: .failed)
                summary.failed += 1
            }
        }
        return summary
    }
}
