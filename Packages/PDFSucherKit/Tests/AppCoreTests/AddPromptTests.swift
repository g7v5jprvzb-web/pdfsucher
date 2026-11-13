import Foundation
import IndexKit
import OutputKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.2.1 §1: adding sources while others are loaded asks „Zusätzlich / Ersetzen / Abbrechen“.
@MainActor @Suite("Add or replace sources", .timeLimit(.minutes(1)))
struct AddPromptTests {
    let base: URL
    let eins: URL, zwei: URL, drei: URL, vier: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        drei = base.appendingPathComponent("drei", isDirectory: true)
        vier = base.appendingPathComponent("vier", isDirectory: true)
        for dir in [eins, zwei, drei, vier] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func model(_ log: StringLog = StringLog(), defaults: UserDefaults? = nil, settings: GridSettings? = nil) -> (AppModel, [String: FakeIndex]) {
        let indexes = Dictionary(uniqueKeysWithValues: ["eins", "zwei", "drei", "vier"].map { name in
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            return (name, index)
        })
        let defaults = defaults ?? UserDefaults(suiteName: "AddPrompt-\(UUID().uuidString)")!
        let m = AppModel(settings: settings ?? GridSettings(defaults: defaults), defaults: defaults, environment: FakeEnvironment(),
                         debounce: .zero, openIndex: { root in
                             guard let index = indexes[root.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
                             return index
                         })
        return (m, indexes)
    }

    var names: (AppModel) -> [String] { { $0.sources.map(\.url.lastPathComponent) } }

    @Test func noPromptWithoutSources() async {
        let (m, _) = model()
        await m.requestAdd([eins])
        #expect(m.addPrompt == nil)
        #expect(names(m) == ["eins"])
    }

    @Test func noPromptWhenAllContained() async throws {
        let (m, _) = model()
        await m.add([eins])
        let inner = eins.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: inner, pages: ["Text"])
        await m.requestAdd([inner, eins])
        #expect(m.addPrompt == nil)
        #expect(m.notice == "„a.pdf“ ist bereits enthalten in „eins“")
        #expect(names(m) == ["eins"])
    }

    @Test func promptTitleAndMessage() async throws {
        let (m, _) = model()
        await m.add([eins])
        let inner = eins.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: inner, pages: ["Text"])
        await m.requestAdd([inner, zwei])                // only zwei is new
        #expect(m.addPrompt?.title == "„zwei“ hinzufügen?")
        #expect(m.addPrompt?.message == "Sollen die neuen Quellen zusätzlich durchsucht werden oder die bisherige Quelle ersetzen?")
        m.answerAddPrompt(.cancel, remember: false)
        await m.add([zwei])
        await m.requestAdd([drei, vier])
        #expect(m.addPrompt?.title == "2 Objekte hinzufügen?")
        #expect(m.addPrompt?.message == "Sollen die neuen Quellen zusätzlich durchsucht werden oder die bisherigen 2 Quellen ersetzen?")
    }

    @Test func additionallyAdds() async {
        let (m, _) = model()
        await m.add([eins])
        await m.requestAdd([zwei])
        m.answerAddPrompt(.add, remember: false)
        await m.waitUntilIdle()
        #expect(m.addPrompt == nil)
        #expect(names(m) == ["eins", "zwei"])
        #expect(m.settings.addSourcesPolicy == .ask)
    }

    @Test func cancelKeepsEverything() async {
        let (m, _) = model()
        await m.add([eins])
        await m.requestAdd([zwei])
        m.answerAddPrompt(.cancel, remember: true)
        await m.waitUntilIdle()
        #expect(m.addPrompt == nil)
        #expect(names(m) == ["eins"])
        #expect(m.settings.addSourcesPolicy == .ask, "cancel is never remembered")
    }

    @Test func replaceReplaces() async throws {
        let log = StringLog()
        let (m, idx) = model(log)
        idx["eins"]!.holdRecognition = true
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        let kept = PageRef(url: zwei.appendingPathComponent("b.pdf"), pageIndex: 0)
        m.selection.toggle(PageRef(url: eins.appendingPathComponent("a.pdf"), pageIndex: 0))
        m.selection.toggle(kept)
        m.queryText = "Vertrag"
        await m.waitForSearch()                       // not waitUntilIdle: the recognition is held
        let searchesBefore = idx["zwei"]!.searchCount
        await m.requestAdd([zwei])
        m.answerAddPrompt(.replace, remember: false)
        #expect(await eventually { log.entries.contains("eins:ocr-cancelled") })
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(names(m) == ["zwei"])
        #expect(log.entries.contains("eins:ocr-cancelled"), "recognition of the removed folder stopped")
        #expect(log.entries.filter { $0 == "eins:ocr-start" }.count == 1, "and not started again")
        #expect(!idx["eins"]!.events.contains { $0.hasPrefix("delete") }, "its index stays on disk")
        #expect(m.selection.count == 1 && m.selection.contains(kept), "ticks of removed sources are gone")
        #expect(m.queryText == "Vertrag")
        #expect(idx["zwei"]!.searchCount > searchesBefore, "the search ran again")
    }

    /// Review I1: a second drop while the prompt is open joins the first instead of replacing it.
    @Test func secondDropWhilePromptOpenIsMerged() async {
        let (m, _) = model()
        await m.add([eins])
        await m.requestAdd([zwei])
        let first = m.addPrompt?.id
        await m.requestAdd([drei])
        #expect(m.addPrompt?.title == "2 Objekte hinzufügen?")
        #expect(m.addPrompt?.id == first, "the same sheet stays up")
        m.answerAddPrompt(.add, remember: false)
        await m.waitUntilIdle()
        #expect(names(m) == ["eins", "zwei", "drei"])
    }

    /// Review I2: „Ersetzen“ with a folder whose index cannot be opened keeps the old sources (like ⌘O in 1.0).
    @Test func failedReplaceKeepsOldSources() async throws {
        let defaults = UserDefaults(suiteName: "AddPrompt-\(UUID().uuidString)")!
        let (m, _) = model(defaults: defaults)
        let kaputt = base.appendingPathComponent("kaputt", isDirectory: true)
        try FileManager.default.createDirectory(at: kaputt, withIntermediateDirectories: true)
        await m.add([eins])
        let tick = PageRef(url: eins.appendingPathComponent("a.pdf"), pageIndex: 0)
        m.selection.toggle(tick)
        await m.requestAdd([kaputt])
        m.answerAddPrompt(.replace, remember: false)
        await m.waitUntilIdle()
        #expect(names(m) == ["eins"])
        #expect(m.selection.contains(tick))
        #expect(defaults.stringArray(forKey: AppModel.sourcesKey) == [eins.path])
        #expect(m.alertMessage != nil, "the failure is reported")
    }

    @Test func rememberSetsPolicy() async {
        let (m, _) = model()
        await m.add([eins])
        await m.requestAdd([zwei])
        m.answerAddPrompt(.replace, remember: true)
        await m.waitUntilIdle()
        #expect(m.settings.addSourcesPolicy == .replace)
        await m.requestAdd([drei])
        await m.waitUntilIdle()
        #expect(m.addPrompt == nil)
        #expect(names(m) == ["drei"])
    }

    @Test(arguments: [AddSourcesPolicy.add, .replace])
    func policySkipsPrompt(_ policy: AddSourcesPolicy) async {
        let (m, _) = model()
        m.settings.addSourcesPolicy = policy
        await m.add([eins])
        await m.requestAdd([zwei])
        await m.waitUntilIdle()
        #expect(m.addPrompt == nil)
        #expect(names(m) == (policy == .add ? ["eins", "zwei"] : ["zwei"]))
    }

    @Test func replaceRemovesRememberedAndSurvivesRestart() async throws {
        let defaults = UserDefaults(suiteName: "AddPrompt-\(UUID().uuidString)")!
        let gone = base.appendingPathComponent("weg", isDirectory: true)
        defaults.set([eins.path, gone.path], forKey: AppModel.sourcesKey)
        let (m, _) = model(defaults: defaults)
        await m.restoreSources()                         // never asks
        #expect(m.addPrompt == nil)
        #expect(names(m) == ["eins"])
        await m.requestAdd([zwei])
        m.answerAddPrompt(.replace, remember: false)
        await m.waitUntilIdle()
        #expect(defaults.stringArray(forKey: AppModel.sourcesKey) == [zwei.path], "remembered missing sources are replaced too")
        let (restarted, _) = model(defaults: defaults)
        await restarted.restoreSources()
        #expect(names(restarted) == ["zwei"])
    }
}
