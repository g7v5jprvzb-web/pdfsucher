import Foundation
import IndexKit
import OfficeKit
import SearchKit
import Synchronization
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Counts `layout(of:kind:)` calls; answers one empty page.
private final class CountingLayout: PageLayoutSource {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        calls.withLock { $0 += 1 }
        return LayoutResult(pages: [LaidOutPage(text: "", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: "fake", layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("fake", 1) }
}

/// 1.3 Part B Task 3: Word/PowerPoint as sources (drop, ⌘O, folders) behind „office.include“.
@MainActor @Suite("Office sources")
struct OfficeSourcesTests {
    let base: URL

    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    func file(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func dropAcceptsOfficeWhenOn() throws {
        let a = try file("a.docx"), b = try file("b.pptx"), d = try file("d.ppt")
        let result = SourceClassifier.classify([a, b, d], includeOffice: true)
        #expect(result.sources.map(\.url.lastPathComponent) == ["a.docx", "b.pptx"])
        #expect(result.ignored == [d])
    }

    @Test func droppedLockFileRejected() throws {
        let lockDocx = try file("~$a.docx"), lockPDF = try file("~$b.pdf")
        let result = SourceClassifier.classify([lockDocx, lockPDF], includeOffice: true)
        #expect(result.sources.isEmpty)
        #expect(result.ignored == [lockDocx, lockPDF])
    }

    @Test func dropIgnoresOfficeWhenOff() throws {
        let a = try file("a.docx"), b = try file("b.pptx"), p = try file("c.pdf")
        let result = SourceClassifier.classify([a, b, p], includeOffice: false)
        #expect(result.sources.map(\.url.lastPathComponent) == ["c.pdf"])
        #expect(result.ignored == [a, b])
    }

    @Test func officePreferenceDefaultsOnAndPersists() {
        let defaults = UserDefaults(suiteName: "Office-\(UUID().uuidString)")!
        let p = OfficePreferences(defaults: defaults)
        #expect(p.includeOffice)
        p.includeOffice = false
        #expect(defaults.object(forKey: "office.include") as? Bool == false)
        #expect(OfficePreferences(defaults: defaults).includeOffice == false)
    }

    func officeFolder() throws -> URL {
        let folder = base.appendingPathComponent("Ordner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("a.pdf"), pages: ["Vertrag"])
        _ = try OfficeFixtures.docx(paragraphs: ["Angebot"], name: "c.docx", in: folder)
        return folder
    }

    @Test func folderIndexListsOfficeOnlyWhenOn() async throws {
        let folder = try officeFolder()
        let layout = CountingLayout()
        let index = try FolderIndex(root: folder, indexURL: base.appendingPathComponent("index.sqlite"), makeLayout: { layout })
        index.configure(.default, includeOffice: true)
        _ = try await index.update(progress: { _ in })
        let docx = try index.browse().first { $0.relativePath == "c.docx" }
        #expect(docx?.pageCount == 0)
        #expect(docx?.kind == .word)
        index.configure(.default, includeOffice: false)
        _ = try await index.update(progress: { _ in })
        #expect(try index.browse().map(\.relativePath) == ["a.pdf"])
    }

    @Test func updateDoesNotLayOut() async throws {
        let folder = try officeFolder()
        let layout = CountingLayout()
        let index = try FolderIndex(root: folder, indexURL: base.appendingPathComponent("index.sqlite"), makeLayout: { layout })
        index.configure(.default, includeOffice: true)
        _ = try await index.update(progress: { _ in })
        #expect(layout.count == 0)
    }

    @Test func togglingOfficeReconfiguresAndReindexesFolders() async throws {
        let eins = base.appendingPathComponent("eins", isDirectory: true)
        let zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let log = StringLog()
        let idx = Dictionary(uniqueKeysWithValues: ["eins", "zwei"].map { name in
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            return (name, index)
        })
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "OfficeSrc-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                         openIndex: { root in idx[root.lastPathComponent]! }, officeRendering: PowerPointDisplaySetting())
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(idx["eins"]!.configuredOffice.last == true)
        m.officePreferences.includeOffice = false
        await m.waitUntilIdle()
        #expect(idx["eins"]!.configuredOffice.last == false)
        #expect(idx["zwei"]!.configuredOffice.last == false)
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        #expect(log.entries.filter { $0 == "zwei:update-start" }.count == 2)
    }

    func fakeModel(_ idx: [String: FakeIndex]) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "OfficeSrc-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in idx[root.lastPathComponent]! }, officeRendering: PowerPointDisplaySetting())
    }

    @Test func officeOffIgnoresDroppedOfficeFile() async throws {
        let x = try file("x.docx")
        let m = fakeModel([:])
        m.officePreferences.includeOffice = false
        await m.add([x])
        #expect(m.sources.isEmpty)
        #expect(m.notice == "1 Datei ignoriert (nur Ordner und PDFs)")
    }

    @Test func togglingOfficeKeepsStoppedRecognitionStopped() async throws {
        let eins = base.appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: eins, withIntermediateDirectories: true)
        let log = StringLog()
        let index = FakeIndex()
        index.name = "eins"
        index.ocrLog = log
        let m = fakeModel(["eins": index])
        await m.add([eins])
        await m.waitUntilIdle()
        m.stopRecognition()
        #expect(m.isRecognitionStopped)
        m.officePreferences.includeOffice = false
        await m.waitUntilIdle()
        #expect(m.isRecognitionStopped)
        #expect(index.configuredOffice.last == false)
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        #expect(log.entries.filter { $0 == "eins:ocr-start" }.count == 1, "the stopped recognition did not run again")
    }

    /// 1.3 Teil B Task 12: the counts in „Word/PowerPoint“ per folder source.
    @Test func modelLayoutCountsPerSource() async throws {
        let folder = base.appendingPathComponent("eins", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = FakeIndex()
        index.layoutCountsValue = LayoutCounts(wordRead: 12, wordFailed: 1, powerpointRead: 30, waiting: 4)
        let m = fakeModel(["eins": index])
        await m.add([folder])
        await m.waitUntilIdle()
        #expect(await m.layoutCounts(for: folder) == index.layoutCountsValue)
        #expect(await m.layoutCounts(for: base.appendingPathComponent("fremd", isDirectory: true)) == nil)
    }

    /// Review 3: a folder not loaded at the switch: opening (or configuring) its index with another PowerPoint renderer
    /// removes the old slide text at once; a renderer change seen later goes at the start of the next run (off the main actor).
    @Test func otherPowerPointRendererClearsOldTextAtOpenAndConfigure() async throws {
        let folder = base.appendingPathComponent("Decks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try OfficeFixtures.pptx(slides: ["Folie"], name: "d.pptx", in: folder)
        let indexURL = base.appendingPathComponent("decks.sqlite")
        // Like the app's `OfficeLayoutSource`, the source reads the current choice at every call.
        let name = LiveName("quicklook")
        let make: @Sendable () -> any PageLayoutSource = { LiveNamedLayout(name: name) }
        func deckPages(_ index: FolderIndex) throws -> Int? { try index.browse().first { $0.relativePath == "d.pptx" }?.pageCount }
        func found(_ index: FolderIndex) throws -> Int {
            try index.search(QueryParser.parse("Altfassung", partialWords: false), sort: .fileName).count
        }

        let first = try FolderIndex(root: folder, indexURL: indexURL, makeLayout: make)
        _ = try await first.update(progress: { _ in })
        _ = try await first.layOut(progress: { _ in })
        #expect(try deckPages(first) == 1 && found(first) == 1)

        // Next start with the other renderer: cleared on open.
        name.set("slidekit")
        let reopened = try FolderIndex(root: folder, indexURL: indexURL, makeLayout: make)
        #expect(try deckPages(reopened) == 0 && found(reopened) == 0)
        _ = try await reopened.layOut(progress: { _ in })
        #expect(try found(reopened) == 1)

        // Same identity again: no further store transaction (update and layOut skip the adoption).
        let writes = reopened.powerPointAdoptions
        _ = try await reopened.update(progress: { _ in })
        #expect(reopened.powerPointAdoptions == writes)

        // Same instance, renderer changed in between: `configure` (main actor) does not touch the store; the old text
        // goes at the start of the folder's next run, before phase 1.
        name.set("quicklook")
        reopened.configure(.default, includeOffice: true)
        #expect(reopened.powerPointAdoptions == writes, "configure writes nothing")
        #expect(try found(reopened) == 1, "until the next run (documented window)")
        _ = try await reopened.update(progress: { _ in })
        #expect(reopened.powerPointAdoptions == writes + 1)
        #expect(try deckPages(reopened) == 0 && found(reopened) == 0)
        // And a layout run alone adopts as well.
        _ = try await reopened.layOut(progress: { _ in })
        name.set("slidekit")
        #expect(try found(reopened) == 1)
        _ = try await reopened.layOut(progress: { _ in })
        #expect(reopened.powerPointAdoptions == writes + 2)
    }

    /// SlideKit wiring, first start of this build over an index laid out by Quick Look: the old slide text is gone
    /// when the index opens (before phase 1 or any layout), and the deck comes back with SlideKit's own text.
    @Test func firstStartWithSlideKitDropsQuickLookTextAtOnce() async throws {
        let folder = base.appendingPathComponent("Alt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try OfficeFixtures.pptx(slides: ["Neufassung Folie"], name: "d.pptx", in: folder)
        let indexURL = base.appendingPathComponent("alt.sqlite")
        let quickLook = QuickLookSlideSource().renderer(for: .powerpoint)
        func count(_ index: FolderIndex, _ word: String) throws -> Int {
            try index.search(QueryParser.parse(word, partialWords: false), sort: .fileName).count
        }

        let old = try FolderIndex(root: folder, indexURL: indexURL,
                                  makeLayout: { RenamedLayout(name: quickLook.name, version: quickLook.version) })
        _ = try await old.update(progress: { _ in })
        _ = try await old.layOut(progress: { _ in })
        #expect(try count(old, "Altfassung") == 1)

        let setting = PowerPointDisplaySetting()                 // default: own viewer, fonts like PowerPoint
        let slides = SlideCache(root: base.appendingPathComponent("SlideCache-alt", isDirectory: true))
        let new = try FolderIndex(root: folder, indexURL: indexURL,
                                  makeLayout: { OfficeLayoutSource.standard(cache: slides, rendering: setting) })
        #expect(try count(new, "Altfassung") == 0, "gone at open")
        _ = try await new.update(progress: { _ in })
        #expect(try count(new, "Altfassung") == 0, "not back after phase 1")
        _ = try await new.layOut(progress: { _ in })
        #expect(try count(new, "Altfassung") == 0)
        #expect(try count(new, "Neufassung") == 1, "laid out by SlideKit")
    }
}

/// One page „Altfassung“ under the given renderer name.
private struct RenamedLayout: PageLayoutSource {
    let name: String
    var version = 1
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "Altfassung", words: [], size: CGSize(width: 100, height: 100))],
                     renderer: name, layoutVersion: version)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name, version) }
}

/// Round 3: the adoption runs inside the Indexer's turn. A layout of the old renderer still running when a new run
/// starts stores its deck first; the new run then clears it – no old-renderer text is left afterwards.
@Suite("PowerPoint renderer adoption turn")
struct AdoptionTurnTests {
    @Test(.timeLimit(.minutes(1))) func heldOldLayoutThenUpdateLeavesNoOldText() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Decks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try OfficeFixtures.pptx(slides: ["Folie"], name: "d.pptx", in: folder)
        let name = LiveName("quicklook")
        let gate = HeldLayout(name: name)
        let index = try FolderIndex(root: folder, indexURL: base.appendingPathComponent("i.sqlite"), makeLayout: { gate })
        _ = try await index.update(progress: { _ in })
        func found() throws -> Int { try index.search(QueryParser.parse("Altfassung", partialWords: false), sort: .fileName).count }

        let layout = Task { try await index.layOut(progress: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(20)
        while !gate.started { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(2)) }
        name.set("slidekit")                                   // the switch while the old layout is running
        let update = Task { try await index.update(progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        gate.release()
        _ = try await layout.value
        _ = try await update.value
        #expect(try found() == 0, "no text of the old renderer left")
        #expect(try index.browse().first { $0.relativePath == "d.pptx" }?.pageCount == 0)
    }
}

/// Lays out „Altfassung“ under the name current when the layout starts, after waiting for `release()` once.
private final class HeldLayout: PageLayoutSource {
    private let name: LiveName
    private let state = Mutex((started: false, released: false))
    init(name: LiveName) { self.name = name }
    var started: Bool { state.withLock { $0.started } }
    func release() { state.withLock { $0.released = true } }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name.current, 1) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let renderer = name.current
        state.withLock { $0.started = true }
        let deadline = ContinuousClock.now + .seconds(20)
        while !state.withLock({ $0.released }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return LayoutResult(pages: [LaidOutPage(text: "Altfassung", words: [], size: CGSize(width: 100, height: 100))],
                            renderer: renderer, layoutVersion: 1)
    }
}

private final class LiveName: Sendable {
    private let value: Mutex<String>
    init(_ value: String) { self.value = Mutex(value) }
    func set(_ new: String) { value.withLock { $0 = new } }
    var current: String { value.withLock { $0 } }
}

/// One page „Altfassung“ under the name `name` holds right now.
private struct LiveNamedLayout: PageLayoutSource {
    let name: LiveName
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "Altfassung", words: [], size: CGSize(width: 100, height: 100))],
                     renderer: name.current, layoutVersion: 1)
    }
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (name.current, 1) }
}
