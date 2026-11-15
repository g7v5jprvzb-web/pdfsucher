import CoreGraphics
import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import SlideKit
import SlideKitAdapter
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Counts layout runs per file name, shared by the named sources below.
private final class Counts: Sendable {
    private let counts = Mutex([String: Int]())
    func add(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
}

/// Lays out every Word/PowerPoint file as one page under its own renderer name.
private struct NamedLayout: PageLayoutSource {
    let name: String
    let counts: Counts
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        counts.add(url.lastPathComponent)
        return LayoutResult(pages: [LaidOutPage(text: "Folie", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: name, layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name, 1) }
}

/// A shared on/off switch for held layouts.
private final class Hold: Sendable {
    private let state = Mutex(true)
    var isOn: Bool { state.withLock { $0 } }
    func release() { state.withLock { $0 = false } }
}

/// Lays out every file as one page with `text`; while `hold` is on it waits, honouring cancellation.
private struct HeldLayout: PageLayoutSource {
    let name: String
    let text: String
    let hold: Hold
    let log: StringLog
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        log.append("\(name):start")
        let deadline = ContinuousClock.now + .seconds(20)
        while hold.isOn {
            if Task.isCancelled { log.append("\(name):cancelled"); throw CancellationError() }
            if ContinuousClock.now > deadline { Issue.record("held layout never released"); break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        log.append("\(name):end")
        return LayoutResult(pages: [LaidOutPage(text: text, words: [], size: CGSize(width: 100, height: 100))],
                            renderer: name, layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name, 1) }
}

/// 1.3 Teil B Task 12: „PowerPoint-Darstellung“ / „Fehlende Schriften“ lay every PowerPoint out again, with no
/// word of the old layout left searchable meanwhile (`resetLayout(kind: .powerpoint)`).
@MainActor @Suite("Office rendering switch", .serialized)
struct OfficeRenderingSwitchTests {
    let base: URL, eins: URL, zwei: URL
    let rendering = PowerPointDisplaySetting()
    fileprivate let counts = Counts()

    /// A layout with the own viewer available: its identity follows the setting.
    fileprivate func withAdapter() -> OfficeLayoutSource {
        OfficeLayoutSource(powerpoint: NamedLayout(name: "quicklook", counts: counts), word: NamedLayout(name: "textkit", counts: counts),
                           slideKit: { [counts] _ in NamedLayout(name: "slidekit", counts: counts) }, rendering: rendering)
    }

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func indexes(_ names: [String], log: StringLog) -> [String: FakeIndex] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            let index = FakeIndex()
            index.name = name
            index.layoutLog = log
            return (name, index)
        })
    }

    func model(_ indexes: [String: FakeIndex] = [:], layout: (any PageLayoutSource)? = nil,
               defaults: UserDefaults = UserDefaults(suiteName: "Rendering-\(UUID().uuidString)")!) -> AppModel {
        AppModel(settings: makeSettings(), defaults: defaults, environment: FakeEnvironment(),
                 slideCache: SlideCache(root: base.appendingPathComponent("SlideCache", isDirectory: true)), debounce: .zero,
                 openIndex: { root in indexes[root.lastPathComponent]! }, officeLayout: layout, officeRendering: rendering)
    }

    @Test func preferencesDefaultAndPersist() {
        let d = UserDefaults(suiteName: "Rendering-\(UUID().uuidString)")!
        let p = OfficePreferences(defaults: d)
        #expect(p.powerPointRenderer == .slideKit && p.fontSubstitution == .powerPoint)
        #expect(OfficeRendering(p) == .default)
        p.powerPointRenderer = .quickLook
        p.fontSubstitution = .similar
        #expect(d.string(forKey: "office.powerPointRenderer") == "quickLook")
        #expect(d.string(forKey: "office.fontSubstitution") == "similar")
        let again = OfficePreferences(defaults: d)
        #expect(OfficeRendering(again) == OfficeRendering(powerPoint: .quickLook, fonts: .similar))
        d.set("kaputt", forKey: "office.powerPointRenderer")
        #expect(OfficePreferences(defaults: d).powerPointRenderer == .slideKit, "unknown value → default")
    }

    @Test func modelPassesTheStoredChoiceToTheLayout() {
        let d = UserDefaults(suiteName: "Rendering-\(UUID().uuidString)")!
        d.set("quickLook", forKey: "office.powerPointRenderer")
        _ = model(defaults: d)
        #expect(rendering.value == OfficeRendering(powerPoint: .quickLook, fonts: .powerPoint))
    }

    @Test(.timeLimit(.minutes(1))) func rendererSwitchResetsPowerPointEverywhere() async throws {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        let m = model(idx, layout: withAdapter())
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        let revision = m.layoutRevision

        m.officePreferences.powerPointRenderer = .quickLook            // slidekit → quicklook
        await m.waitUntilIdle()
        #expect(rendering.value.powerPoint == .quickLook)
        for name in ["eins", "zwei"] {
            #expect(idx[name]!.layoutRequests == ["adopt:powerpoint"])
            #expect(idx[name]!.layoutCount == 2)
        }
        #expect(m.layoutRevision > revision)
        #expect(m.alertMessage == nil)

        // Fonts do not matter to Quick Look: the identity stays, nothing is reset.
        m.officePreferences.fontSubstitution = .similar
        await m.waitUntilIdle()
        #expect(rendering.value == OfficeRendering(powerPoint: .quickLook, fonts: .similar))
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint"])
        #expect(idx["eins"]!.layoutCount == 2)

        m.officePreferences.powerPointRenderer = .slideKit             // quicklook → slidekit (fonts kept: similar)
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint", "adopt:powerpoint"])
        #expect(idx["eins"]!.layoutCount == 3)
    }

    /// The settings UI's own choices (ViewerUI does not see SlideKit) cover exactly main's values and keys.
    @Test func uiChoicesMapToMainsTypes() {
        #expect(OfficeRendererChoice.allCases.map(\.rawValue) == PowerPointRenderer.allCases.map(\.rawValue))
        #expect(OfficeFontChoice.allCases.map(\.rawValue) == FontSubstitution.allCases.map(\.rawValue))
        let d = UserDefaults(suiteName: "Rendering-\(UUID().uuidString)")!
        let p = OfficePreferences(defaults: d)
        p.powerPointRenderer = .quickLook
        p.fontSubstitution = .similar
        #expect(OfficeRenderSettings.powerPointRenderer(from: d) == .quickLook)
        #expect(OfficeRenderSettings.fontSubstitution(from: d) == .similar)
    }

    /// The app's wiring (no injected layout or pages): tiles, preview and output follow the choice — SlideKit pages
    /// with the chosen fonts, or Quick Look's — and a switch gives a new provider and new tile versions.
    @Test(.timeLimit(.minutes(1))) func pagesFollowTheChoice() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        let pptx = eins.appendingPathComponent("Vortrag.pptx")
        let slides = try #require(m.foreignPages as? SlideKitPages)
        #expect(slides.fontSubstitution == .powerPoint)
        #expect(m.foreignPages?.contentVersion(pptx) == "slidekit:101:r1")
        let revision = m.foreignPagesRevision

        m.officePreferences.powerPointRenderer = .quickLook
        await m.waitUntilIdle()
        #expect(m.foreignPages is OfficePages)
        #expect(m.foreignPages?.contentVersion(pptx).hasPrefix("quicklook:") == true)
        #expect(m.foreignPagesRevision > revision)
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint"], "renderer identity changed")

        // Quick Look ignores the fonts: same provider, nothing laid out again.
        let quickLookRevision = m.foreignPagesRevision
        m.officePreferences.fontSubstitution = .similar
        await m.waitUntilIdle()
        #expect(m.foreignPagesRevision == quickLookRevision)
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint"])

        m.officePreferences.powerPointRenderer = .slideKit
        await m.waitUntilIdle()
        #expect((m.foreignPages as? SlideKitPages)?.fontSubstitution == .similar)
        #expect(m.foreignPages?.contentVersion(pptx) == "slidekit:102:r1")
        #expect(rendering.value == OfficeRendering(powerPoint: .slideKit, fonts: .similar))

        // Fonts under SlideKit: new layout version (102 → 101), reset again.
        m.officePreferences.fontSubstitution = .powerPoint
        await m.waitUntilIdle()
        #expect(m.foreignPages?.contentVersion(pptx) == "slidekit:101:r1")
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint", "adopt:powerpoint", "adopt:powerpoint"])
    }

    /// Review: the new pages (and their tiles) come only after the old PowerPoint words are gone, so new drawing never
    /// pairs with old word boxes.
    @Test(.timeLimit(.minutes(1))) func pagesChangeOnlyAfterTheOldWordsAreGone() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        idx["eins"]!.holdAdopt = true
        m.officePreferences.powerPointRenderer = .quickLook
        #expect(await eventually { idx["eins"]!.adoptStarted == 1 })
        #expect(m.foreignPages is SlideKitPages, "old pages while the old words are still there")
        #expect(m.foreignPagesRevision == 0)
        idx["eins"]!.holdAdopt = false
        await m.waitUntilIdle()
        #expect(m.foreignPages is OfficePages)
        #expect(m.foreignPagesRevision == 1)
    }

    /// Final review: a single PowerPoint being laid out at the switch is stopped and laid out again by the new
    /// renderer; its old text is never found.
    @Test(.timeLimit(.minutes(1))) func switchDuringSingleFileLayoutRelaysItOut() async throws {
        let pptx = try OfficeFixtures.pptx(slides: ["Folie eins"], name: "Einzeln.pptx", in: base)
        let log = StringLog()
        let hold = Hold()
        let held = OfficeLayoutSource(powerpoint: HeldLayout(name: "quicklook", text: "Neufassung", hold: hold, log: log),
                                      word: NamedLayout(name: "textkit", counts: counts),
                                      slideKit: { _ in HeldLayout(name: "slidekit", text: "Altfassung", hold: hold, log: log) },
                                      rendering: rendering)
        let m = model(layout: held)
        await m.add([pptx])
        #expect(await eventually { log.entries == ["slidekit:start"] })
        m.officePreferences.powerPointRenderer = .quickLook
        #expect(await eventually { log.entries.contains("slidekit:cancelled") })
        hold.release()
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0.hasPrefix("quicklook:") } == ["quicklook:start", "quicklook:end"])
        #expect(!log.entries.contains("slidekit:end"))
        m.queryText = "Altfassung"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty, "old text never found")
        m.queryText = "Neufassung"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.url.lastPathComponent) == ["Einzeln.pptx"])
    }

    /// A model given its pages (tests, previews) keeps them across a switch.
    @Test(.timeLimit(.minutes(1))) func injectedPagesStay() async throws {
        let pages = OfficePages(cache: SlideCache(root: base.appendingPathComponent("Other", isDirectory: true)))
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Rendering-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(),
                         slideCache: SlideCache(root: base.appendingPathComponent("SlideCache", isDirectory: true)),
                         debounce: .zero, foreignPages: pages, officeRendering: rendering)
        m.officePreferences.powerPointRenderer = .quickLook
        await m.waitUntilIdle()
        #expect(m.foreignPages is OfficePages)
        #expect(m.foreignPagesRevision == 0)
    }

    /// SlideKit draws on demand: a tile without a picture is no slide-cache miss, so no new layout is requested, and
    /// repeated reports of the same file version query the index once.
    @Test(.timeLimit(.minutes(1))) func slidesMissingUnderSlideKitRequestsNoLayout() async throws {
        let d = try OfficeFixtures.pptx(slides: ["Folie eins"], name: "d.pptx", in: eins)
        try Data("kaputt".utf8).write(to: d)                 // unreadable: SlideKit has no pages for it
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        for _ in 0..<3 {
            m.slidesMissing(for: PageRef(url: d, pageIndex: 0))
            await m.waitUntilIdle()
        }
        #expect(idx["eins"]!.layoutRequests.isEmpty)
        #expect(idx["eins"]!.layoutCount == 1)
        #expect(idx["eins"]!.outdatedChecks == ["d.pptx"], "once per file version")
    }

    /// Under SlideKit an edited deck reported by its tile is still indexed again.
    @Test(.timeLimit(.minutes(1))) func slidesMissingUnderSlideKitReindexesAChangedDeck() async throws {
        let d = try OfficeFixtures.pptx(slides: ["Folie eins"], name: "d.pptx", in: eins)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.ocrLog = log                             // phase-1 runs are logged there
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        idx["eins"]!.outdatedPaths = ["d.pptx"]
        m.slidesMissing(for: PageRef(url: d, pageIndex: 0))
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        #expect(idx["eins"]!.layoutRequests.isEmpty)
    }

    /// A layout running at the switch is stopped first (its result belongs to the old renderer).
    @Test(.timeLimit(.minutes(1))) func switchDuringLayoutStopsItAndLaysOutOnceMore() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx, layout: withAdapter())
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        m.officePreferences.powerPointRenderer = .quickLook
        #expect(await eventually { log.entries.contains("eins:layout-cancelled") })
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests == ["adopt:powerpoint"])
        #expect(idx["eins"]!.layoutCount == 2)
    }

    @Test(.timeLimit(.minutes(1))) func switchRelaysOutSinglePowerPointOnly() async throws {
        let pptx = try OfficeFixtures.pptx(slides: ["Folie eins"], name: "Vortrag.pptx", in: base)
        let docx = try OfficeFixtures.docx(paragraphs: ["Bleibt"], name: "Brief.docx", in: base)
        let m = model(layout: withAdapter())
        await m.add([pptx, docx])
        await m.waitUntilIdle()
        #expect(counts.count("Vortrag.pptx") == 1)

        m.officePreferences.powerPointRenderer = .quickLook
        await m.waitUntilIdle()
        #expect(counts.count("Vortrag.pptx") == 2)
        #expect(counts.count("Brief.docx") == 1)
        #expect(m.hits.first { $0.url.lastPathComponent == "Vortrag.pptx" }?.pageCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func sameValueAgainDoesNothing() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        m.officePreferences.powerPointRenderer = .slideKit           // unchanged
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests.isEmpty)
        #expect(idx["eins"]!.layoutCount == 1)
    }
}
