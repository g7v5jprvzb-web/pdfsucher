import CoreGraphics
import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Lays out every Word/PowerPoint file as one page (no Quick Look, no cache) and counts the runs per file name.
private final class CountingLayout: PageLayoutSource {
    private let counts = Mutex([String: Int]())
    func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }

    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        counts.withLock { $0[url.lastPathComponent, default: 0] += 1 }
        return LayoutResult(pages: [LaidOutPage(text: "Folie \(url.lastPathComponent)", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: "fake", layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("fake", 1) }
}

/// A gate the maintenance waits behind until the test opens it (20 s safety deadline like the fakes).
private final class Gate: Sendable {
    private let isOpen = Mutex(false)
    func open() { isOpen.withLock { $0 = true } }
    func wait() async {
        let deadline = ContinuousClock.now + fakeHoldDeadline
        while !isOpen.withLock({ $0 }) {
            if ContinuousClock.now > deadline { Issue.record("maintenance gate was never opened"); return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// 1.3 Teil B Task 9: slide cache maintenance at start, „Folien-Cache leeren“, and slides missing from the cache;
/// plus the single-file priority over folder layout (core review I3).
@MainActor @Suite("Slide cache maintenance", .serialized)
struct SlideCacheMaintenanceTests {
    let base: URL, eins: URL, zwei: URL, leftovers: URL
    let cache: SlideCache
    let cacheRoot: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        leftovers = base.appendingPathComponent("QL", isDirectory: true)
        for dir in [eins, zwei, leftovers] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        cacheRoot = base.appendingPathComponent("SlideCache", isDirectory: true)
        cache = SlideCache(root: cacheRoot)
    }

    func indexes(_ names: [String], log: StringLog) -> [String: FakeIndex] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            index.layoutLog = log
            return (name, index)
        })
    }

    func model(_ indexes: [String: FakeIndex] = [:], layout: (any PageLayoutSource)? = nil,
               cache: SlideCache? = nil, renderer: String = "quickLook") -> AppModel {
        // Slide cache maintenance belongs to Quick Look („PowerPoint-Darstellung“; SlideKit draws without a cache).
        let defaults = UserDefaults(suiteName: "SlideMaint-\(UUID().uuidString)")!
        defaults.set(renderer, forKey: "office.powerPointRenderer")
        let m = AppModel(settings: makeSettings(), defaults: defaults,
                         environment: FakeEnvironment(), slideCache: cache ?? self.cache, debounce: .zero,
                         openIndex: { root in indexes[root.lastPathComponent]! }, officeLayout: layout,
                         officeRendering: PowerPointDisplaySetting())
        m.quickLookLeftoverRoot = leftovers
        m.prewarmFonts = { false }                                 // no Office font cache access from these tests
        m.fontsCompleteLater = { _ in }
        return m
    }

    /// The key `OfficePages`/`QuickLookSlideSource` use for `url` (size and date of the resolved file).
    func key(_ url: URL) throws -> SlideCacheKey {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SlideCacheKey(url: url, fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    @discardableResult
    func storeSlides(for url: URL) throws -> SlideCacheKey {
        let k = try key(url)
        try cache.store([try ImageFixtures.render(text: "Folie", size: CGSize(width: 100, height: 60))], for: k)
        return k
    }

    func deck(_ name: String, in folder: URL) throws -> URL {
        try OfficeFixtures.pptx(slides: ["Folie eins"], name: name, in: folder)
    }

    func setDate(_ url: URL, daysAgo days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
    }

    func cacheNames() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []).sorted() }

    // MARK: Start

    @Test(.timeLimit(.minutes(1))) func startSweepsAndPrunesByAge() async throws {
        let old = try storeSlides(for: try deck("alt.pptx", in: base))
        let fresh = try storeSlides(for: try deck("neu.pptx", in: base))
        try setDate(cacheRoot.appendingPathComponent(old.id), daysAgo: 200)
        // A writer that crashed two days ago, and one still writing (its folder changes with every slide).
        let crashed = try cache.beginEntry(for: try key(try deck("abgestuerzt.pptx", in: base)))
        try crashed.append(try ImageFixtures.render(text: "x", size: CGSize(width: 10, height: 10)))
        let crashedTmp = try #require(cacheNames().first { $0.hasSuffix(".tmp") })
        try setDate(cacheRoot.appendingPathComponent(crashedTmp), daysAgo: 2)
        let writing = try cache.beginEntry(for: try key(try deck("offen.pptx", in: base)))
        try writing.append(try ImageFixtures.render(text: "x", size: CGSize(width: 10, height: 10)))
        // Quick Look leftovers: an old one of a crashed run, a young one of a run still working.
        let oldPreview = leftovers.appendingPathComponent("alt", isDirectory: true)
        let youngPreview = leftovers.appendingPathComponent("jung", isDirectory: true)
        for dir in [oldPreview, youngPreview] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try setDate(oldPreview, daysAgo: 1)

        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        let gate = Gate()
        m.maintenanceGate = { await gate.wait() }
        m.startMaintenance()
        m.startMaintenance()                                  // once per model
        await m.add([eins])
        #expect(await eventually { log.entries.contains("eins:update-end") })
        try await Task.sleep(for: .milliseconds(100))
        #expect(idx["eins"]!.layoutCount == 0, "the layout waits for the maintenance")
        gate.open()
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 1)
        #expect(cache.slideCount(for: old) == nil)
        #expect(cache.slideCount(for: fresh) == 1)
        #expect(!cacheNames().contains(crashedTmp))
        #expect(cacheNames().filter { $0.hasSuffix(".tmp") }.count == 1)       // the young writer's folder stays
        try writing.commit()
        #expect(!FileManager.default.fileExists(atPath: oldPreview.path))
        #expect(FileManager.default.fileExists(atPath: youngPreview.path))
    }

    /// Hardening 1: while the maintenance runs, only layout steps wait — new folders (phase 1) and dropped scans
    /// (single-file recognition) go on.
    @Test(.timeLimit(.minutes(1))) func maintenanceHoldsOnlyLayoutSteps() async throws {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        let m = model(idx)
        let gate = Gate()
        m.maintenanceGate = { await gate.wait() }
        m.startMaintenance()
        await m.add([eins])
        #expect(await eventually { log.entries.contains("eins:update-end") })
        let photo = base.appendingPathComponent("beleg.png")
        try OCRFixtures.write(try OCRFixtures.textImage(["Quittung Kündigung"]).image, to: photo, type: .png)
        await m.add([photo])
        m.queryText = "Quittung"
        #expect(await eventually(.seconds(20)) { m.hits.contains { $0.url.lastPathComponent == "beleg.png" } },
                "the scan is recognized while the maintenance still runs")
        await m.add([zwei])
        #expect(await eventually { log.entries.contains("zwei:update-end") }, "a new folder is indexed meanwhile")
        #expect(idx["eins"]!.layoutCount == 0 && idx["zwei"]!.layoutCount == 0)
        gate.open()
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 1 && idx["zwei"]!.layoutCount == 1)
    }

    /// Hardening 7: a maintenance whose cache cannot be read (root is a file) only logs; the queue goes on.
    @Test(.timeLimit(.minutes(1))) func queueContinuesWhenMaintenanceFails() async throws {
        let broken = base.appendingPathComponent("kaputt")
        try Data("kein Ordner".utf8).write(to: broken)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx, cache: SlideCache(root: broken))
        m.startMaintenance()
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 1)
        #expect(m.alertMessage == nil)
    }

    /// 1.3.2: no Office font prewarm at start any more (reading Office's font cache made macOS ask for data of other apps at
    /// every launch); it starts lazily with the first Word/PowerPoint layout (`OfficeFontPrewarmTests`).
    @Test(.timeLimit(.minutes(1))) func startDoesNotPrewarmOfficeFonts() async throws {
        let calls = Mutex<[Bool]>([])
        let m = model()
        m.prewarmFonts = { calls.withLock { $0.append(Thread.isMainThread) }; return false }
        m.fontsCompleteLater = { _ in }
        m.startMaintenance()
        await m.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.withLock { $0 }.isEmpty)
    }

    // MARK: „Folien-Cache leeren“

    @Test(.timeLimit(.minutes(1))) func clearRequestsPowerPointRelayoutEverywhere() async throws {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        try storeSlides(for: try deck("a.pptx", in: eins))
        let revision = m.layoutRevision

        await m.clearSlideCache()
        await m.waitUntilIdle()
        #expect(cacheNames().isEmpty)
        #expect(m.alertMessage == nil)
        for name in ["eins", "zwei"] {
            #expect(idx[name]!.layoutRequests == ["kind:powerpoint"])
            #expect(idx[name]!.layoutCount == 2)
        }
        #expect(m.layoutRevision > revision)
    }

    /// Final review: under the own viewer (default) the slide cache only holds old Quick Look pictures; clearing it
    /// frees disk space and touches no layout (no stop, no relayout).
    @Test(.timeLimit(.minutes(1))) func clearUnderSlideKitOnlyFreesTheCache() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx, renderer: "slideKit")
        try storeSlides(for: try deck("a.pptx", in: eins))
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })

        await m.clearSlideCache()                          // while a layout runs: it is not stopped
        #expect(cacheNames().isEmpty)
        #expect(m.alertMessage == nil)
        #expect(!log.entries.contains("eins:layout-cancelled"))
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(!log.entries.contains("eins:layout-cancelled"))
        #expect(idx["eins"]!.layoutRequests.isEmpty)
        #expect(idx["eins"]!.layoutCount == 1)
    }

    /// Review Focus 4: clearing while a deck is being laid out stops that run, leaves no half entry and no `.tmp`
    /// folder, and lays out every folder exactly once more.
    @Test(.timeLimit(.minutes(1))) func clearingCacheDuringLayoutRelaysOutOnce() async throws {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins, zwei])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        try storeSlides(for: try deck("fertig.pptx", in: eins))
        // The deck being laid out right now has written one slide into its writer.
        let half = try deck("halb.pptx", in: eins)
        let writer = try cache.beginEntry(for: try key(half))
        try writer.append(try ImageFixtures.render(text: "x", size: CGSize(width: 10, height: 10)))

        await m.clearSlideCache()
        #expect(log.entries.contains("eins:layout-cancelled"))
        #expect(cacheNames().isEmpty, "no entry and no .tmp folder left")
        #expect(throws: (any Error).self) { try writer.commit() }
        #expect(cache.slideCount(for: try key(half)) == nil, "no half entry")
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests == ["kind:powerpoint"])
        #expect(idx["zwei"]!.layoutRequests == ["kind:powerpoint"])
        #expect(idx["eins"]!.layoutCount == 2)                // the stopped run + one new
        #expect(idx["zwei"]!.layoutCount == 1)                // it was still waiting: one run
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 2)
        #expect(idx["zwei"]!.layoutCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func clearRelaysOutSinglePowerPoint() async throws {
        let pptx = try deck("Vortrag.pptx", in: base)
        let docx = try OfficeFixtures.docx(paragraphs: ["Bleibt"], name: "Brief.docx", in: base)
        let layout = CountingLayout()
        let m = model(layout: layout)
        await m.add([pptx, docx])
        await m.waitUntilIdle()
        #expect(layout.count("Vortrag.pptx") == 1)

        await m.clearSlideCache()
        await m.waitUntilIdle()
        #expect(layout.count("Vortrag.pptx") == 2)
        #expect(layout.count("Brief.docx") == 1)              // Word has no slides in the cache
        #expect(m.hits.first { $0.url.lastPathComponent == "Vortrag.pptx" }?.pageCount == 1)
    }

    /// Hardening 4: with text recognition off a dropped scan has nothing to do, so it does not stop the layout.
    @Test(.timeLimit(.minutes(1))) func singleScanDoesNotPreemptLayoutWhenRecognitionIsOff() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        m.ocrPreferences.recognizeText = false
        await m.waitUntilIdle()
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        let pdf = base.appendingPathComponent("scan.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Seite"])
        await m.add([pdf])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!log.entries.contains("eins:layout-cancelled"))
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutCount == 1)
    }

    // MARK: Slides missing from the cache

    @Test(.timeLimit(.minutes(1))) func slidesMissingRequestsOnce() async throws {
        let d = try deck("d.pptx", in: eins)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()

        // Tiles report up to once a second each.
        for page in 0..<3 { m.slidesMissing(for: PageRef(url: d, pageIndex: page % 2)) }
        await m.waitUntilIdle()
        m.slidesMissing(for: PageRef(url: d, pageIndex: 0))
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests == ["path:d.pptx"])
        #expect(idx["eins"]!.layoutCount == 2)
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 1)
    }

    /// Protects against loops while the tile does not show the cached slide yet.
    @Test(.timeLimit(.minutes(1))) func slidesMissingIgnoredWhenCacheHasEntry() async throws {
        let d = try deck("d.pptx", in: eins)
        try storeSlides(for: d)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()

        m.slidesMissing(for: PageRef(url: d, pageIndex: 0))
        await m.waitUntilIdle()
        #expect(idx["eins"]!.layoutRequests.isEmpty)
        #expect(idx["eins"]!.layoutCount == 1)
    }

    /// Core review I2: a deck edited during the session (folders are not rescanned) is indexed again.
    @Test(.timeLimit(.minutes(1))) func slidesMissingOfChangedDeckIndexesFolderAgain() async throws {
        let d = try deck("d.pptx", in: eins)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()

        idx["eins"]!.outdatedPaths = ["d.pptx"]              // the index still has the old size/date
        m.slidesMissing(for: PageRef(url: d, pageIndex: 0))
        m.slidesMissing(for: PageRef(url: d, pageIndex: 1))
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        #expect(idx["eins"]!.layoutRequests.isEmpty)          // phase 1 marks the changed deck itself
        m.slidesMissing(for: PageRef(url: d, pageIndex: 0))   // same file version: nothing more
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func slidesMissingRelaysOutSingleDeckOnce() async throws {
        let pptx = try deck("Vortrag.pptx", in: base)
        let layout = CountingLayout()
        let m = model(layout: layout)
        await m.add([pptx])
        await m.waitUntilIdle()
        #expect(layout.count("Vortrag.pptx") == 1)

        m.slidesMissing(for: PageRef(url: pptx, pageIndex: 0))
        m.slidesMissing(for: PageRef(url: pptx, pageIndex: 0))
        await m.waitUntilIdle()
        #expect(layout.count("Vortrag.pptx") == 2)
        m.slidesMissing(for: PageRef(url: pptx, pageIndex: 0))
        await m.waitUntilIdle()
        #expect(layout.count("Vortrag.pptx") == 2)
        #expect(m.hits.first?.pageCount == 1)
    }

    /// Core review I2 for Word: a document edited in a folder shows no old word boxes and is indexed again (once).
    @Test(.timeLimit(.minutes(1))) func changedWordDocumentInFolderIsIndexedAgain() async throws {
        let word = try OfficeFixtures.docx(paragraphs: ["Angebot"], name: "w.docx", in: eins)
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()

        idx["eins"]!.outdatedPaths = ["w.docx"]
        #expect(await m.ocrText(for: PageRef(url: word, pageIndex: 0)) == nil)
        #expect(await m.ocrText(for: PageRef(url: word, pageIndex: 1)) == nil)
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        // PDFs are not checked (their tiles have no layout).
        let pdf = eins.appendingPathComponent("p.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Seite"])
        _ = await m.ocrText(for: PageRef(url: pdf, pageIndex: 0))
        #expect(!idx["eins"]!.outdatedChecks.contains("p.pdf"))
    }

    // MARK: Single files first (core review I3)

    /// A scan or image dropped in during a folder's layout is recognized first; the folder's layout resumes after it.
    @Test(.timeLimit(.minutes(1))) func singlePDFRecognitionPreemptsFolderLayout() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdLayout = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:layout-start" })
        let photo = base.appendingPathComponent("beleg.png")
        try OCRFixtures.write(try OCRFixtures.textImage(["Quittung Kündigung"]).image, to: photo, type: .png)
        await m.add([photo])
        m.queryText = "Quittung"
        #expect(await eventually(.seconds(20)) { m.hits.contains { $0.url.lastPathComponent == "beleg.png" } },
                "the photo is found while the folder's layout is still held")
        #expect(log.entries.contains("eins:layout-cancelled"))
        idx["eins"]!.holdLayout = false
        await m.waitUntilIdle()
        #expect(log.entries.filter { $0 == "eins:layout-end" }.count == 1)
        #expect(log.entries.last == "eins:ocr-end")
    }
}
