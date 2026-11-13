// Sorting.swift — Task 2.3
import Foundation

/// Sorts hits for display (spec §4.2). Ties fall back to `relativePath`, then to the full path,
/// so the order is stable across searches and sources (spec 1.1 §4). `.folder` groups by source first.
public func sortHits(_ hits: [DocumentHit], by mode: SortMode) -> [DocumentHit] {
    hits.sorted { a, b in
        let primary: ComparisonResult
        switch mode {
        case .matchCount:
            primary = compareDescending(a.totalMatches, b.totalMatches)
                .then(natural(a.fileName, b.fileName))
        case .relevance:
            primary = compareDescending(a.relevance, b.relevance)
        case .modifiedDate:
            primary = compareDescending(a.modifiedAt, b.modifiedAt)
        case .fileName:
            primary = natural(a.fileName, b.fileName)
        case .folder:
            primary = natural(a.sourceRoot.path, b.sourceRoot.path)
                .then(compareFolders(a.folderComponents, b.folderComponents))
                .then(natural(a.fileName, b.fileName))
        }
        return primary.then(natural(a.relativePath, b.relativePath))
            .then(natural(a.id, b.id))
            .then(a.id < b.id ? .orderedAscending : a.id > b.id ? .orderedDescending : .orderedSame)
            == .orderedAscending
    }
}

private func compareDescending<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a > b ? .orderedAscending : a < b ? .orderedDescending : .orderedSame
}

/// Finder-like order: case-insensitive, digits compared numerically ("2" before "10").
private func natural(_ a: String, _ b: String) -> ComparisonResult {
    a.localizedStandardCompare(b)
}

/// Folder by folder, so a subfolder follows its parent ("a", "a/sub", "a b").
private func compareFolders(_ a: [String], _ b: [String]) -> ComparisonResult {
    for (x, y) in zip(a, b) {
        let r = natural(x, y)
        if r != .orderedSame { return r }
    }
    return compareDescending(b.count, a.count)  // the parent (fewer components) first
}

private extension ComparisonResult {
    func then(_ next: @autoclosure () -> ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? next() : self
    }
}

private extension DocumentHit {
    var fileName: String { (relativePath as NSString).lastPathComponent }
    var folderComponents: [String] { relativePath.split(separator: "/").dropLast().map(String.init) }
}
