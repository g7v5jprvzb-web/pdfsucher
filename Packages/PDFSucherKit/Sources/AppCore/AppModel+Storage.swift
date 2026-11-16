// AppModel+Storage.swift — settings „Speicher“: sizes and deleting of indexes and caches (1.3.10)
import Foundation
import IndexKit
import SearchKit

/// Index files on disk: their size and the ones no source uses any more.
public enum IndexFiles {
    /// `<64 hex digits>.sqlite` plus its `-wal`, `-shm` and `-journal` files (`IndexStore.location(forFolder:)`).
    static func indexPath(ofFile name: String) -> String? {
        let suffixes = [".sqlite", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal"]
        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }) else { return nil }
        let stem = name.dropLast(suffix.count)
        guard stem.count == 64, stem.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return stem + ".sqlite"
    }

    /// Bytes of an index file with its `-wal` and `-shm` files.
    public static func bytes(ofIndex file: URL) -> Int {
        [file.path, file.path + "-wal", file.path + "-shm"].reduce(0) { sum, path in
            sum + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0)
        }
    }

    /// Files of `directory` that belong to an index file not in `keeping` (standardized paths of `.sqlite` files).
    /// Only names of the index form count: any other file in the folder is never listed.
    public static func orphans(in directory: URL, keeping: Set<String>) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard let index = indexPath(ofFile: name),
                  !keeping.contains(directory.appendingPathComponent(index, isDirectory: false).standardizedFileURL.path)
            else { return nil }
            return directory.appendingPathComponent(name, isDirectory: false)
        }
    }

    public static func size(of files: [URL]) -> Int {
        files.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0) }
    }
}

extension AppModel {
    /// Size of the index of one folder source or (nil) of all of them, with `-wal` and `-shm`.
    public func indexBytes(for source: URL?) async -> Int {
        let path = source.map { LoadedSourceRef(url: $0, isFolder: true).url.path }
        let files = folderSources.compactMap { url -> URL? in
            guard path == nil || path == url.path else { return nil }
            return indexes[url.path]?.indexFileURL
        }
        return await Task.detached(priority: .utility) { files.reduce(0) { $0 + IndexFiles.bytes(ofIndex: $1) } }.value
    }

    /// Index files of folders that are neither loaded nor remembered as missing, and not open in this process.
    public func orphanIndexFiles() async -> [URL] {
        guard let directory = indexDirectory else { return [] }
        let keep = keptIndexFiles()
        return await Task.detached(priority: .utility) { IndexFiles.orphans(in: directory, keeping: keep) }.value
    }

    /// „Verwaiste Indexe löschen“: computes them again now and deletes them. Returns how many files went.
    @discardableResult
    public func deleteOrphanIndexes() async -> Int {
        guard let directory = indexDirectory else { return 0 }
        let keep = keptIndexFiles()
        let failed = await Task.detached(priority: .userInitiated) { () -> (Int, Error?) in
            var removed = 0
            var first: Error?
            for url in IndexFiles.orphans(in: directory, keeping: keep) {
                do { try FileManager.default.removeItem(at: url); removed += 1 } catch { first = first ?? error }
            }
            return (removed, first)
        }.value
        if let error = failed.1 {
            alertMessage = "Verwaiste Indexe konnten nicht alle gelöscht werden: \(error.localizedDescription)"
        }
        return failed.0
    }

    /// The index files of loaded and remembered sources and every index open in this process.
    func keptIndexFiles() -> Set<String> {
        var keep = FolderIndex.openIndexFiles()
        for path in sources.map(\.url.path) + rememberedMissing {
            let file = IndexStore.location(forFolder: URL(fileURLWithPath: path, isDirectory: true))
            // Same name inside `indexDirectory` (the app sets it to the folder of `location`, tests to a temp folder).
            let folder = indexDirectory ?? file.deletingLastPathComponent()
            keep.insert(folder.appendingPathComponent(file.lastPathComponent, isDirectory: false).standardizedFileURL.path)
        }
        for index in indexes.values {
            if let url = index.indexFileURL { keep.insert(url.standardizedFileURL.path) }
        }
        return keep
    }

    /// Size of the slide cache (Word/PowerPoint pictures of Quick Look).
    public func slideCacheBytes() async -> Int {
        let cache = slideCache
        return await Task.detached(priority: .utility) { cache.byteCount }.value
    }

    /// „Texterkennung neu ausführen“ for one folder source or (nil) all of them.
    public func rerunRecognition(forSource source: URL?) {
        let path = source.map { LoadedSourceRef(url: $0, isFolder: true).url.path }
        for url in folderSources where path == nil || path == url.path { rerunRecognition(for: url) }
    }
}
