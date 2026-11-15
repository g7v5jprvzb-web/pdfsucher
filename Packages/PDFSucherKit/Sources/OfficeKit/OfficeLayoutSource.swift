// OfficeLayoutSource.swift — 1.3 Office Task 8: one layout source for the Indexer, dispatching by document kind.
import Foundation
import IndexKit
import SlideKitAdapter

/// The `PageLayoutSource` the Indexer gets: PowerPoint → the own viewer (SlideKit) or Quick Look, as `rendering`
/// says at layout time; Word → `word` (TextKit).
/// PDFs and images never need a layout; asked anyway, `layout` throws `LayoutSourceError.unreadable`
/// („kein Office-Dokument“) and `renderer(for:)` reports `("none", 0)`.
///
/// PowerPoint renderer identity (stored per document and as the expected renderer in the index, part of the tile key):
/// the source that really lays out — Quick Look's own, or the SlideKit adapter's (`slidekit`, version 101 „wie
/// PowerPoint“ / 102 „ähnliche Schrift“). A change re-lays out every deck (`Indexer`, `adoptLayoutRenderer` +
/// `resetLayout`).
public struct OfficeLayoutSource: PageLayoutSource {
    static let notOfficeReason = "kein Office-Dokument"

    private let quickLook: any PageLayoutSource
    private let word: any PageLayoutSource
    private let slideKit: (@Sendable (FontSubstitution) -> any PageLayoutSource)?
    private let rendering: PowerPointDisplaySetting

    /// - Parameters:
    ///   - powerpoint: the Quick Look source.
    ///   - slideKit: makes the own viewer's source for a font choice (the app: `SlideKitLayoutSource`, see
    ///     `standard(cache:rendering:)`); nil (tests) = „Eigener Viewer“ lays out with Quick Look.
    ///   - rendering: the user's choice, read at every call.
    public init(powerpoint: any PageLayoutSource = QuickLookSlideSource(), word: any PageLayoutSource = TextKitWordSource(),
                slideKit: (@Sendable (FontSubstitution) -> any PageLayoutSource)? = nil,
                rendering: PowerPointDisplaySetting = .shared) {
        self.quickLook = powerpoint
        self.word = word
        self.slideKit = slideKit
        self.rendering = rendering
    }

    /// The app's layout source: the own viewer (SlideKit adapter, decks opened per layout, not kept) or Quick Look
    /// with its slides in `cache`, the choice from `rendering`. The one place that wires the PowerPoint layout
    /// (folder indexes and single files use it alike); the pages for tiles, preview and output come from
    /// `OfficeDisplay.pages(for:cache:renderers:)` with the same `FontSubstitution`.
    public static func standard(cache: SlideCache, rendering: PowerPointDisplaySetting = .shared) -> OfficeLayoutSource {
        OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: cache),
                           slideKit: { SlideKitLayoutSource(fontSubstitution: $0) }, rendering: rendering)
    }

    /// The PowerPoint source for the current choice.
    private func powerPointSource() -> any PageLayoutSource {
        let choice = rendering.value
        guard choice.powerPoint == .slideKit, let slideKit else { return quickLook }
        return slideKit(choice.fonts)
    }

    public func renderer(for kind: DocumentKind) -> (name: String, version: Int) {
        switch kind {
        case .powerpoint: return powerPointSource().renderer(for: kind)
        case .word: return word.renderer(for: kind)
        case .pdf, .image: return ("none", 0)
        }
    }

    public func staleRenderers(for kind: DocumentKind) -> [String] {
        switch kind {
        case .powerpoint: return powerPointSource().staleRenderers(for: kind)
        case .word: return word.staleRenderers(for: kind)
        case .pdf, .image: return []
        }
    }

    public func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        switch kind {
        case .powerpoint: return try await powerPointSource().layout(of: url, kind: kind)
        case .word: return try await word.layout(of: url, kind: kind)
        case .pdf, .image: throw LayoutSourceError.unreadable(url, reason: Self.notOfficeReason)
        }
    }
}
