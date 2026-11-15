// OfficeDisplay.swift — SlideKit wiring (1.3.0): the Word/PowerPoint pages for tiles, preview and output.
import Foundation
import OOXMLKit
import IndexKit
import OutputKit
import SlideKit
import SlideKitAdapter

/// Builds the app's `ForeignPageProvider` for a display choice, next to `OfficeLayoutSource.standard` (the layout
/// side). Spec §9: tiles, the large preview and saved/printed output come from the same renderer.
public enum OfficeDisplay {
    /// The pages for `rendering`: the own viewer → `SlideKitPages` (live vector slides, no slide cache) with the same
    /// `FontSubstitution` the layout uses, Word through `OfficePages`; Quick Look → `OfficePages` (slide pictures
    /// from `cache`). `renderers` is the app's layout source (Word's and Quick Look's tile versions).
    /// The provider is fixed to `rendering`: when the choice changes, build a new one (and the tile cache holding it)
    /// and call `releaseOpenDecks()`.
    public static func pages(for rendering: OfficeRendering, cache: SlideCache,
                             renderers: any PageLayoutSource) -> any ForeignPageProvider {
        let office = OfficePages(cache: cache, renderers: renderers)
        switch rendering.powerPoint {
        case .slideKit: return SlideKitPages(fontSubstitution: rendering.fonts, fallback: office)
        case .quickLook: return office
        }
    }

    /// Whether `pages(for:)` draws the same for both choices (Quick Look ignores the fonts).
    public static func samePages(_ a: OfficeRendering, _ b: OfficeRendering) -> Bool {
        a.powerPoint == b.powerPoint && (a.powerPoint == .quickLook || a.fonts == b.fonts)
    }

    /// Whether PowerPoint pages come from the slide cache (Quick Look). Only then a tile without its slide picture
    /// means a cache miss worth a new layout; SlideKit draws on demand.
    public static func usesSlideCache(_ rendering: OfficeRendering) -> Bool { rendering.powerPoint == .quickLook }

    /// Starts the registration of Office's own fonts (`FontRegistrationGate.shared`, i.e. `FontResolver.prewarm()`)
    /// and waits for it at most the gate's 3 s, so a macOS access prompt comes when the app starts its first
    /// Word/PowerPoint layout (`AppModel`), before the first font is resolved; Word documents opened meanwhile join the
    /// same registration. Blocking and idempotent: call it on a GCD queue, never on the main thread nor in a Swift
    /// task. Without it the first Word layout or font resolution starts it.
    /// - Returns: whether the registration succeeded: done within the gate's deadline, Office's cloud font cache read
    ///   in time (false after a timeout, e.g. an unanswered prompt). A denied prompt reads as an empty font cache.
    @discardableResult
    public static func prewarmFonts() -> Bool {
        FontRegistrationGate.shared.wait() && FontRegistrationGate.shared.isComplete
    }

    /// Runs `body` (utility queue) when the started registration finishes complete – also after the waiters' 3 s
    /// deadline (a prompt answered late). Nothing when it finishes incomplete or was never started.
    public static func whenFontsComplete(_ body: @escaping @Sendable () -> Void) {
        let gate = FontRegistrationGate.shared
        gate.notifyWhenDone { if gate.isComplete { body() } }
    }

    /// No Office fonts in this process (`FontResolver.officeFontRoots = .none`): the UI-test launch of the app. Call
    /// it before the first font is resolved.
    public static func useNoOfficeFonts() { FontResolver.officeFontRoots = .none }

    /// Drops the decks the own viewer keeps open (after a display switch: frees their memory at once).
    public static func releaseOpenDecks() { SlideDeckCache.shared.removeAll() }
}
