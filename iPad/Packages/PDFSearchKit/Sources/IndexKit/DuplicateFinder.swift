// DuplicateFinder.swift — pdf-dubletten: byte-identical PDFs within one phase-1 run
import CryptoKit
import Foundation

extension Indexer {
    struct Duplicates: Sendable {
        /// Copy path → lead path (the first file with the same bytes in the given order).
        var copies: [String: String] = [:]
        /// Files hashed (PDFs whose size another PDF of the run shares).
        var hashed = 0
    }

    /// Finds PDFs among `files` with identical bytes (SHA-256). Only PDFs whose size another PDF shares are hashed, at most
    /// `limit` at once; a file that cannot be read is left out (it is then read normally). The lead of each group is the
    /// first of it in `files`. Throws `CancellationError` when cancelled.
    static func duplicateGroups(_ files: [ScannedFile], limit: Int) async throws -> Duplicates {
        let pdfs = files.filter { $0.kind == .pdf }
        var sizes: [Int64: Int] = [:]
        for file in pdfs { sizes[file.fileSize, default: 0] += 1 }
        let candidates = pdfs.filter { sizes[$0.fileSize, default: 0] > 1 }
        guard !candidates.isEmpty else { return Duplicates() }

        var digests: [String: Data] = [:]
        try await withThrowingTaskGroup(of: (String, Data?).self) { group in
            var queue = candidates.makeIterator()
            func add(_ file: ScannedFile) {
                group.addTask { (file.relativePath, try sha256(of: file.url)) }
            }
            for _ in 0..<max(1, limit) { guard let file = queue.next() else { break }; add(file) }
            while let (path, digest) = try await group.next() {
                if let digest { digests[path] = digest }
                if let file = queue.next() { add(file) }
            }
        }

        var result = Duplicates(hashed: candidates.count)
        var leads: [String: String] = [:]       // "size|digest" → lead path
        for file in candidates {
            guard let digest = digests[file.relativePath] else { continue }
            let key = "\(file.fileSize)|" + digest.base64EncodedString()
            if let lead = leads[key] { result.copies[file.relativePath] = lead } else { leads[key] = file.relativePath }
        }
        return result
    }

    /// SHA-256 of a file, read in 1 MiB blocks; nil if it cannot be read.
    static func sha256(of url: URL) throws -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let block: Data?
            do { block = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let block, !block.isEmpty else { break }     // nil or empty = end of file
            hasher.update(data: block)
        }
        return Data(hasher.finalize())
    }
}
