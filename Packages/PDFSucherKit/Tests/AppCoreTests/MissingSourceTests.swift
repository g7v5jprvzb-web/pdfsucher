import Foundation
import PDFKit
import IndexKit
import OfficeKit
import OutputKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Chris (Task 5.6): saving or printing with a ticked page whose file is gone keeps the spec behaviour
/// (message names the file, selection stays) and offers „Fehlende Seiten aus Auswahl entfernen“.
@MainActor @Suite("Missing source files", .serialized)
struct MissingSourceTests {
    let base: URL
    let folder: URL
    let indexURL: URL

    init() throws {
        base = try PDFFixtures.tempDirectory()
        folder = base.appendingPathComponent("PDFs", isDirectory: true)
        indexURL = base.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("vertrag.pdf"),
                                pages: ["Der Vertrag beginnt heute.", "Nichts.", "Vertrag Ende."])
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot zum Vertrag."])
    }

    /// Ticks vertrag.pdf p.1 and p.3 and angebot.pdf p.1.
    func model(_ env: FakeEnvironment) async -> AppModel {
        let indexURL = self.indexURL
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: env, slideCache: testSlideCache, debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        for hit in model.hits {
            for page in hit.pageHits { model.selection.toggle(PageRef(url: hit.url, pageIndex: page.pageIndex)) }
        }
        return model
    }

    @Test func saveWithDeletedFileOffersRemovalThenSaves() async throws {
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = await model(env)
        #expect(model.selection.count == 3)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("angebot.pdf"))

        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == "Speichern fehlgeschlagen: Auswahl.pdf – „angebot.pdf“ kann nicht geöffnet werden")
        #expect(model.alertOffersRemovingMissingPages)
        #expect(model.selection.count == 3)

        model.removeMissingPagesFromSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        #expect(!model.alertOffersRemovingMissingPages)
        #expect(model.selection.count == 2)

        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        #expect(PDFDocument(url: env.saveURL!)?.pageCount == 2)
    }

    @Test func shortenedFileRemovesOnlyMissingPages() async throws {
        let env = FakeEnvironment()
        let model = await model(env)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("vertrag.pdf"), pages: ["Der Vertrag beginnt heute."])
        model.printSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == "Drucken nicht möglich: Seite 3 fehlt in „vertrag.pdf“")
        #expect(model.alertOffersRemovingMissingPages)
        #expect(env.printed.isEmpty)

        model.removeMissingPagesFromSelection()
        await model.waitUntilIdle()
        #expect(model.selection.count == 2)          // vertrag.pdf p.1 and angebot.pdf p.1 stay
        model.printSelection()
        await model.waitUntilIdle()
        #expect(env.printed.count == 1)
    }

    @Test func otherSaveErrorOffersNoRemoval() async throws {
        let locked = base.appendingPathComponent("nur-lesen", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let env = FakeEnvironment()
        env.saveURL = locked.appendingPathComponent("Auswahl.pdf")
        let model = await model(env)
        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage != nil)
        #expect(!model.alertOffersRemovingMissingPages)
    }

    @Test func dismissingTheAlertEndsTheOffer() async throws {
        let env = FakeEnvironment()
        let model = await model(env)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("angebot.pdf"))
        model.printSelection()
        await model.waitUntilIdle()
        #expect(model.alertOffersRemovingMissingPages)
        model.alertMessage = nil
        #expect(!model.alertOffersRemovingMissingPages)
    }

    /// Review of the fixes: a later, unrelated alert must not show the removal button.
    @Test func laterAlertDoesNotKeepTheOffer() async throws {
        let model = await model(FakeEnvironment())
        try FileManager.default.removeItem(at: folder.appendingPathComponent("angebot.pdf"))
        model.printSelection()
        await model.waitUntilIdle()
        #expect(model.alertOffersRemovingMissingPages)
        model.alertMessage = "Index konnte nicht gelöscht werden: x"
        #expect(!model.alertOffersRemovingMissingPages)
    }

    /// Review of the fixes: saving or printing right after „entfernen“ uses the cleaned selection.
    @Test func saveAndPrintWaitForRemoval() async throws {
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = await model(env)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("angebot.pdf"))
        model.printSelection()
        await model.waitUntilIdle()
        model.removeMissingPagesFromSelection()
        model.saveSelection()                      // without waiting for the removal
        model.printSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        #expect(PDFDocument(url: env.saveURL!)?.pageCount == 2)
        #expect(env.printed.count == 1)
    }

    /// Chris (Task 5.6): the print document is built in the background; meanwhile „Druck wird
    /// vorbereitet…“, and a second click on „Drucken …“ starts no second job.
    @Test func printPreparesInBackgroundAndIgnoresSecondClick() async throws {
        let env = FakeEnvironment()
        let model = await model(env)
        model.printSelection()
        #expect(model.isPreparingPrint)
        #expect(env.printed.isEmpty)               // not built synchronously on the main actor
        model.printSelection()                     // double click
        await model.waitUntilIdle()
        #expect(!model.isPreparingPrint)
        #expect(env.printed.count == 1)
        #expect(model.alertMessage == nil)
    }

    /// Review: no save panel while the print document is prepared (the print sheet would land on it).
    @Test func noSaveWhilePreparingPrint() async throws {
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = await model(env)
        model.printSelection()
        model.saveSelection()
        await model.waitUntilIdle()
        #expect(env.printed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: env.saveURL!.path))
    }

    @Test func printFailureEndsPreparing() async throws {
        let env = FakeEnvironment()
        let model = await model(env)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("angebot.pdf"))
        model.printSelection()
        await model.waitUntilIdle()
        #expect(!model.isPreparingPrint)
        #expect(env.printed.isEmpty)
        #expect(model.alertMessage == "Drucken nicht möglich: „angebot.pdf“ kann nicht geöffnet werden")
    }

    @Test func preparingText() {
        #expect(ViewerText.preparingPrint == "Druck wird vorbereitet…")
    }
}
