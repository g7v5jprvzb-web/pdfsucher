// PageLayoutSource.swift — 1.3 Teil A, Task 3
import Foundation

/// The document cannot be laid out at all (damaged, encrypted, unsupported); the `Indexer` stores it
/// with status `error` and does not retry it until the file changes. Any other error counts as
/// passing: the document is tried again in the next run.
public enum LayoutSourceError: Error, Equatable {
    case unreadable(URL, reason: String)
}

/// Lays out Word and PowerPoint documents into pages with text and word boxes (spec 1.3), used by
/// the `Indexer` phase „layout“.
public protocol PageLayoutSource: Sendable {
    /// Called off the main actor, at most `concurrency` at once. Must honour Task cancellation.
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult
    /// Renderer name and version this source produces for `kind` (for re-layout after upgrades).
    func renderer(for kind: DocumentKind) -> (name: String, version: Int)
    /// Renderer names (as stored per document, `LayoutResult.renderer`) whose documents of `kind` are to be laid out
    /// again at the next layout run, whatever their version (1.3.2: Word laid out with substitute fonts, once Office's
    /// fonts are registered). Default none.
    func staleRenderers(for kind: DocumentKind) -> [String]
}

extension PageLayoutSource {
    public func staleRenderers(for kind: DocumentKind) -> [String] { [] }
}
