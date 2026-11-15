// FolderTree.swift — Ordnerleiste (spec 2026-11-13-pdfsucher-v1.2.5-folder-tree): pure model
import Foundation
import SearchKit

/// One folder of the „Quellen“ section, or the group „Einzelne Dateien“.
public struct FolderNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case folder, singleFiles }

    public let url: URL
    public let name: String
    /// Files in this folder and all folders below it.
    public var fileCount: Int
    public var children: [FolderNode]
    public let isSourceRoot: Bool
    public let kind: Kind

    public var id: String { kind == .singleFiles ? "pdfsucher.singleFiles" : url.path }
}

/// Builds the tree from the document list (the files shown when browsing), without reading the disk:
/// one root per loaded folder, its subfolders that hold files (directly or below), up to `maxDepth`
/// levels; single files under „Einzelne Dateien“.
public enum FolderTree {
    public static let maxDepth = 10
    public static let singleFilesTitle = "Einzelne Dateien"

    private final class Builder {
        let url: URL
        let name: String
        var count = 0
        var children: [String: Builder] = [:]
        init(url: URL, name: String) { self.url = url; self.name = name }

        func node(isRoot: Bool) -> FolderNode {
            let kids = children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return FolderNode(url: url, name: name, fileCount: count, children: kids.map { $0.node(isRoot: false) },
                              isSourceRoot: isRoot, kind: .folder)
        }
    }

    /// - Parameter counts: whether a file adds to the counts (the „Dateitypen“ filter). The folders that exist
    ///   come from all files, so a folder whose files are all hidden stays in the tree with 0.
    public static func build(sources: [LoadedSourceRef], files: [URL], counts: (URL) -> Bool = { _ in true }) -> [FolderNode] {
        let folders = sources.filter(\.isFolder).map { source -> (prefix: String, builder: Builder) in
            let path = source.url.standardizedFileURL.path
            return (path.hasSuffix("/") ? path : path + "/", Builder(url: source.url, name: source.url.lastPathComponent))
        }
        let singlePaths = Set(sources.filter { !$0.isFolder }.map { $0.url.standardizedFileURL.path })
        var singles = Set<String>()
        var countedSingles = Set<String>()
        for file in files {
            let path = file.standardizedFileURL.path
            let counted = counts(file)
            if singlePaths.contains(path) {
                singles.insert(path)
                if counted { countedSingles.insert(path) }
                continue
            }
            // The deepest source that contains it (sources do not overlap, 1.1 §4; deepest is the safe choice).
            guard let source = folders.filter({ path.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) else { continue }
            var node = source.builder
            if counted { node.count += 1 }
            let parts = path.dropFirst(source.prefix.count).split(separator: "/").dropLast()
            for part in parts.prefix(maxDepth) {
                let name = String(part)
                if let child = node.children[name] {
                    node = child
                } else {
                    let child = Builder(url: node.url.appendingPathComponent(name, isDirectory: true), name: name)
                    node.children[name] = child
                    node = child
                }
                if counted { node.count += 1 }
            }
        }
        var roots = folders.map { $0.builder.node(isRoot: true) }
        if !singles.isEmpty {
            roots.append(FolderNode(url: URL(fileURLWithPath: "/", isDirectory: true), name: singleFilesTitle, fileCount: countedSingles.count,
                                    children: [], isSourceRoot: false, kind: .singleFiles))
        }
        return roots
    }

    /// The node for `url` (a folder of the tree), with the names from its source root down to it.
    public static func path(to url: URL, in tree: [FolderNode]) -> [FolderNode]? {
        let target = url.standardizedFileURL.path
        func search(_ node: FolderNode, _ trail: [FolderNode]) -> [FolderNode]? {
            let trail = trail + [node]
            if node.kind == .folder, node.url.standardizedFileURL.path == target { return trail }
            for child in node.children {
                if target.hasPrefix(child.url.standardizedFileURL.path), let found = search(child, trail) { return found }
            }
            return nil
        }
        for root in tree where root.kind == .folder { if let found = search(root, []) { return found } }
        return nil
    }
}

/// A predicate on documents shown in the grid. Filters combine with AND (`DocumentFilters`); a file type
/// filter (PDF/Word/PowerPoint/Bilder) is added later next to the folder filter.
public protocol DocumentFilter: Sendable {
    func includes(_ hit: DocumentHit) -> Bool
    /// Text for the filter header, e.g. „Bilder“.
    var label: String { get }
}

/// The folders chosen in the folder bar (⌘-click: several). Empty = no filter.
public struct FolderFilter: Equatable, Sendable {
    public private(set) var folders: [URL] = []
    public private(set) var singleFiles: [URL] = []

    public init() {}

    public var isEmpty: Bool { folders.isEmpty && singleFiles.isEmpty }

    /// A click (`adding` false: only this one) or ⌘-click (`adding` true: toggled in the selection).
    public mutating func select(_ folder: URL, adding: Bool) {
        let folder = folder.standardizedFileURL
        if !adding {
            folders = [folder]
            singleFiles = []
        } else if let i = folders.firstIndex(of: folder) {
            folders.remove(at: i)
        } else {
            folders.append(folder)
        }
    }

    /// The group „Einzelne Dateien“ (its files).
    public mutating func selectSingleFiles(_ files: [URL], adding: Bool) {
        let files = files.map(\.standardizedFileURL)
        if !adding { folders = []; singleFiles = files }
        else if singleFiles == files { singleFiles = [] }
        else { singleFiles = files }
    }

    public mutating func clear() { folders = []; singleFiles = [] }

    /// Drops chosen single files that are no longer loaded (paths in `loaded`); folders stay.
    public mutating func keepSingleFiles(_ loaded: Set<String>) {
        singleFiles.removeAll { !loaded.contains($0.path) }
    }

    public func includes(_ url: URL) -> Bool {
        guard !isEmpty else { return true }
        let path = url.standardizedFileURL.path
        if singleFiles.contains(where: { $0.path == path }) { return true }
        return folders.contains { folder in
            let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            return path.hasPrefix(root)
        }
    }

    public func apply(_ hits: [DocumentHit]) -> [DocumentHit] {
        guard !isEmpty else { return hits }
        let prefixes = folders.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let singles = Set(singleFiles.map(\.path))
        return hits.filter { hit in
            let path = hit.url.standardizedFileURL.path
            return singles.contains(path) || prefixes.contains { path.hasPrefix($0) }
        }
    }

    /// „Ordner: Akten › Verträge › 2024 (37 Dateien)“ / „3 Ordner (120 Dateien)“; nil without a filter.
    /// - Parameter shown: documents shown while searching: „(3 von 37 Dateien)“.
    public func header(tree: [FolderNode], shown: Int? = nil) -> String? {
        guard let title = title(tree: tree) else { return nil }
        let total = fileCount(tree: tree)
        // While searching always „x von y“, also when every file hit (trial run: „10 Dateien“ read like browsing).
        guard let shown else { return "\(title) (\(Self.files(total)))" }
        return "\(title) (\(shown.formatted(.number.locale(Locale(identifier: "de_DE")))) von \(Self.files(total)))"
    }

    /// „Ordner: Akten › Verträge“, „Einzelne Dateien“ or „3 Ordner“.
    private func title(tree: [FolderNode]) -> String? {
        guard !isEmpty else { return nil }
        if folders.count == 1, singleFiles.isEmpty, let trail = FolderTree.path(to: folders[0], in: tree) {
            return "Ordner: " + trail.map(\.name).joined(separator: " › ")
        }
        if folders.isEmpty { return FolderTree.singleFilesTitle }
        return "\(folders.count + (singleFiles.isEmpty ? 0 : 1)) Ordner"
    }

    /// Files in the chosen folders (from the tree) and single files.
    private func fileCount(tree: [FolderNode]) -> Int {
        folders.compactMap { FolderTree.path(to: $0, in: tree)?.last?.fileCount }.reduce(0, +) + singleFiles.count
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 Datei" : "\(n.formatted(.number.locale(Locale(identifier: "de_DE")))) Dateien" }
}

/// Every filter on the grid: the folder filter plus further ones (AND).
public struct DocumentFilters: Sendable {
    public var folder = FolderFilter()
    public var others: [any DocumentFilter] = []

    public init() {}

    public var isEmpty: Bool { folder.isEmpty && others.isEmpty }

    public func apply(_ hits: [DocumentHit]) -> [DocumentHit] {
        let byFolder = folder.apply(hits)
        guard !others.isEmpty else { return byFolder }
        return byFolder.filter { hit in others.allSatisfy { $0.includes(hit) } }
    }
}

// MARK: - Orte

/// Lists the subfolders of a folder (in the background; injected in tests).
public protocol FolderLister: Sendable {
    func subfolders(of folder: URL) throws -> [URL]
}

/// Folders only: no files, no hidden folders, no packages (apps, bundles), sorted like the Finder.
public struct FileSystemFolderLister: FolderLister {
    public init() {}

    public func subfolders(of folder: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return urls.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.isDirectory == true && v.isPackage != true && v.isHidden != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// One entry of the „Orte“ section.
public struct Place: Equatable, Hashable, Sendable {
    public let name: String
    public let url: URL
}

public enum Places {
    /// Home, Schreibtisch, Dokumente, Downloads and the mounted volumes (not the start volume).
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                volumes: [URL] = mountedVolumes()) -> [Place] {
        [Place(name: "Home", url: home),
         Place(name: "Schreibtisch", url: home.appendingPathComponent("Desktop", isDirectory: true)),
         Place(name: "Dokumente", url: home.appendingPathComponent("Documents", isDirectory: true)),
         Place(name: "Downloads", url: home.appendingPathComponent("Downloads", isDirectory: true))]
        + volumes.map { Place(name: $0.lastPathComponent, url: $0) }
    }

    public static func mountedVolumes() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" && $0.path.hasPrefix("/Volumes/") }
    }

    public enum Action: Equatable, Sendable {
        /// Inside a loaded source: filter at once.
        case filter(URL)
        /// Not loaded: the add prompt (1.2.1), then load and filter.
        case add(URL)
    }

    public static func action(for folder: URL, sources: [LoadedSourceRef]) -> Action {
        let path = folder.standardizedFileURL.path
        let inside = sources.contains { source in
            guard source.isFolder else { return false }
            let root = source.url.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return inside ? .filter(folder) : .add(folder)
    }
}
