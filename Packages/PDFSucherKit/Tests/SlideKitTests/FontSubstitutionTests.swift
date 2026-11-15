// FontSubstitutionTests.swift — SlideDeck's font substitution option and the Office settings keys.
import CoreGraphics
import Foundation
import Testing
import TestSupport
import OOXMLKit
@testable import SlideKit

@Suite struct FontSubstitutionTests {
    private let missing = "Fictional Corporate Sans"

    private func fixture() -> PptxFixture {
        var f = PptxFixture()
        let p = "<a:p><a:r><a:rPr sz=\"2000\"><a:latin typeface=\"\(missing)\"/></a:rPr>"
            + "<a:t>Substituted text that wraps somewhere</a:t></a:r></a:p>"
        f.slides = [.init(shapes: X.textBox(2, CGRect(x: 0, y: 0, width: 120, height: 300), body: X.body(p)))]
        return f
    }

    @Test func deckDefaultsToPowerPoint() throws {
        let o = try fixture().open()
        #expect(o.deck.fontSubstitution == .powerPoint)
        #expect(o.deck.store.fonts.substitution == .powerPoint)
    }

    /// Same file, two decks: each resolves the missing family by its own option and keeps its own caches.
    @Test func sameFileWithBothOptions() throws {
        let (holder, decks) = try fixture().open([.powerPoint, .similar])
        _ = holder
        let pp = decks[0], similar = decks[1]
        let office = pp.store.fonts.isInstalled("Calibri") ? "Calibri" : "Arial"
        #expect(pp.store.fonts.resolvedFamily(missing) == office)
        #expect(similar.store.fonts.resolvedFamily(missing) == "Helvetica Neue")
        #expect(pp.store !== similar.store)
        // wordBoxes follow the option: Calibri/Arial and Helvetica Neue words have different widths.
        let a = pp.wordBoxes(0), b = similar.wordBoxes(0)
        try #require(a.count == b.count && !a.isEmpty)
        #expect(zip(a, b).contains { abs($0.box.width - $1.box.width) > 0.001 })
    }

    @Test func prewarmFontsCanBeCalledFromAnyThread() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { SlideDeck.prewarmFonts() } }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { SlideDeck.prewarmFonts(); done.resume() }
        }
        #expect(FontResolver(theme: nil).isInstalled("Helvetica Neue"))
    }

    @Test func settingsReaders() throws {
        let name = "slidekit-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(OfficeRenderSettings.fontSubstitutionKey == "office.fontSubstitution")
        #expect(OfficeRenderSettings.powerPointRendererKey == "office.powerPointRenderer")
        #expect(OfficeRenderSettings.officeFontsKey == "office.officeFonts")
        #expect(OfficeRenderSettings.officeFonts(from: d) == .all)
        d.set("bundled", forKey: OfficeRenderSettings.officeFontsKey)
        #expect(OfficeRenderSettings.officeFonts(from: d) == .bundled)
        d.set("bogus", forKey: OfficeRenderSettings.officeFontsKey)
        #expect(OfficeRenderSettings.officeFonts(from: d) == .all)
        #expect(OfficeRenderSettings.fontSubstitution(from: d) == .powerPoint)
        #expect(OfficeRenderSettings.powerPointRenderer(from: d) == .slideKit)
        d.set("similar", forKey: OfficeRenderSettings.fontSubstitutionKey)
        d.set("quickLook", forKey: OfficeRenderSettings.powerPointRendererKey)
        #expect(OfficeRenderSettings.fontSubstitution(from: d) == .similar)
        #expect(OfficeRenderSettings.powerPointRenderer(from: d) == .quickLook)
        d.set("bogus", forKey: OfficeRenderSettings.fontSubstitutionKey)
        d.set("bogus", forKey: OfficeRenderSettings.powerPointRendererKey)
        #expect(OfficeRenderSettings.fontSubstitution(from: d) == .powerPoint)
        #expect(OfficeRenderSettings.powerPointRenderer(from: d) == .slideKit)
        #expect(PowerPointRenderer.allCases == [.slideKit, .quickLook])
    }
}
