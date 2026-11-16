// SlideKitLayoutSource.swift — SlideKit adapter for the Office integration: PowerPoint layout for the Indexer.
import Foundation
import IndexKit
import SlideKit

/// Lays out a PowerPoint file with SlideKit (no Quick Look, no WebKit, no slide cache): one page per visible
/// slide with its normalized text (`SlideDeck.slideText`), word boxes (`SlideDeck.wordBoxes`, 0…1, origin top
/// left) and the slide size in points. Plug it in as `OfficeLayoutSource(powerpoint: SlideKitLayoutSource(…))`.
///
/// Text layout depends on the `FontSubstitution` (missing fonts drawn like PowerPoint or in a look-alike), so it is
/// part of the layout version: switching the setting gives another `renderer(for:)` version and the `Indexer` lays
/// every PowerPoint document out again. Pass the app setting (`OfficeRenderSettings.fontSubstitution(from:)`);
/// this source has no default of its own.
///
/// Decks are opened for the layout and dropped afterwards (`decks` nil, the default): an index run over hundreds
/// of decks must not push the viewer's decks out of `SlideDeckCache.shared` nor keep their text and images. A deck
/// the viewer has open already (`borrowing`, default the shared cache) is used as it is (office-speed: no second
/// parse), without opening anything into that cache.
///
/// Only `.powerpoint`: other kinds report `("none", 0)` and throw `LayoutSourceError.unreadable`. A file that is no
/// readable presentation (no zip, encrypted, damaged, legacy .ppt) → `unreadable`; file system errors (file gone,
/// no permission, I/O) propagate, so the `Indexer` retries. Honours cancellation between slides. A deck without visible slides gives
/// no pages.
public struct SlideKitLayoutSource: PageLayoutSource {
    /// Renderer name stored with every page (`LayoutResult.renderer`, `documents.renderer`).
    public static let rendererName = "slidekit"
    /// Bump when SlideKit's text or word boxes change in a way the index should pick up.
    public static let baseVersion = 1

    static let notPowerPointReason = "keine PowerPoint-Präsentation"
    static let unreadableReason = "Präsentation nicht lesbar"
    static let encryptedReason = "Präsentation ist verschlüsselt"

    public let fontSubstitution: FontSubstitution
    private let decks: SlideDeckCache?
    private let borrowing: SlideDeckCache

    /// `decks`: a cache to open decks through (tests); nil opens each deck for its layout only. `borrowing`: whose
    /// open decks the layout may use (tests pass their own).
    public init(fontSubstitution: FontSubstitution, decks: SlideDeckCache? = nil, borrowing: SlideDeckCache = .shared) {
        self.fontSubstitution = fontSubstitution
        self.decks = decks
        self.borrowing = borrowing
    }

    /// `baseVersion * 100` plus a fixed code per substitution (powerPoint 1, similar 2): another setting is another
    /// version, a SlideKit upgrade raises both.
    public static func layoutVersion(for fontSubstitution: FontSubstitution) -> Int {
        let code = switch fontSubstitution {
        case .powerPoint: 1
        case .similar: 2
        }
        return baseVersion * 100 + code
    }

    public func renderer(for kind: DocumentKind) -> (name: String, version: Int) {
        kind == .powerpoint ? (Self.rendererName, Self.layoutVersion(for: fontSubstitution)) : ("none", 0)
    }

    public func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        guard kind == .powerpoint else { throw LayoutSourceError.unreadable(url, reason: Self.notPowerPointReason) }
        try Task.checkCancellation()
        // Word boxes need Office's fonts: wait for (or start) the registration, as the first font lookup did before
        // office-speed; then only decks opened with them are borrowed.
        if !SlideDeck.officeFontsReady { SlideDeck.prewarmFonts() }
        let deck: SlideDeck
        do {
            deck = try decks?.deck(for: url, fontSubstitution: fontSubstitution)
                ?? borrowing.openDeck(for: url, fontSubstitution: fontSubstitution)
                ?? SlideDeckCache.open(url, fontSubstitution: fontSubstitution)
        } catch let error as SlideKitError {
            throw LayoutSourceError.unreadable(url, reason: error == .encrypted ? Self.encryptedReason : Self.unreadableReason)
        }
        var pages: [LaidOutPage] = []
        pages.reserveCapacity(deck.slideCount)
        for i in 0..<deck.slideCount {
            try Task.checkCancellation()
            pages.append(LaidOutPage(text: deck.slideText(i), words: deck.wordBoxes(i), size: deck.slideSize))
        }
        return LayoutResult(pages: pages, renderer: Self.rendererName, layoutVersion: Self.layoutVersion(for: fontSubstitution))
    }
}
