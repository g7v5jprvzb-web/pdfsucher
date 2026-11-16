import CoreGraphics
import Foundation
import IndexKit
import OfficeKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Lays out every Word/PowerPoint single file as one page (no fonts, no Quick Look).
private final class OnePageLayout: PageLayoutSource {
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "Seite \(url.lastPathComponent)", words: [], size: CGSize(width: 100, height: 100))],
                     renderer: "fake", layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("fake", 1) }
}

/// Lays out Word single files with the substitute-font marker (`TextKitWordSource.substituteRenderer`).
private final class SubstituteWordLayout: PageLayoutSource {
    private let count = Mutex(0)
    var layouts: Int { count.withLock { $0 } }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        count.withLock { $0 += 1 }
        return LayoutResult(pages: [LaidOutPage(text: "Ersatz", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: TextKitWordSource.substituteRenderer, layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("textkit", 1) }
}

/// `Thread.isMainThread` of each prewarm call; what the registration answers (done in time or not).
private final class PrewarmCalls: Sendable {
    private let calls = Mutex<[Bool]>([])
    private let answer = Mutex(false)
    func record() -> Bool { calls.withLock { $0.append(Thread.isMainThread) }; return answer.withLock { $0 } }
    var all: [Bool] { calls.withLock { $0 } }
    var succeeds: Bool {
        get { answer.withLock { $0 } }
        set { answer.withLock { $0 = newValue } }
    }
}

/// 1.3.2: Office's fonts are prepared lazily, once, when the first Word/PowerPoint document is laid out (a folder
/// layout run with pending documents, or a single Word/PowerPoint file) or shown (a row in the grid, the preview:
/// `officeDocumentShown`, deferred while the user types), never with „Word/PowerPoint“ off and never for PDFs/images
/// alone; at app start only when a registration once succeeded. Always on a GCD queue, never on the main thread.
@MainActor @Suite("Office font prewarm (lazy)", .serialized)
struct OfficeFontPrewarmTests {
    let base: URL, eins: URL, zwei: URL
    private let calls = PrewarmCalls()

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    var recorded: [Bool] { calls.all }

    func stub(_ m: AppModel) -> AppModel {
        let calls = self.calls
        m.prewarmFonts = { calls.record() }
        m.fontsCompleteLater = { _ in }                      // no late completion unless a test says so
        return m
    }

    func model(_ indexes: [String: FakeIndex] = [:], powerPoint renderer: String? = nil,
               defaults: UserDefaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!,
               layout: any PageLayoutSource = OnePageLayout()) -> AppModel {
        if let renderer { defaults.set(renderer, forKey: "office.powerPointRenderer") }
        return stub(AppModel(settings: makeSettings(), defaults: defaults,
                      environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                      openIndex: { root in indexes[root.lastPathComponent]! }, officeLayout: layout,
                      officeRendering: PowerPointDisplaySetting()))
    }

    /// Each folder keeps its own index file in the test's temp directory.
    func realModel() -> AppModel {
        let base = self.base
        return stub(AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!,
                      environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                      openIndex: { root in
                          try FolderIndex.shared(root: root, indexURL: base.appendingPathComponent(root.lastPathComponent + ".sqlite"),
                                                 slideCache: testSlideCache)
                      },
                      officeRendering: PowerPointDisplaySetting()))
    }

    /// A short grace period for a prewarm that should not come (it would be dispatched asynchronously).
    func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    // MARK: Folders

    @Test(.timeLimit(.minutes(1))) func firstFolderLayoutPrewarmsOnceOffTheMainThread() async throws {
        let idx = ["eins": FakeIndex(), "zwei": FakeIndex()]
        idx["eins"]!.holdUpdates = true
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins])
        // Phase 1 (text) runs: no prewarm yet.
        try await settle()
        #expect(recorded.isEmpty)
        idx["eins"]!.holdUpdates = false
        // The layout run reports its pending documents: the prewarm starts while it still runs.
        #expect(await eventually { recorded.count == 1 })
        #expect(idx["eins"]!.layoutCount == 1)
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        // A later layout (another folder) does not prewarm again.
        await m.add([zwei])
        await m.waitUntilIdle()
        #expect(idx["zwei"]!.layoutCount == 1)
        try await settle()
        #expect(recorded == [false])
    }

    @Test(.timeLimit(.minutes(1))) func folderWithoutOfficeDocumentsDoesNotPrewarm() async throws {
        let index = FakeIndex()
        index.layoutTotal = 0                                // the layout run finds no Word/PowerPoint document
        let m = model(["eins": index])
        m.startMaintenance()
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(index.layoutCount == 1)
        try await settle()
        #expect(recorded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func officeOffNeverPrewarms() async throws {
        let index = FakeIndex()
        let m = model(["eins": index])
        m.officePreferences.includeOffice = false
        let docx = try OfficeFixtures.docx(paragraphs: ["Vertrag"], name: "Vertrag.docx", in: base)
        await m.add([eins, docx])
        await m.waitUntilIdle()
        #expect(index.layoutCount == 0)
        try await settle()
        #expect(recorded.isEmpty)
    }

    /// The real indexer: a folder of PDFs and images only has no layout work, so no prewarm; a folder with a
    /// Word file has.
    @Test(.timeLimit(.minutes(1))) func realIndexPrewarmsOnlyForOfficeDocuments() async throws {
        try PDFFixtures.makePDF(at: eins.appendingPathComponent("a.pdf"), pages: ["Ein Vertrag"])
        let m = realModel()
        await m.add([eins])
        await m.waitUntilIdle()
        try await settle()
        #expect(recorded.isEmpty)

        _ = try OfficeFixtures.docx(paragraphs: ["Die Kündigungsfrist"], name: "b.docx", in: zwei)
        await m.add([zwei])
        await m.waitUntilIdle()
        #expect(await eventually { recorded.count == 1 })
        #expect(recorded == [false])
    }

    /// The macOS prompt must never come in the middle of a search: searching and browsing an index whose Word and
    /// PowerPoint documents are laid out already (no layout work) never prewarm by themselves (shown documents do,
    /// but only once typing has paused: `typingDefersTheStartUntilInputIsIdle`).
    @Test(.timeLimit(.minutes(1))) func searchingAndBrowsingNeverPrewarm() async throws {
        let index = FakeIndex()
        index.layoutTotal = 0                                // laid out on an earlier launch
        let root = eins.path
        index.hits = [doc("Vertrag.docx", pages: [0], root: root), doc("Folien.pptx", pages: [0, 1], root: root)]
        index.browseList = index.hits
        let m = model(["eins": index])
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(m.hits.count == 2)                           // browsing
        for query in ["V", "Ve", "Vertrag", "Folien"] {      // typing
            m.queryText = query
            await m.waitUntilIdle()
        }
        #expect(index.searchCount > 0)
        try await settle()
        #expect(recorded.isEmpty)
    }

    // MARK: Single files

    @Test(.timeLimit(.minutes(1))) func singleOfficeFilePrewarmsOnce() async throws {
        let m = model()
        let pdf = base.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Nur ein PDF"])
        await m.add([pdf])
        await m.waitUntilIdle()
        try await settle()
        #expect(recorded.isEmpty)                            // a PDF single file needs no Office fonts

        let docx = try OfficeFixtures.docx(paragraphs: ["Vertrag"], name: "Vertrag.docx", in: base)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(await eventually { recorded.count == 1 })
        let pptx = try OfficeFixtures.pptx(slides: ["Folie"], name: "Folien.pptx", in: base)
        await m.add([pptx])
        await m.waitUntilIdle()
        try await settle()
        #expect(recorded == [false])
    }

    /// A PowerPoint single file under Quick Look needs no Office fonts (Quick Look draws it); a Word file still does.
    @Test(.timeLimit(.minutes(1))) func singleDeckUnderQuickLookDoesNotPrewarm() async throws {
        let m = model(powerPoint: "quickLook")
        let pptx = try OfficeFixtures.pptx(slides: ["Folie"], name: "Folien.pptx", in: base)
        await m.add([pptx])
        await m.waitUntilIdle()
        try await settle()
        #expect(recorded.isEmpty)
        let docx = try OfficeFixtures.docx(paragraphs: ["Vertrag"], name: "Vertrag.docx", in: base)
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(await eventually { recorded.count == 1 })
    }

    // MARK: Shown documents (fonts-start a, c)

    /// After a restart with nothing to lay out, a Word document or a SlideKit deck in the grid or the preview starts
    /// the registration: once, off the main thread; PDFs, images, decks under Quick Look and „Word/PowerPoint“ off do not.
    @Test(.timeLimit(.minutes(1))) func shownWordDocumentStartsTheFontsOnce() async throws {
        let m = model()
        m.officeDocumentShown(base.appendingPathComponent("a.pdf"))
        m.officeDocumentShown(base.appendingPathComponent("b.png"))
        try await settle()
        #expect(recorded.isEmpty)
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually { recorded.count == 1 })
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        m.officeDocumentShown(base.appendingPathComponent("Anderer.docx"))
        try await settle()
        #expect(recorded == [false])
    }

    @Test(.timeLimit(.minutes(1))) func shownSlideKitDeckStartsTheFonts() async throws {
        let m = model()
        m.officeDocumentShown(base.appendingPathComponent("Folien.pptx"))
        #expect(await eventually { recorded.count == 1 })
    }

    @Test(.timeLimit(.minutes(1))) func shownDeckUnderQuickLookOrOfficeOffDoesNotStart() async throws {
        let quickLook = model(powerPoint: "quickLook")
        quickLook.officeDocumentShown(base.appendingPathComponent("Folien.pptx"))
        let off = model()
        off.officePreferences.includeOffice = false
        off.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        try await settle()
        #expect(recorded.isEmpty)
    }

    /// Adapted `searchingAndBrowsingNeverPrewarm`: the prompt must not pop up mid-typing. A start asked for while the
    /// user types waits until the search field has been idle for `typingIdleDelay` (≈ 1 s in the app).
    @Test(.timeLimit(.minutes(1))) func typingDefersTheStartUntilInputIsIdle() async throws {
        let m = model()
        m.typingIdleDelay = .milliseconds(400)
        m.queryText = "V"
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        var lastKey = ContinuousClock.now
        for query in ["Ve", "Ver", "Vert"] {
            try await Task.sleep(for: .milliseconds(150))
            #expect(recorded.isEmpty, "still typing")
            m.queryText = query
            lastKey = .now
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorded.isEmpty, "only 150 ms idle")
        #expect(await eventually { recorded.count == 1 })
        #expect(ContinuousClock.now - lastKey >= .milliseconds(400))
        #expect(recorded == [false])
    }

    /// Without typing a shown document starts at once (no idle wait).
    @Test(.timeLimit(.minutes(1))) func withoutTypingTheStartIsImmediate() async throws {
        let m = model()
        m.typingIdleDelay = .seconds(30)
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually(.seconds(2)) { recorded.count == 1 })
    }

    // MARK: Launch (fonts-start b)

    /// A registration that once succeeded is started at launch (off the main thread); one that never did (timeout,
    /// denial, first launch) is not – the prompt keeps coming only with Office documents.
    @Test(.timeLimit(.minutes(1))) func launchStartsTheFontsOnlyAfterAnEarlierSuccess() async throws {
        let fresh = model()
        fresh.startOfficeFontsIfRegisteredBefore()
        try await settle()
        #expect(recorded.isEmpty)

        let defaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppModel.fontsRegisteredOnceKey)
        let off = model(defaults: defaults)
        off.officePreferences.includeOffice = false
        off.startOfficeFontsIfRegisteredBefore()
        try await settle()
        #expect(recorded.isEmpty)

        let knownDefaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!   // „Word/PowerPoint“ on
        knownDefaults.set(true, forKey: AppModel.fontsRegisteredOnceKey)
        let known = model(defaults: knownDefaults)
        known.startOfficeFontsIfRegisteredBefore()
        #expect(await eventually { recorded.count == 1 })
        #expect(recorded == [false])
    }

    @Test(.timeLimit(.minutes(1))) func onlyASuccessfulRegistrationIsRemembered() async throws {
        let failedDefaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!
        calls.succeeds = false
        let failed = model(defaults: failedDefaults)
        failed.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually { recorded.count == 1 })
        try await settle()
        #expect(failedDefaults.object(forKey: AppModel.fontsRegisteredOnceKey) == nil)

        let goodDefaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!
        calls.succeeds = true
        let good = model(defaults: goodDefaults)
        good.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually { goodDefaults.bool(forKey: AppModel.fontsRegisteredOnceKey) })
    }

    // MARK: After the registration (fonts-start d, e)

    /// A successful registration reloads Word tiles and the preview once (`foreignPagesRevision`) when a Word document
    /// was shown before, and gives every folder a layout run (the Indexer lays out documents stored with substitute
    /// fonts again).
    @Test(.timeLimit(.minutes(1))) func successReloadsShownWordPagesAndLaysOutFoldersAgain() async throws {
        let index = FakeIndex(), clean = FakeIndex()
        index.layoutTotal = 0
        clean.layoutTotal = 0
        index.storedRenderers = [TextKitWordSource.substituteRenderer]
        clean.storedRenderers = ["textkit"]
        calls.succeeds = true
        let m = model(["eins": index, "zwei": clean])
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(index.layoutCount == 1 && clean.layoutCount == 1)
        let revision = m.foreignPagesRevision
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually { m.foreignPagesRevision == revision + 1 })
        #expect(await eventually { index.layoutCount == 2 })
        await m.waitUntilIdle()
        try await settle()
        #expect(m.foreignPagesRevision == revision + 1, "once")
        #expect(clean.layoutCount == 1, "no substitute layouts stored: no extra run")
    }

    /// Decks shown before the fonts (office-speed: SlideKit tiles no longer wait for the registration, they draw
    /// substitutes): the tiles are loaded again once, like Word's.
    @Test(.timeLimit(.minutes(1))) func successAfterDecksShownReloadsTilesOnce() async throws {
        calls.succeeds = true
        let defaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!
        let m = model(defaults: defaults)
        let revision = m.foreignPagesRevision
        m.officeDocumentShown(base.appendingPathComponent("Folien.pptx"))
        #expect(await eventually { defaults.bool(forKey: AppModel.fontsRegisteredOnceKey) })
        try await settle()
        #expect(m.foreignPagesRevision == revision + 1)
    }

    /// A Word single file laid out with substitute fonts is laid out again after a successful registration.
    @Test(.timeLimit(.minutes(1))) func wordSingleFileWithSubstituteFontsIsLaidOutAgain() async throws {
        let layout = SubstituteWordLayout()
        let m = model(layout: layout)
        let docx = try OfficeFixtures.docx(paragraphs: ["Vertrag"], name: "Vertrag.docx", in: base)
        calls.succeeds = false                               // the layout's own start misses the deadline
        await m.add([docx])
        await m.waitUntilIdle()
        #expect(layout.layouts == 1)
        #expect(await eventually { recorded.count == 1 })
        // The registration finishes later (the success path, as the prewarm reports it).
        m.fontsRegistered()
        await m.waitUntilIdle()
        #expect(await eventually { layout.layouts == 2 })
    }

    /// The waiter's deadline passed, but the registration completes later (fonts-start c of the review): the same
    /// success handling runs then.
    @Test(.timeLimit(.minutes(1))) func lateCompletionCountsAsSuccess() async throws {
        let defaults = UserDefaults(suiteName: "FontPrewarm-\(UUID().uuidString)")!
        calls.succeeds = false
        let m = model(defaults: defaults)
        let later = Mutex<(@Sendable () -> Void)?>(nil)
        m.fontsCompleteLater = { body in later.withLock { $0 = body } }
        m.officeDocumentShown(base.appendingPathComponent("Vertrag.docx"))
        #expect(await eventually { later.withLock { $0 } != nil })
        try await settle()
        #expect(defaults.object(forKey: AppModel.fontsRegisteredOnceKey) == nil)
        later.withLock { $0 }?()
        #expect(await eventually { defaults.bool(forKey: AppModel.fontsRegisteredOnceKey) })
    }
}
