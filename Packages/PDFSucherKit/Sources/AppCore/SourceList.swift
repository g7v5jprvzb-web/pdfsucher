// SourceList.swift — 1.1 Task 1 (spec 1.1 §4 „Quellen“, „Überschneidungen“)
import Foundation
import IndexKit
import SearchKit

/// A source that was not added because a loaded folder already contains it.
public struct Containment: Equatable, Sendable {
    public let url: URL
    public let container: URL
}

/// What `SourceList.add` did.
public struct SourceAddResult: Equatable, Sendable {
    public var added: [LoadedSourceRef] = []
    /// Loaded sources inside a newly added folder; the folder replaces them.
    public var replaced: [LoadedSourceRef] = []
    public var alreadyContained: [Containment] = []
}

/// The loaded sources, in the order they were added. Paths are compared standardized and with symlinks
/// resolved; case is compared exactly (open panels and drops give the on-disk spelling). No file is reachable through two sources:
/// a source inside a loaded folder is not added, a folder replaces the loaded sources inside it.
public struct SourceList: Equatable, Sendable {
    public private(set) var items: [LoadedSourceRef] = []

    public init(_ items: [LoadedSourceRef] = []) {
        _ = add(items)
    }

    public mutating func add(_ candidates: [LoadedSourceRef]) -> SourceAddResult {
        var result = SourceAddResult()
        for candidate in candidates {
            let candidate = LoadedSourceRef(url: candidate.url, isFolder: candidate.isFolder)
            let path = Self.components(candidate.url)
            if items.contains(where: { Self.components($0.url) == path }) { continue }
            if let container = items.first(where: { $0.isFolder && Self.isPrefix(Self.components($0.url), of: path) }) {
                result.alreadyContained.append(Containment(url: candidate.url, container: container.url))
                continue
            }
            if candidate.isFolder {
                let inside = items.filter { Self.isPrefix(path, of: Self.components($0.url)) }
                items.removeAll { inside.contains($0) }
                // Added earlier in this same call: never loaded, so not „replaced“ either.
                let addedNow = inside.filter { result.added.contains($0) }
                result.added.removeAll { addedNow.contains($0) }
                result.replaced += inside.filter { !addedNow.contains($0) }
            }
            items.append(candidate)
            result.added.append(candidate)
        }
        return result
    }

    /// Removes the source at `url`; false if no such source is loaded.
    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        let path = Self.components(url)
        guard let i = items.firstIndex(where: { Self.components($0.url) == path }) else { return false }
        items.remove(at: i)
        return true
    }

    public mutating func removeAll() { items.removeAll() }

    /// Standardized, symlink-resolved path components (restored or directly added URLs bypass the classifier).
    static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    /// `prefix` is a proper ancestor of `path` (component-wise, so `/a` is not a prefix of `/ab`).
    static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count < path.count && Array(path.prefix(prefix.count)) == prefix
    }
}

/// Sorts opened or dropped URLs into sources (folders and PDFs, symlinks resolved) and ignored items.
public enum SourceClassifier {
    /// - Parameter includeImages: images (`DocumentKind.imageExtensions`) count as single-file sources (spec 1.2).
    public static func classify(_ urls: [URL], includeImages: Bool = true) -> (sources: [LoadedSourceRef], ignored: [URL]) {
        var sources: [LoadedSourceRef] = []
        var ignored: [URL] = []
        for url in urls {
            // A Finder alias leads to its original (drag and drop does not resolve it, the open panel does).
            let original = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
                ? (try? URL(resolvingAliasFileAt: url)) ?? url : url
            let resolved = original.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey])
            if values?.isDirectory == true, values?.isPackage != true {
                sources.append(LoadedSourceRef(url: URL(fileURLWithPath: resolved.path, isDirectory: true), isFolder: true))
            } else if values?.isRegularFile == true,
                      SupportedSourceTypes.accepts(fileExtension: resolved.pathExtension, includeImages: includeImages) {
                sources.append(LoadedSourceRef(url: URL(fileURLWithPath: resolved.path, isDirectory: false), isFolder: false))
            } else {
                ignored.append(url)
            }
        }
        return (sources, ignored)
    }
}
