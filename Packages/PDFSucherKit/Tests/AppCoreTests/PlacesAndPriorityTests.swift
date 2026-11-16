import Foundation
import IndexKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// 1.4.0 P2: a click on a place loads it at once; the folder filter sets the order of the background work.
@MainActor @Suite("Orte sofort, Vorrang nach Filter", .timeLimit(.minutes(1)))
struct PlacesAndPriorityTests {
    let base: URL
    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    func model(_ indexes: [String: FakeIndex]) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Places-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in
                     guard let index = indexes[root.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
                     return index
                 })
    }

    func folder(_ path: String) throws -> URL {
        let url = base.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPlaceIsAddedWithoutTheSheetWhenTheSettingAsks() async throws {
        let eins = try folder("eins"), zwei = try folder("zwei")
        let m = model(["eins": FakeIndex(), "zwei": FakeIndex()])
        #expect(m.settings.addSourcesPolicy == .ask)
        await m.add([eins])
        await m.openPlace(zwei)
        #expect(m.addPrompt == nil)
        #expect(m.sources.map(\.url.lastPathComponent).sorted() == ["eins", "zwei"])
        #expect(m.folderFilter.folders == [zwei.standardizedFileURL])
    }

    @Test func aPlaceStillReplacesWhenTheSettingSaysSo() async throws {
        let eins = try folder("eins"), zwei = try folder("zwei")
        let m = model(["eins": FakeIndex(), "zwei": FakeIndex()])
        m.settings.addSourcesPolicy = .replace
        await m.add([eins])
        await m.openPlace(zwei)
        #expect(m.sources.map(\.url.lastPathComponent) == ["zwei"])
    }

    @Test func aDropStillAsks() async throws {
        let eins = try folder("eins"), zwei = try folder("zwei")
        let m = model(["eins": FakeIndex(), "zwei": FakeIndex()])
        await m.add([eins])
        await m.requestAdd([zwei])
        #expect(m.addPrompt != nil)
    }

    @Test func theFolderFilterSetsEachSourcesPriority() async throws {
        let akten = try folder("akten"), belege = try folder("belege")
        _ = try folder("akten/2025/Ä")
        let a = FakeIndex(), b = FakeIndex()
        let m = model(["akten": a, "belege": b])
        await m.add([akten, belege])
        m.selectFolder(akten.appendingPathComponent("2025/Ä", isDirectory: true), adding: false)
        #expect(a.priorities.last == ["2025/Ä/"])
        #expect(b.priorities.last == [])
        m.selectFolder(akten, adding: false)                  // the source itself: no preference
        #expect(a.priorities.last == [])
        m.clearFolderFilter()
        #expect(a.priorities.last == [])
    }
}
