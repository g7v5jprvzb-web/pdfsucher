import Foundation

/// A PDF or JPEG found while walking a folder.
public struct ScannedFile: Sendable, Hashable {
    /// The real file's URL (for a cloud placeholder: where the file appears once downloaded).
    public let url: URL
    public let relativePath: String
    public let kind: FileKind
    public let size: Int64
    public let modified: Double
    /// False for cloud placeholders that are not on the device.
    public let isDownloaded: Bool

    public var entry: FileEntry {
        FileEntry(relativePath: relativePath, kind: kind, size: size, modified: modified)
    }
}

/// Walks a picked folder and its subfolders (up to `maxDepth` levels) and lists PDFs and JPEGs.
public enum FolderScanner {
    public static let maxDepth = 10

    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]

    public static func scan(root: URL) -> [ScannedFile] {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                // Hidden folders (".Trash", ".git" …) are skipped, as is anything too deep.
                if name.hasPrefix(".") || enumerator.level >= maxDepth { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile ?? true else { continue }

            // iCloud Drive placeholders of not-yet-downloaded files can look like ".Name.pdf.icloud".
            var realURL = url
            var isPlaceholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
                isPlaceholder = true
            } else if name.hasPrefix(".") {
                continue
            }
            guard let kind = FileKind(pathExtension: realURL.pathExtension) else { continue }

            let status = values?.ubiquitousItemDownloadingStatus
            let isDownloaded = !isPlaceholder && (status == nil || status == .current || status == .downloaded)

            result.append(ScannedFile(
                url: realURL,
                relativePath: relativePath(of: realURL, rootComponents: rootComponents),
                kind: kind,
                size: Int64(values?.fileSize ?? 0),
                modified: (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970,
                isDownloaded: isDownloaded
            ))
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func relativePath(of url: URL, rootComponents: [String]) -> String {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents {
            return components.dropFirst(rootComponents.count).joined(separator: "/")
        }
        // Different spelling of the same root (e.g. /private/var vs /var): fall back to the tail
        // after the root folder's own name.
        if let rootName = rootComponents.last, let index = components.lastIndex(of: rootName), index + 1 < components.count {
            return components[(index + 1)...].joined(separator: "/")
        }
        return url.lastPathComponent
    }
}
