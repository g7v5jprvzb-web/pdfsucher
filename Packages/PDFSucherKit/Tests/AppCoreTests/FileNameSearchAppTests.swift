import Foundation
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// 1.3.2 Teil A in the app: the setting „Auch Dateinamen durchsuchen“ (on by default) reaches every search, a
/// change searches again, and a single file is found by its name.
@MainActor @Suite("File name search in the app", .timeLimit(.minutes(1)))
struct FileNameSearchAppTests {
    @Test func settingIsOnByDefaultAndKept() {
        let d = UserDefaults(suiteName: "FileNames-\(UUID().uuidString)")!
        let s = GridSettings(defaults: d)
        #expect(s.searchFileNames)
        s.searchFileNames = false
        #expect(!GridSettings(defaults: d).searchFileNames)
    }

    @Test func folderSearchesGetTheSettingAndAChangeSearchesAgain() async throws {
        let index = FakeIndex()
        let settings = makeSettings()
        let m = makeModel(index: index, settings: settings)
        await m.add([try PDFFixtures.tempDirectory()])
        m.queryText = "rechnung"
        await m.waitUntilIdle()
        #expect(index.searchNamesSeen.last == true)
        let before = index.searchNamesSeen.count
        settings.searchFileNames = false
        await m.waitUntilIdle()
        #expect(index.searchNamesSeen.count > before, "searched again")
        #expect(index.searchNamesSeen.last == false)
    }

    @Test func aSingleFileIsFoundByItsName() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let pdf = dir.appendingPathComponent("Rechnung März.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Nur Zahlen"])
        let m = makeModel(index: FakeIndex())
        await m.add([pdf])
        m.queryText = "rechnung"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.url.lastPathComponent) == ["Rechnung März.pdf"])
        #expect(m.hits.first?.nameMatch == true)
    }

    /// Chris, 2026-11-14: a single file that cannot be read is found by its name; its row shows the error symbol
    /// (unreadable) with the name hint, and the „cannot be read“ notice stays away while the row says it.
    @Test func anUnreadableSingleFileIsFoundByItsName() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let broken = dir.appendingPathComponent("Rechnung kaputt.pdf")
        try Data("kein PDF".utf8).write(to: broken)
        let m = makeModel(index: FakeIndex())
        await m.add([broken])
        m.queryText = "rechnung"
        await m.waitUntilIdle()
        let hit = try #require(m.hits.first)
        #expect(m.hits.count == 1 && hit.nameMatch && hit.isUnreadable && hit.pageCount == 0)
        #expect(m.noticeKind == nil)
        // Not by its name: no row, the notice as before.
        m.queryText = "anderes"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
        #expect(m.noticeKind == .unreadable)
        // Names switched off: as before as well.
        m.settings.searchFileNames = false
        m.queryText = "rechnung"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
    }

    /// „Auch Dateiendung durchsuchen“: off by default, kept, and reaches the search (a change searches again).
    @Test func extensionSettingReachesTheSearch() async throws {
        let d = UserDefaults(suiteName: "FileNameExt-\(UUID().uuidString)")!
        #expect(!GridSettings(defaults: d).searchFileNameExtensions)
        GridSettings(defaults: d).searchFileNameExtensions = true
        #expect(GridSettings(defaults: d).searchFileNameExtensions)

        let index = FakeIndex()
        let settings = makeSettings()
        let m = makeModel(index: index, settings: settings)
        await m.add([try PDFFixtures.tempDirectory()])
        m.queryText = "pptx"
        await m.waitUntilIdle()
        #expect(index.nameExtensionsSeen.last == false)
        let before = index.nameExtensionsSeen.count
        settings.searchFileNameExtensions = true
        await m.waitUntilIdle()
        #expect(index.nameExtensionsSeen.count > before, "searched again")
        #expect(index.nameExtensionsSeen.last == true)
    }
}
