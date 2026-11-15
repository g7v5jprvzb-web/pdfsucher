import OfficeKit
import Foundation
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.1 §11: every example of the search help runs against the real search (index + matcher).
/// A failing example is reported, not „fixed“ in the help text.
@MainActor @Suite("Search help examples against the real search", .serialized)
struct SearchHelpExampleTests {
    nonisolated static var examples: [HelpExample] { SearchHelp.entries.flatMap(\.examples) }

    @Test(.timeLimit(.minutes(2)), arguments: SearchHelpExampleTests.examples)
    func helpExampleMatchesRealSearch(_ example: HelpExample) async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("PDFs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let texts = example.finds + example.doesNotFind
        for (i, text) in texts.enumerated() {
            let url = folder.appendingPathComponent("t\(i).pdf")
            if example.asScan {
                // A scanned page: the text only as an image, found by the text recognition (spec 1.2).
                try OCRFixtures.makeScanPDF(at: url, images: [try OCRFixtures.textImage([text], size: CGSize(width: 1654, height: 2339)).image])
            } else {
                try PDFFixtures.makePDF(at: url, pages: [text])
            }
        }
        let indexURL = base.appendingPathComponent("index.sqlite")
        let settings = makeSettings()
        settings.partialWords = example.partialWords
        let model = AppModel(settings: settings, defaults: UserDefaults(suiteName: "Help-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
        await model.open(folder: folder)
        await model.waitUntilIdle()
        model.queryText = example.query
        await model.waitUntilIdle()
        let found = Set(model.hits.map { Int($0.url.deletingPathExtension().lastPathComponent.dropFirst())! }.map { texts[$0] })
        #expect(found == Set(example.finds), "„\(example.query)“ found \(found.sorted()), expected \(example.finds)")
    }
}
