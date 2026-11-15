import AppKit
import Foundation
import IndexKit
import OfficeKit
import OutputKit
import PDFKit
import SearchKit
import SlideKitAdapter
import Synchronization
import SwiftUI
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Screenshots of the real window content (AppModel + real index + ContentShell + Highlighter)
/// without UI automation: a real window captured with `screencapture -l` (as in Phase 4).
/// Opt-in: `PDFSUCHER_APPSHOTS=$PWD/docs/screenshots scripts/test.sh --filter AppScreenshotTests`
@MainActor @Suite("App screenshots", .serialized)
struct AppScreenshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"] != nil))
    func screenshots() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Dokumente", isDirectory: true)
        try ScreenshotFixtures.make(in: folder)
        let indexURL = base.appendingPathComponent("index.sqlite")

        _ = NSApplication.shared
        let settings = GridSettings(defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!)
        let model = AppModel(settings: settings, defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!,
                             environment: NoEnvironment(), slideCache: testSlideCache, debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
        await model.open(folder: folder)
        await model.waitUntilIdle()

        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1280, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "PDFSucher"
        window.contentView = NSHostingView(rootView: ContentShell(model: model, highlighter: Highlighter.make))
        window.orderFrontRegardless()

        func focusFirstHit(of name: String? = nil) {
            let hit = name.flatMap { n in model.hits.first { $0.url.lastPathComponent == n } } ?? model.hits.first
            if let hit { model.focusedPage = PageRef(url: hit.url, pageIndex: hit.pageHits[0].pageIndex) }
        }
        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(3))      // thumbnails render off the main actor
            let out = output.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "screencapture \(name)")
            #expect(FileManager.default.fileExists(atPath: out.path))
        }

        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.count == 5)
        focusFirstHit()
        settings.columnsMode = .fixed
        settings.columns = 5
        try await shoot("01-treffer-fest-5-seiten.png")

        settings.columnsMode = .automatic
        try await shoot("02-treffer-automatisch.png")
        settings.columnsMode = .fixed

        model.queryText = "Mietvertrag"
        await model.waitUntilIdle()
        focusFirstHit(of: "Uebergabeprotokoll.pdf")
        #expect(model.focusedPage?.url.lastPathComponent == "Uebergabeprotokoll.pdf")
        try await shoot("03-getrenntes-wort-markiert.png")
        window.close()
    }

    /// 1.3 Teil B core smoke run: real AppModel, FolderIndex/Indexer, OfficeLayoutSource (Quick Look + TextKit),
    /// ThumbnailCache with the Office hook; slide cache, tile disk cache and index in a temp folder.
    /// Opt-in: `PDFSUCHER_APPSHOTS=$PWD/docs/screenshots/office scripts/test.sh --filter AppScreenshotTests/officeScreenshots`.
    /// Copies `test.docx`/`test.pptx` from `PDFSUCHER_OFFICE_IN` (default `~/Developer/PDFSucher-spikes/office/in`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"] != nil))
    func officeScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: env["PDFSUCHER_APPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Dokumente", isDirectory: true).standardizedFileURL
        try ScreenshotFixtures.makeOffice(in: folder)
        let spikes = URL(fileURLWithPath: env["PDFSUCHER_OFFICE_IN"]
                         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/PDFSucher-spikes/office/in").path)
        let examples = folder.appendingPathComponent("Beispiele", isDirectory: true)
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        for name in ["test.docx", "test.pptx"] {
            let source = spikes.appendingPathComponent(name)
            try #require(FileManager.default.fileExists(atPath: source.path), "\(source.path) fehlt")
            try FileManager.default.copyItem(at: source, to: examples.appendingPathComponent(name))
        }
        let slides = SlideCache(root: base.appendingPathComponent("SlideCache", isDirectory: true))
        let tiles = TileDiskCache(directory: base.appendingPathComponent("Tiles", isDirectory: true))
        let index = try FolderIndex(root: folder, indexURL: base.appendingPathComponent("index.sqlite"),
                                    makeLayout: { OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: slides)) })
        let clock = ContinuousClock()
        let start = clock.now
        let foreign = RecordingForeignPages(OfficePages(cache: slides), clock: clock)
        let environment = FakeEnvironment()

        _ = NSApplication.shared
        let settings = GridSettings(defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!)
        settings.columnsMode = .fixed
        settings.columns = 4
        settings.previewPosition = .trailing      // several rows with tiles next to the large preview
        let model = AppModel(settings: settings, defaults: UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!,
                             environment: environment, slideCache: testSlideCache, debounce: .zero, openIndex: { _ in index },
                             officeLayout: OfficeLayoutSource(powerpoint: QuickLookSlideSource(cache: slides)),
                             foreignPages: foreign, officeRendering: PowerPointDisplaySetting())
        model.tileDisk = tiles

        // The window is up from the start (browsing, no query), so Office tiles are asked for as the layout lands.
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1280, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "PDFSucher"
        window.contentView = NSHostingView(rootView: ContentShell(model: model, highlighter: Highlighter.make, tileDisk: tiles))
        window.orderFrontRegardless()

        let statuses = StatusLog()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                statuses.note(model.indexStatus, at: clock.now)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await model.open(folder: folder)
        await model.waitUntilIdle()
        let idle = clock.now
        try await Task.sleep(for: .seconds(3))
        poll.cancel()

        func ms(_ d: Duration) -> Int { Int((Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded()) }
        let sequence = statuses.entries.map { "\(ms($0.at - start))ms \(ViewerText.indexStatus($0.status) ?? "–")" }
        print("OFFICE-SMOKE status sequence:\n  " + sequence.joined(separator: "\n  "))
        let laidOut = statuses.entries.contains { if case .layingOut = $0.status { true } else { false } }
        #expect(laidOut, "Statuszeile zeigte nie „Word/PowerPoint …“")
        #expect(sequence.contains { $0.contains("Word/PowerPoint") })
        let lastLayout = statuses.entries.lastIndex { if case .layingOut = $0.status { true } else { false } }
        let layoutDone = lastLayout.flatMap { $0 + 1 < statuses.entries.count ? statuses.entries[$0 + 1].at : nil } ?? idle
        let tileEvents = foreign.events.filter { $0.maxPixel != nil && $0.ok }
        print("OFFICE-SMOKE pipeline to idle: \(ms(idle - start)) ms, layout done at \(ms(layoutDone - start)) ms")
        for name in ["Rahmenvertrag.docx", "Vertragsübersicht.pptx", "test.docx", "test.pptx"] {
            let first = tileEvents.first { $0.ref.url.lastPathComponent == name }
            print("OFFICE-SMOKE first tile \(name): " + (first.map { "\(ms($0.at - start)) ms (\(ms($0.at - layoutDone)) ms after layout done, provider \(ms($0.took)) ms)" } ?? "none"))
        }
        if let first = tileEvents.first {
            print("OFFICE-SMOKE first Office tile: \(ms(first.at - layoutDone)) ms after layout done")
        }
        #expect(!tileEvents.isEmpty, "keine Office-Kachel")
        print("OFFICE-SMOKE backingScaleFactor \(window.backingScaleFactor)")

        func focus(_ name: String, page: Int? = nil) {
            guard let hit = model.hits.first(where: { $0.url.lastPathComponent == name }) else { Issue.record("\(name) fehlt"); return }
            model.focusedPage = PageRef(url: hit.url, pageIndex: page ?? hit.pageHits.first?.pageIndex ?? 0)
        }
        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(4))      // thumbnails and the Office preview render off the main actor
            let out = output.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "screencapture \(name)")
        }

        // 1. Hits for „Kündigungsfrist“: PDF, Word („vereinfacht“), PowerPoint.
        let searchStart = clock.now
        model.queryText = "Kündigungsfrist"
        await model.waitUntilIdle()
        print("OFFICE-SMOKE search „Kündigungsfrist“ (first): \(ms(clock.now - searchStart)) ms, \(model.hits.count) documents")
        let names = Set(model.hits.map(\.url.lastPathComponent))
        #expect(names == ["Mietvertrag_Buero_2024.pdf", "Rahmenvertrag.docx", "Vertragsübersicht.pptx", "test.docx", "test.pptx"])
        let word = try #require(model.hits.first { $0.url.lastPathComponent == "Rahmenvertrag.docx" })
        let deck = try #require(model.hits.first { $0.url.lastPathComponent == "Vertragsübersicht.pptx" })
        let pdf = try #require(model.hits.first { $0.url.lastPathComponent == "Mietvertrag_Buero_2024.pdf" })
        #expect(word.kind == .word && word.isSimplified)
        #expect(word.pageHits.map(\.pageIndex) == [1])
        #expect(deck.kind == .powerpoint && !deck.isSimplified)
        #expect(deck.pageCount == 3, "ausgeblendete Folie gehört nicht dazu")
        #expect(deck.pageHits.map(\.pageIndex) == [1], "nur die sichtbare Folie 2")
        // Slide highlights come from the stored word boxes (folder name with an umlaut).
        let slideWords = await model.ocrText(for: PageRef(url: deck.url, pageIndex: 1))?.words.count ?? 0
        #expect(slideWords > 0, "keine Wortrahmen für die Folie")
        focus("Mietvertrag_Buero_2024.pdf")
        try await shoot("office-01-treffer.png")

        // 2. Browsing without a query.
        model.queryText = ""
        await model.waitUntilIdle()
        focus("test.pptx", page: 0)
        try await shoot("office-02-durchblaettern.png")

        // 3./4. Large preview of the slide hit and the Word page hit.
        model.queryText = "Kündigungsfrist"
        await model.waitUntilIdle()
        focus("Vertragsübersicht.pptx")
        try await shoot("office-03-vorschau-folie.png")
        focus("Rahmenvertrag.docx")
        try await shoot("office-04-vorschau-word.png")
        let previews = foreign.events.filter { $0.maxPixel == nil }
        print("OFFICE-SMOKE preview documents: " + previews.map { "\($0.ref.url.lastPathComponent)#\($0.ref.pageIndex) ok=\($0.ok) \(ms($0.took)) ms" }.joined(separator: ", "))

        // Double-click routing: Office originals go to the default app, PDFs to Preview.
        model.openInPreview(PageRef(url: word.url, pageIndex: 1))
        model.openInPreview(PageRef(url: deck.url, pageIndex: 1))
        model.openInPreview(PageRef(url: pdf.url, pageIndex: 1))
        #expect(environment.openedWithDefaultApp == [word.url, deck.url])
        #expect(environment.opened == [pdf.url])

        // Saving a mixed selection: the Word page keeps its text.
        let saved = base.appendingPathComponent("Auswahl.pdf")
        environment.saveURL = saved
        let picked = [PageRef(url: pdf.url, pageIndex: 1), PageRef(url: word.url, pageIndex: 1), PageRef(url: deck.url, pageIndex: 1)]
        for ref in picked { model.selection.toggle(ref) }
        let order = model.selection.ordered(documentOrder: model.hits.map(\.url))
        let saveStart = clock.now
        model.saveSelection()
        await model.waitUntilIdle()
        let merged = try #require(PDFDocument(url: saved))
        #expect(merged.pageCount == 3)
        if let wordAt = order.firstIndex(of: picked[1]), let page = merged.page(at: wordAt) {
            let text = page.string ?? ""
            print("OFFICE-SMOKE saved \(merged.pageCount) pages in \(ms(clock.now - saveStart)) ms; Word page \(wordAt + 1) text: \(text.prefix(80))")
            #expect(text.contains("Kündigungsfrist"))
        } else { Issue.record("Word-Seite fehlt in der Auswahl") }
        model.selection.clear()

        // Search times with Office documents in the index (warm).
        for term in ["Kündigungsfrist", "Müller", "Quartalsende", "Vertrag", "Haftung"] {
            var times: [Int] = []
            for _ in 0..<3 {
                model.queryText = ""
                await model.waitUntilIdle()
                let t = clock.now
                model.queryText = term
                await model.waitUntilIdle()
                times.append(ms(clock.now - t))
            }
            print("OFFICE-SMOKE search „\(term)“: \(times) ms, \(model.hits.count) documents")
        }
        window.close()
    }

    /// SlideKit wiring (1.3.0) smoke run with the app's own wiring: default „PowerPoint-Darstellung“ (own viewer),
    /// then Quick Look, then the own viewer with „ähnliche Schrift“ — layout, tiles, preview and saving each time.
    /// Index, slide cache, tiles and settings in a temp folder; SlideKit keeps decks in memory only.
    /// Opt-in: `PDFSUCHER_APPSHOTS=$PWD/docs/screenshots/office scripts/test.sh --filter AppScreenshotTests/officeSlideKitScreenshots`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_APPSHOTS"] != nil))
    func officeSlideKitScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: env["PDFSUCHER_APPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Dokumente", isDirectory: true).standardizedFileURL
        try ScreenshotFixtures.makeOffice(in: folder)
        let spikes = URL(fileURLWithPath: env["PDFSUCHER_OFFICE_IN"]
                         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/PDFSucher-spikes/office/in").path)
        let examples = folder.appendingPathComponent("Beispiele", isDirectory: true)
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        for name in ["test.docx", "test.pptx"] {
            let source = spikes.appendingPathComponent(name)
            try #require(FileManager.default.fileExists(atPath: source.path), "\(source.path) fehlt")
            try FileManager.default.copyItem(at: source, to: examples.appendingPathComponent(name))
        }
        let slides = SlideCache(root: base.appendingPathComponent("SlideCache", isDirectory: true))
        let tiles = TileDiskCache(directory: base.appendingPathComponent("Tiles", isDirectory: true))
        let rendering = PowerPointDisplaySetting()
        let index = try FolderIndex(root: folder, indexURL: base.appendingPathComponent("index.sqlite"),
                                    makeLayout: { OfficeLayoutSource.standard(cache: slides, rendering: rendering) })
        let environment = FakeEnvironment()
        let clock = ContinuousClock()

        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "AppShots-\(UUID().uuidString)")!
        let settings = GridSettings(defaults: defaults)
        settings.columnsMode = .fixed
        settings.columns = 4
        settings.previewPosition = .trailing
        // No officeLayout/foreignPages: the app's wiring (OfficeLayoutSource.standard, OfficeDisplay.pages).
        let model = AppModel(settings: settings, defaults: defaults, environment: environment, slideCache: slides,
                             debounce: .zero, openIndex: { _ in index }, officeRendering: rendering)
        model.tileDisk = tiles
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1280, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "PDFSucher"
        window.contentView = NSHostingView(rootView: ContentShell(model: model, highlighter: Highlighter.make, tileDisk: tiles))
        window.orderFrontRegardless()

        func ms(_ d: Duration) -> Int { Int((Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded()) }
        func focus(_ name: String, page: Int? = nil) {
            guard let hit = model.hits.first(where: { $0.url.lastPathComponent == name }) else { Issue.record("\(name) fehlt"); return }
            model.focusedPage = PageRef(url: hit.url, pageIndex: page ?? hit.pageHits.first?.pageIndex ?? 0)
        }
        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(4))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", output.appendingPathComponent(name).path]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "screencapture \(name)")
        }
        func deckHit() throws -> DocumentHit { try #require(model.hits.first { $0.url.lastPathComponent == "Vertragsübersicht.pptx" }) }
        func search(_ term: String) async {
            model.queryText = ""
            await model.waitUntilIdle()
            model.queryText = term
            await model.waitUntilIdle()
        }

        // 1. Own viewer (default): laid out by SlideKit, pages from SlideKit.
        let start = clock.now
        await model.open(folder: folder)
        await model.waitUntilIdle()
        print("OFFICE-SLIDEKIT open → idle (SlideKit layout): \(ms(clock.now - start)) ms")
        #expect(OfficeLayoutSource.standard(cache: slides, rendering: rendering).renderer(for: .powerpoint) == ("slidekit", 101))
        #expect(model.foreignPages is SlideKitPages)
        await search("Kündigungsfrist")
        var deck = try deckHit()
        #expect(deck.pageCount == 3 && deck.pageHits.map(\.pageIndex) == [1])
        #expect((await model.ocrText(for: PageRef(url: deck.url, pageIndex: 1)))?.words.isEmpty == false)
        focus("Vertragsübersicht.pptx")
        try await shoot("office-05-slidekit-treffer.png")
        await search("")
        focus("test.pptx", page: 0)
        try await shoot("office-06-slidekit-durchblaettern.png")

        // Saving a slide: SlideKit's vector page of the slide size with its text (spec §9: same renderer).
        let saved = base.appendingPathComponent("Folie.pdf")
        environment.saveURL = saved
        await search("Kündigungsfrist")
        deck = try deckHit()
        model.selection.toggle(PageRef(url: deck.url, pageIndex: 1))
        model.saveSelection()
        await model.waitUntilIdle()
        let page = try #require(PDFDocument(url: saved)?.page(at: 0))
        print("OFFICE-SLIDEKIT saved slide: \(page.bounds(for: .mediaBox).size), text: \((page.string ?? "").prefix(80))")
        #expect(page.string?.contains("Kündigungsfrist") == true)
        model.selection.clear()

        // 2. Quick Look: every deck is reset and laid out by Quick Look; pages from the slide cache.
        let switched = clock.now
        model.officePreferences.powerPointRenderer = .quickLook
        await model.waitUntilIdle()
        print("OFFICE-SLIDEKIT switch to Quick Look → idle: \(ms(clock.now - switched)) ms")
        #expect(model.foreignPages is OfficePages)
        await search("Kündigungsfrist")
        deck = try deckHit()
        #expect(deck.pageHits.map(\.pageIndex) == [1])
        focus("Vertragsübersicht.pptx")
        try await shoot("office-07-quicklook-treffer.png")
        await search("")
        focus("test.pptx", page: 0)
        try await shoot("office-08-quicklook-durchblaettern.png")

        // 3. Own viewer with „ähnliche Schrift“ (layout version 102).
        let back = clock.now
        model.officePreferences.fontSubstitution = .similar
        model.officePreferences.powerPointRenderer = .slideKit
        await model.waitUntilIdle()
        print("OFFICE-SLIDEKIT switch to SlideKit + similar → idle: \(ms(clock.now - back)) ms")
        #expect((model.foreignPages as? SlideKitPages)?.fontSubstitution == .similar)
        await search("")
        focus("test.pptx", page: 0)
        try await shoot("office-09-slidekit-aehnliche-schrift.png")
        window.close()
    }
}

/// Distinct index status values with the time they were first seen.
@MainActor private final class StatusLog {
    private(set) var entries: [(at: ContinuousClock.Instant, status: IndexStatus)] = []
    func note(_ status: IndexStatus, at time: ContinuousClock.Instant) {
        if entries.last?.status != status { entries.append((time, status)) }
    }
}

/// `OfficePages` that notes when each page document was asked for and whether it came back.
private final class RecordingForeignPages: ForeignPageProvider {
    struct Event: Sendable { let at: ContinuousClock.Instant; let ref: PageRef; let maxPixel: Int?; let ok: Bool; let took: Duration }
    private let base: OfficePages
    private let clock: ContinuousClock
    private let log = Mutex<[Event]>([])
    init(_ base: OfficePages, clock: ContinuousClock) { self.base = base; self.clock = clock }
    var events: [Event] { log.withLock { $0 }.sorted { $0.at < $1.at } }
    func handles(_ url: URL) -> Bool { base.handles(url) }
    func pageCount(of url: URL) -> Int? { base.pageCount(of: url) }
    func makePage(_ ref: PageRef) throws -> PDFPage { try base.makePage(ref) }
    func contentVersion(_ url: URL) -> String { base.contentVersion(url) }
    func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
        let t = clock.now
        let document = base.pageDocument(ref, maxPixel: maxPixel)
        let now = clock.now
        log.withLock { $0.append(Event(at: now, ref: ref, maxPixel: maxPixel, ok: document != nil, took: now - t)) }
        return document
    }
}

@MainActor private final class NoEnvironment: AppEnvironment {
    func chooseSources() -> [URL] { [] }
    func chooseSaveLocation(defaultName: String) -> URL? { nil }
    func runPrint(_ operation: NSPrintOperation) {}
    func openInPreview(_ url: URL) {}
    func openWithDefaultApp(_ url: URL) {}
    func confirmDeleteIndex(question: String) -> Bool { false }
}
