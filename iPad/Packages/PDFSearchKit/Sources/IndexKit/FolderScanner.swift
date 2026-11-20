// FolderScanner.swift — Task 1.1
import Darwin
import Foundation

public enum FolderScannerError: Error, Equatable {
    case notADirectory(URL)
}

/// Result of a scan including the subdirectories that could not be listed.
public struct FolderScanResult: Sendable, Equatable {
    public let files: [ScannedFile]
    /// Logical relative paths (like `ScannedFile.relativePath`) whose contents are unknown:
    /// directories that could not be listed (permissions, I/O error) and symbolic links whose
    /// target is missing (e.g. an unmounted volume). Not the same as deleted.
    /// An empty string means the root itself could not be listed.
    public let unreachablePaths: [String]
}

/// Lists every `.pdf` file (extension case-insensitive) below a folder, and with
/// `includeImages` also every image file of `DocumentKind.imageExtensions` (spec 1.2 §2), and with
/// `includeOffice` Word and PowerPoint files (spec 1.3; `~$` lock files are always skipped).
///
/// - Depth: files directly in `root` are depth 0; at most `maxDepth` directory levels below
///   `root` are entered.
/// - Hidden items (dot files or the hidden flag) and packages (`.app`, …) are skipped.
/// - Symbolic links are resolved (`realpath`). A directory is entered at most once, keyed by
///   the file resource identifier of its resolved target, so link loops terminate. The walk is
///   breadth-first with names sorted, and at each level real directories claim their target
///   before symlinked ones: a directory reachable both directly and through a link is listed
///   under its shallowest path, preferring the real one, independent of listing order.
///   Files are not de-duplicated: a link to a pdf and the pdf itself are both listed.
/// - Broken links and unreadable subdirectories are skipped and reported in
///   `FolderScanResult.unreachablePaths`; an unreadable `root` throws.
/// - `relativePath` is the logical path below `root` (names as seen through links), NFC,
///   joined with `/`; `url` is `root` plus the on-disk names. Sorted by `relativePath`.
/// - Honours task cancellation (checked once per directory).
public struct FolderScanner: Sendable {
    private let maxDepth: Int
    private let includeImages: Bool
    private let includeOffice: Bool
    /// iPad: only these image extensions (lowercase); nil = every `SupportedSourceTypes.imageExtensions`.
    private let imageExtensions: Set<String>?

    /// `includeImages` is off by default so callers from before 1.2 keep listing PDFs only.
    /// `includeOffice` (Word/PowerPoint, spec 1.3) is off by default for the same reason.
    /// `imageExtensions` (iPad) narrows the images listed, e.g. to JPEG only.
    public init(maxDepth: Int = 10, includeImages: Bool = false, includeOffice: Bool = false, imageExtensions: Set<String>? = nil) {
        self.maxDepth = maxDepth
        self.includeImages = includeImages
        self.includeOffice = includeOffice
        self.imageExtensions = imageExtensions
    }

    /// The same scanner for a folder `depth` levels below the root of a full scan, so it reaches exactly as deep
    /// (1.4.0 P3: scans of the changed subfolders only); nil when the folder is already at the depth limit.
    public func scoped(depth: Int) -> FolderScanner? {
        guard maxDepth - depth >= 0 else { return nil }
        return FolderScanner(maxDepth: maxDepth - depth, includeImages: includeImages, includeOffice: includeOffice,
                      imageExtensions: imageExtensions)
    }

    private func isIndexed(_ name: String) -> Bool {
        // Office lock files (`~$name.docx`) are never documents (`SupportedSourceTypes`).
        guard SupportedSourceTypes.accepts(fileName: name, includeImages: includeImages, includeOffice: includeOffice) else { return false }
        guard let imageExtensions, SupportedSourceTypes.kind(forExtension: (name as NSString).pathExtension) == .image else { return true }
        return imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isRegularFileKey,
        .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .fileIdentifierKey,
    ]

    /// The volume of a folder, for `ScannedFile.fileID` (once per folder; a mount point is a folder).
    private static func volume(of dir: URL) -> String? {
        try? dir.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    public func scan(root: URL) throws -> [ScannedFile] {
        try scanDetailed(root: root).files
    }

    private struct Dir {
        let physical: URL
        let logical: URL
        let prefix: String
    }

    public func scanDetailed(root: URL) throws -> FolderScanResult {
        let rootURL = root.standardizedFileURL
        guard let resolvedRoot = Self.realURL(rootURL) else {
            // Let Foundation produce the descriptive error (e.g. no such file).
            _ = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
            throw FolderScannerError.notADirectory(root)
        }
        let values = try resolvedRoot.resourceValues(forKeys: Self.keys)
        guard values.isDirectory == true else { throw FolderScannerError.notADirectory(root) }
        // Root errors propagate.
        _ = try FileManager.default.contentsOfDirectory(at: resolvedRoot, includingPropertiesForKeys: nil)

        var visited = Set<NSObject>()
        if let id = values.fileResourceIdentifier as? NSObject { visited.insert(id) }
        var files: [ScannedFile] = []
        var unreadable: [String] = []
        var level = [Dir(physical: resolvedRoot, logical: rootURL, prefix: "")]
        var depth = 0

        while !level.isEmpty {
            var realDirs: [(Dir, NSObject)] = []
            var linkedDirs: [(Dir, NSObject)] = []
            for dir in level {
                if Task.isCancelled { throw CancellationError() }
                let volume = Self.volume(of: dir.physical)
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: dir.physical, includingPropertiesForKeys: Array(Self.keys), options: []) else {
                    unreadable.append(dir.prefix)
                    continue
                }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    if name.hasPrefix(".") { continue }
                    let nfcName = name.precomposedStringWithCanonicalMapping
                    let relativePath = dir.prefix.isEmpty ? nfcName : dir.prefix + "/" + nfcName
                    guard let own = try? child.resourceValues(forKeys: Self.keys) else {
                        unreadable.append(relativePath) // cannot tell what it is: keep its documents
                        continue
                    }
                    if own.isHidden == true { continue }

                    let values: URLResourceValues
                    var physical = child
                    let isLink = own.isSymbolicLink == true
                    if isLink {
                        guard let target = Self.realURL(child),
                              let tv = try? target.resourceValues(forKeys: Self.keys) else {
                            unreadable.append(relativePath)
                            continue
                        }
                        values = tv
                        physical = target
                    } else {
                        values = own
                    }
                    let logical = dir.logical.appendingPathComponent(name, isDirectory: values.isDirectory == true)

                    if values.isDirectory == true {
                        guard values.isPackage != true, own.isPackage != true else { continue }
                        guard depth + 1 <= maxDepth else { continue }
                        guard let id = values.fileResourceIdentifier as? NSObject else { continue }
                        let entry = (Dir(physical: physical, logical: logical, prefix: relativePath), id)
                        if isLink { linkedDirs.append(entry) } else { realDirs.append(entry) }
                    } else if values.isRegularFile == true, isIndexed(name) {
                        // A linked file may lie on another volume: its own volume then.
                        let fileVolume = isLink ? Self.volume(of: physical.deletingLastPathComponent()) : volume
                        files.append(ScannedFile(
                            relativePath: relativePath,
                            url: logical,
                            fileSize: Int64(values.fileSize ?? 0),
                            modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                            fileID: fileVolume.flatMap { v in values.fileIdentifier.map { "\(v)/\($0)" } }))
                    }
                }
            }
            // Real directories claim their target before links at the same depth.
            level = []
            for (dir, id) in realDirs + linkedDirs where visited.insert(id).inserted {
                level.append(dir)
            }
            depth += 1
        }
        files.sort { $0.relativePath < $1.relativePath }
        return FolderScanResult(files: files, unreachablePaths: unreadable.sorted())
    }

    /// Fully resolved path via `realpath(3)`, or nil for a broken link / missing item.
    /// (`URL.resolvingSymlinksInPath` strips `/private` and so leaves `/tmp` as a link.)
    private static func realURL(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
