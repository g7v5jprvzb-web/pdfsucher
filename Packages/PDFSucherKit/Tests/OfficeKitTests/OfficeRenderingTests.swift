import CoreGraphics
import Foundation
import IndexKit
@testable import OfficeKit
import OutputKit
import PDFKit
import SlideKit
import SlideKitAdapter
import Synchronization
import Testing
import TestSupport

/// A layout source that answers one page and names itself.
private final class NamedSource: PageLayoutSource {
    let name: String
    let version: Int
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    init(_ name: String, version: Int = 3) { self.name = name; self.version = version }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name, version) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        calls.withLock { $0 += 1 }
        return LayoutResult(pages: [LaidOutPage(text: name, words: [], size: CGSize(width: 10, height: 10))],
                            renderer: name, layoutVersion: version)
    }
}

/// 1.3 Teil B Task 12: „PowerPoint-Darstellung“ and „Fehlende Schriften“ choose the PowerPoint layout at layout time.
@Suite("Office rendering setting")
struct OfficeRenderingTests {
    let deck = URL(fileURLWithPath: "/tmp/x.pptx")

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeRendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func defaultsAreOwnViewerAndPowerPointFonts() {
        #expect(OfficeRendering.default == OfficeRendering(powerPoint: .slideKit, fonts: .powerPoint))
        #expect(PowerPointDisplaySetting().value == .default)
    }

    /// The settings UI keeps its own choices (ViewerUI must not see SlideKit); they map by raw value.
    @Test func storedRawValuesMapToTheRealTypes() {
        #expect(OfficeRendering(powerPointRawValue: "quickLook", fontsRawValue: "similar")
                == OfficeRendering(powerPoint: .quickLook, fonts: .similar))
        #expect(OfficeRendering(powerPointRawValue: "slideKit", fontsRawValue: "powerPoint") == .default)
        #expect(OfficeRendering(powerPointRawValue: "kaputt", fontsRawValue: "") == .default, "unknown → default")
    }

    @Test func quickLookChosenUsesQuickLook() async throws {
        let ql = NamedSource("quicklook"), sk = NamedSource("slidekit")
        let setting = PowerPointDisplaySetting(OfficeRendering(powerPoint: .quickLook))
        let source = OfficeLayoutSource(powerpoint: ql, word: NamedSource("textkit"), slideKit: { _ in sk }, rendering: setting)
        #expect(source.renderer(for: .powerpoint) == ("quicklook", 3))
        #expect(try await source.layout(of: deck, kind: .powerpoint).renderer == "quicklook")
        #expect(sk.count == 0)
    }

    /// Without an own-viewer source (tests), the own viewer lays decks out with Quick Look (and says so).
    @Test func ownViewerFallsBackToQuickLookWithoutAdapter() async throws {
        let ql = NamedSource("quicklook")
        let source = OfficeLayoutSource(powerpoint: ql, word: NamedSource("textkit"), rendering: PowerPointDisplaySetting())
        #expect(source.renderer(for: .powerpoint) == ("quicklook", 3))
        #expect(try await source.layout(of: deck, kind: .powerpoint).renderer == "quicklook")
        #expect(ql.count == 1)
    }

    /// The own viewer's identity comes from its source (the adapter encodes the fonts in the version): no suffix.
    @Test func ownViewerUsesItsSourceForTheFonts() async throws {
        let fonts = Mutex<[FontSubstitution]>([])
        let setting = PowerPointDisplaySetting()
        let source = OfficeLayoutSource(powerpoint: NamedSource("quicklook"), word: NamedSource("textkit"),
                                        slideKit: { f in
                                            fonts.withLock { $0.append(f) }
                                            return NamedSource("slidekit", version: f == .similar ? 102 : 101)
                                        },
                                        rendering: setting)
        #expect(source.renderer(for: .powerpoint) == ("slidekit", 101))
        #expect(try await source.layout(of: deck, kind: .powerpoint).renderer == "slidekit")
        setting.value = OfficeRendering(powerPoint: .slideKit, fonts: .similar)
        #expect(source.renderer(for: .powerpoint) == ("slidekit", 102))
        let result = try await source.layout(of: deck, kind: .powerpoint)
        #expect(result.renderer == "slidekit" && result.layoutVersion == 102, "stored renderer = expected renderer")
        #expect(fonts.withLock { $0 }.last == .similar)
        #expect(source.renderer(for: .word) == ("textkit", 3))
    }

    /// The app's wiring point: the own viewer is the SlideKit adapter, its version follows „Fehlende Schriften“.
    @Test func standardWiresTheSlideKitAdapter() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pptx = try OfficeFixtures.pptx(slides: ["Erste Folie", "Zweite Folie"], name: "Vortrag.pptx", in: dir)
        let setting = PowerPointDisplaySetting()
        let source = OfficeLayoutSource.standard(cache: SlideCache(root: dir.appendingPathComponent("Slides")), rendering: setting)
        #expect(source.renderer(for: .powerpoint) == (SlideKitLayoutSource.rendererName, 101))
        let result = try await source.layout(of: pptx, kind: .powerpoint)
        #expect(result.renderer == "slidekit" && result.layoutVersion == 101)
        #expect(result.pages.count == 2 && result.pages[1].text.contains("Zweite Folie"))
        #expect(!result.pages[0].words.isEmpty, "word boxes for highlights")

        setting.value = OfficeRendering(powerPoint: .slideKit, fonts: .similar)
        #expect(source.renderer(for: .powerpoint) == ("slidekit", 102))
        #expect(try await source.layout(of: pptx, kind: .powerpoint).layoutVersion == 102)

        setting.value = OfficeRendering(powerPoint: .quickLook, fonts: .similar)
        #expect(source.renderer(for: .powerpoint) == QuickLookSlideSource().renderer(for: .powerpoint))
        #expect(source.renderer(for: .word) == TextKitWordSource().renderer(for: .word))
    }

    @Test func tileVersionFollowsTheSetting() {
        let setting = PowerPointDisplaySetting(OfficeRendering(powerPoint: .quickLook))
        let layout = OfficeLayoutSource(powerpoint: NamedSource("quicklook"), word: NamedSource("textkit"),
                                        slideKit: { _ in NamedSource("slidekit") }, rendering: setting)
        let pages = OfficePages(cache: SlideCache(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeRendering-\(UUID().uuidString)")), renderers: layout)
        #expect(pages.contentVersion(deck).hasPrefix("quicklook:3|"))
        setting.value = .default
        #expect(pages.contentVersion(deck).hasPrefix("slidekit:3|"))
    }

    /// Tiles, preview and output: SlideKit pages for the own viewer (Word through `OfficePages`), Quick Look's
    /// slide pictures otherwise; the tile version names the renderer and the fonts.
    @Test func pagesFollowTheChoice() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SlideCache(root: dir.appendingPathComponent("Slides"))
        let layout = OfficeLayoutSource.standard(cache: cache, rendering: PowerPointDisplaySetting(.default))
        let pptx = dir.appendingPathComponent("Vortrag.pptx"), docx = dir.appendingPathComponent("Brief.docx")

        OfficeDisplay.prewarmFonts()       // SlideKit's version has a „~“ until Office's fonts are registered
        let own = OfficeDisplay.pages(for: .default, cache: cache, renderers: layout)
        let slides = try #require(own as? SlideKitPages)
        #expect(slides.fontSubstitution == .powerPoint)
        #expect(own.contentVersion(pptx) == "slidekit:101:r1")
        #expect(own.handles(docx) && own.contentVersion(docx) == OfficePages(cache: cache, renderers: layout).contentVersion(docx))

        let similar = OfficeDisplay.pages(for: OfficeRendering(powerPoint: .slideKit, fonts: .similar), cache: cache, renderers: layout)
        #expect(similar.contentVersion(pptx) == "slidekit:102:r1")

        let quickLook = OfficeDisplay.pages(for: OfficeRendering(powerPoint: .quickLook), cache: cache, renderers: layout)
        #expect(quickLook is OfficePages)
        #expect(OfficeDisplay.usesSlideCache(OfficeRendering(powerPoint: .quickLook)))
        #expect(!OfficeDisplay.usesSlideCache(.default))
    }

    /// Spec §9: saved output is drawn by the same renderer as tile and preview — with SlideKit a vector page of the
    /// slide's size carrying the slide's text.
    @Test func savedSlideIsAVectorPageOfTheSlideSize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pptx = try OfficeFixtures.pptx(slides: ["Angebot Wasserwerk"], name: "Vortrag.pptx", in: dir)
        let slideRoot = dir.appendingPathComponent("Slides")
        let cache = SlideCache(root: slideRoot)
        let pages = OfficeDisplay.pages(for: .default, cache: cache,
                                        renderers: OfficeLayoutSource.standard(cache: cache, rendering: PowerPointDisplaySetting()))
        let out = dir.appendingPathComponent("out.pdf")
        try Merger(foreign: pages).write([PageRef(url: pptx, pageIndex: 0)], to: out)
        let saved = try #require(PDFDocument(url: out)?.page(at: 0))
        #expect(saved.bounds(for: .mediaBox).size == CGSize(width: 720, height: 540))
        #expect(saved.string?.contains("Angebot Wasserwerk") == true, "vector text, not a picture")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: slideRoot.path)) ?? []).isEmpty, "no slide pictures")
    }
}
