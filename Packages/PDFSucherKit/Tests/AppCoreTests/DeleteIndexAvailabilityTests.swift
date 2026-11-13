import Foundation
import Testing
import TestSupport
@testable import ViewerUI
@testable import AppCore

/// Chris (Task 5.6): „Index löschen …“ only with an open folder, otherwise disabled with a hint.
@MainActor @Suite("Delete index availability")
struct DeleteIndexAvailabilityTests {
    @Test func onlyWithOpenFolder() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(index: FakeIndex())
        #expect(!model.canDeleteIndex)
        await model.open(folder: dir)
        #expect(model.canDeleteIndex)
        model.open(file: dir.appendingPathComponent("a.pdf"))
        #expect(!model.canDeleteIndex)
    }

    @Test func hintWhenDisabled() {
        #expect(SettingsView.deleteIndexHelp(canDelete: false) == "Erst einen Ordner öffnen")
        #expect(SettingsView.deleteIndexHelp(canDelete: true) != "Erst einen Ordner öffnen")
    }
}
