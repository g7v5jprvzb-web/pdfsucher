// TextKitWordSource.swift — 1.3 Office Task 7: Word pages from `TextKitWordDocument` (renderer `textkit` v1).
import Foundation
import IndexKit

/// Lays out Word documents with `TextKitWordDocument` (via its cache, so a viewer opening the file next reuses the
/// import). Runs on the caller's task, off the main actor (the AppKit importer is stable there, decisions.md);
/// checks cancellation between pages.
///
/// Only for `.word`: PowerPoint is `QuickLookSlideSource`'s job (`OfficeLayoutSource` dispatches by kind), so
/// `.powerpoint` throws `unreadable`. Errors otherwise as `TextKitWordDocument.init`: a file the importer rejects is
/// `unreadable`, a missing file keeps its Cocoa error (the Indexer retries / drops it next run).
///
/// Font state (1.3.2): a document laid out before Office's font registration was done (its 3 s deadline passed, a
/// prompt still open or denied) is stored as `substituteRenderer` instead of `textkit`; its word boxes were measured
/// with substitute fonts. Once the registration is done, `staleRenderers(for: .word)` names it and the Indexer lays
/// those documents out again at its next run, so word boxes match the tiles, which are then drawn with Office's fonts.
/// The expected renderer (`renderer(for:)`) stays `textkit` 1: no relayout of every Word document.
public struct TextKitWordSource: PageLayoutSource {
    static let notWordReason = "kein Word-Dokument"
    /// Renderer name of a Word document laid out with substitute fonts (still the simplified renderer).
    public static let substituteRenderer = "textkit-substitute"

    private let fontGate: FontRegistrationGate

    public init() { fontGate = .shared }

    /// Tests: another registration gate.
    init(fontGate: FontRegistrationGate) { self.fontGate = fontGate }

    /// `("textkit", 1)`. This source only handles `.word`; the value for other kinds is meaningless, because
    /// `OfficeLayoutSource` dispatches by kind and asks the PowerPoint source for `.powerpoint`.
    public func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("textkit", 1) }

    /// `substituteRenderer` for Word once Office's fonts are complete (`isComplete`); nothing before (also not in a process that missed the cloud fonts) (laying those documents
    /// out again would give the same substitute fonts) and for other kinds.
    public func staleRenderers(for kind: DocumentKind) -> [String] {
        kind == .word && fontGate.isComplete ? [Self.substituteRenderer] : []
    }

    public func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        guard kind == .word else { throw LayoutSourceError.unreadable(url, reason: Self.notWordReason) }
        try Task.checkCancellation()
        // The layout phase may start the registration.
        let document = try TextKitWordDocument.cached(url: url, fontGate: fontGate, fonts: .start)
        var pages: [LaidOutPage] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            pages.append(document.page(index))
        }
        return LayoutResult(pages: pages, renderer: document.laidOutWithOfficeFonts ? "textkit" : Self.substituteRenderer,
                            layoutVersion: 1)
    }
}
