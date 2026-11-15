import Foundation
import PDFKit
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.2 §3 wired into the AppModel queue: phase 1 (text) for every folder first, then phase 2 (text
/// recognition) in the background; new folders pre-empt a running recognition.
@MainActor @Suite("Text recognition in the queue")
struct OCRQueueTests {
    let base: URL
    let eins: URL, zwei: URL

    init() throws {
        base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        eins = base.appendingPathComponent("eins", isDirectory: true)
        zwei = base.appendingPathComponent("zwei", isDirectory: true)
        for dir in [eins, zwei] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func indexes(_ names: [String], log: StringLog) -> [String: FakeIndex] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            return (name, index)
        })
    }

    func model(_ indexes: [String: FakeIndex], defaults: UserDefaults? = nil) -> AppModel {
        AppModel(settings: makeSettings(), defaults: defaults ?? UserDefaults(suiteName: "OCRQ-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in indexes[root.lastPathComponent]! }, officeRendering: PowerPointDisplaySetting())
    }

    @Test func phase1OfAllFoldersBeforeRecognition() async {
        let log = StringLog()
        let m = model(indexes(["eins", "zwei"], log: log))
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "zwei:update-start", "zwei:update-end",
                                "eins:ocr-start", "eins:ocr-end", "zwei:ocr-start", "zwei:ocr-end"])
        #expect(m.indexStatus == .upToDate)
    }

    @Test func newFolderPreemptsRecognition() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        await m.add([zwei])
        #expect(await eventually { log.entries.contains("zwei:update-end") })
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end", "eins:ocr-start", "eins:ocr-cancelled",
                                "zwei:update-start", "zwei:update-end", "eins:ocr-start", "eins:ocr-end",
                                "zwei:ocr-start", "zwei:ocr-end"])
    }

    /// Final review I1: a single scan or image dropped in during a long folder recognition is recognized
    /// first; the folder resumes afterwards.
    @Test(.timeLimit(.minutes(1))) func newSingleFilePreemptsFolderRecognition() async throws {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        let photo = base.appendingPathComponent("beleg.png")
        try OCRFixtures.write(try OCRFixtures.textImage(["Quittung Kündigung"]).image, to: photo, type: .png)
        await m.add([photo])
        m.queryText = "Quittung"
        #expect(await eventually(.seconds(20)) { m.hits.contains { $0.url.lastPathComponent == "beleg.png" } },
                "the photo is found while the folder's recognition is still held")
        #expect(log.entries.contains("eins:ocr-cancelled"))
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(log.entries.last == "eins:ocr-end")
    }

    @Test func recognitionStatusText() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { m.indexStatus == .recognizing(folder: 1, folders: 1, done: 0, total: 5) })
        idx["eins"]!.emitProgress(IndexProgress(done: 3, total: 5, currentFile: nil, phase: .ocr))
        #expect(await eventually { m.indexStatus == .recognizing(folder: 1, folders: 1, done: 3, total: 5) })
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(ViewerText.indexStatus(.recognizing(folder: 1, folders: 1, done: 120, total: 3400)) == "Texterkennung 120/3.400")
        #expect(ViewerText.indexStatus(.recognizing(folder: 2, folders: 3, done: 120, total: 3400)) == "Texterkennung Ordner 2/3: 120/3.400")
    }

    @Test func stopRecognitionKeepsFinished() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        m.stopRecognition()
        await m.waitUntilIdle()
        #expect(log.entries.last == "eins:ocr-cancelled")
        #expect(m.indexStatus == .upToDate)
        #expect(m.isRecognitionStopped)
        // A new source resumes the recognition (also of the stopped folder).
        idx["eins"]!.holdRecognition = false
        await m.add([zwei])
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(4)) == ["eins:ocr-start", "eins:ocr-end", "zwei:ocr-start", "zwei:ocr-end"])
        #expect(!m.isRecognitionStopped)
    }

    @Test func phase2RefreshesResults() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        idx["eins"]!.hitsAfterRecognition = [doc("scan.pdf", pages: [0], root: "/eins")]
        let m = model(idx)
        await m.add([eins])
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(m.hits.isEmpty)
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["scan.pdf"])
    }

    @Test func deleteIndexWhileRecognizing() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        let deleting = Task { await m.deleteIndex(for: eins) }
        #expect(await eventually { log.entries.contains("eins:ocr-cancelled") })
        idx["eins"]!.holdRecognition = false
        await deleting.value
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(5)) == ["eins:ocr-cancelled", "eins:update-start", "eins:update-end", "eins:ocr-start", "eins:ocr-end"])
        #expect(idx["eins"]!.events.contains("delete"))
    }

    @Test func recognitionOffSkipsPhase2() async {
        let log = StringLog()
        let defaults = UserDefaults(suiteName: "OCRQ-\(UUID().uuidString)")!
        defaults.set(false, forKey: "ocr.recognizeText")
        let m = model(indexes(["eins"], log: log), defaults: defaults)
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(log.entries == ["eins:update-start", "eins:update-end"])
    }

    /// Real index and Vision: a scanned PDF and an image become searchable by phase 2.
    @Test(.timeLimit(.minutes(2))) func scanFolderBecomesSearchable() async throws {
        let folder = base.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try OCRFixtures.makeScanPDF(at: folder.appendingPathComponent("scan.pdf"),
                                    images: [try OCRFixtures.textImage(["Kündigungsfrist beachten"], size: CGSize(width: 1654, height: 2339)).image])
        try OCRFixtures.write(try OCRFixtures.textImage(["Mietvertrag Müller"]).image,
                              to: folder.appendingPathComponent("foto.png"), type: .png)
        let indexURL = base.appendingPathComponent("scans.sqlite")
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "OCRQ-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                         openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
        await m.add([folder])
        await m.waitUntilIdle()
        let index = try FolderIndex.shared(root: folder, indexURL: indexURL, slideCache: testSlideCache)
        #expect(try index.ocrCounts() == (pages: 1, images: 1), "\(m.indexStatus)")
        m.queryText = "Kündigungsfrist"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["scan.pdf"])
        let scanText = await m.ocrText(for: PageRef(url: try #require(m.hits.first).url, pageIndex: 0))
        #expect(scanText?.text.contains("beachten") == true)
        #expect(scanText?.words.isEmpty == false)
        m.queryText = "müller"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["foto.png"])
        #expect(m.hits.first?.isImage == true)
        m.queryText = ""                                   // browsing lists the image with one page
        await m.waitUntilIdle()
        let foto = m.hits.first { $0.relativePath == "foto.png" }
        #expect(foto?.isImage == true && foto?.pageCount == 1)
        #expect(m.hits.first { $0.relativePath == "scan.pdf" }?.pageCount == 1)
    }

    // MARK: Task 2: settings (spec 1.2 §7)

    @Test func settingsPersistDefaultsOn() {
        let defaults = UserDefaults(suiteName: "OCRQ-\(UUID().uuidString)")!
        let p = OCRPreferences(defaults: defaults)
        #expect(p.recognizeText && p.includeImages)
        p.recognizeText = false
        p.includeImages = false
        let again = OCRPreferences(defaults: defaults)
        #expect(!again.recognizeText && !again.includeImages)
    }

    @Test func switchingOCROffStopsPhase2() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        m.ocrPreferences.recognizeText = false
        #expect(await eventually { log.entries.last == "eins:ocr-cancelled" })
        await m.waitUntilIdle()
        #expect(m.indexStatus == .upToDate)
        idx["eins"]!.holdRecognition = false
        m.ocrPreferences.recognizeText = true
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(2)) == ["eins:ocr-start", "eins:ocr-end"])
    }

    @Test func switchingImagesOffRescans() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        m.ocrPreferences.includeImages = false
        await m.waitUntilIdle()
        #expect(idx["eins"]!.configured.last == OCRSettings(recognizeText: true, includeImages: false))
        #expect(idx["zwei"]!.configured.last == OCRSettings(recognizeText: true, includeImages: false))
        #expect(log.entries.filter { $0 == "eins:update-start" }.count == 2)
        #expect(log.entries.filter { $0 == "zwei:update-start" }.count == 2)
    }

    @Test func rerunRecognitionForOneSource() async {
        let log = StringLog()
        let idx = indexes(["eins", "zwei"], log: log)
        let m = model(idx)
        await m.add([eins, zwei])
        await m.waitUntilIdle()
        m.stopRecognition()
        m.rerunRecognition(for: zwei)
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(3)) == ["zwei:reset-ocr", "zwei:ocr-start", "zwei:ocr-end"])
        #expect(!m.isRecognitionStopped)
    }

    @Test func countsPerSource() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.counts = (pages: 120, images: 7)
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        let counts = await m.ocrCounts(for: eins)
        #expect(counts?.pages == 120 && counts?.images == 7)
        #expect(await m.ocrCounts(for: zwei) == nil)
        #expect(ViewerText.ocrCounts(pages: 120, images: 7) == "120 Seiten und 7 Bilder erkannt")
        #expect(ViewerText.ocrCounts(pages: 1, images: 1) == "1 Seite und 1 Bild erkannt")
        #expect(ViewerText.ocrCounts(pages: 0, images: 0) == "Noch nichts erkannt")
    }

    // MARK: Review of Task 1

    /// Scans are not „nicht lesbar“ while recognition is on: only what recognition found no text in counts.
    @Test func scansAreNotListedAsUnreadableWhenRecognized() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.report = IndexReport(noText: ["scan.pdf", "leer.pdf"])
        idx["eins"]!.ocrReport = OCRReport(recognized: 1, noText: ["leer.pdf"])
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: [], noText: ["leer.pdf"]))
        m.ocrPreferences.recognizeText = false
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: [], noText: ["scan.pdf", "leer.pdf"]))
    }

    /// A damaged index found by a search during the recognition of that folder is rebuilt at once.
    @Test func damageFoundDuringRecognitionRebuilds() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        idx["eins"]!.failNextSearch(with: IndexStoreError.corruptIndexRebuilt)
        m.queryText = "Vertrag"
        #expect(await eventually { log.entries.contains("eins:ocr-cancelled") })
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(4)) == ["eins:update-start", "eins:update-end", "eins:ocr-start", "eins:ocr-end"])
        #expect(m.notice == nil)
    }

    @Test func deleteIndexForgetsOldOCRProblems() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.ocrReport = OCRReport(failed: ["kaputt.png"])
        let m = model(idx)
        await m.add([eins])
        await m.waitUntilIdle()
        #expect(m.indexStatus == .problems(failed: ["kaputt.png"], noText: []))
        idx["eins"]!.ocrReport = OCRReport()
        m.ocrPreferences.recognizeText = false
        await m.deleteIndex(for: eins)
        await m.waitUntilIdle()
        #expect(m.indexStatus == .upToDate)
    }

    // MARK: Review of Task 2

    @Test func rerunWhileThatFolderIsRecognized() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        m.rerunRecognition(for: eins)
        #expect(await eventually { log.entries.contains("eins:ocr-cancelled") })
        idx["eins"]!.holdRecognition = false
        await m.waitUntilIdle()
        #expect(Array(log.entries.suffix(4)) == ["eins:reset-ocr", "eins:ocr-cancelled", "eins:ocr-start", "eins:ocr-end"])
    }

    @Test func resumeAfterStop() async {
        let log = StringLog()
        let idx = indexes(["eins"], log: log)
        idx["eins"]!.holdRecognition = true
        let m = model(idx)
        await m.add([eins])
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        m.stopRecognition()
        await m.waitUntilIdle()
        #expect(m.isRecognitionStopped)
        idx["eins"]!.holdRecognition = false
        m.resumeRecognition()
        await m.waitUntilIdle()
        #expect(log.entries.last == "eins:ocr-end")
        // OCR off and on again also resumes after ✕.
        idx["eins"]!.holdRecognition = true
        m.rerunRecognition(for: eins)
        #expect(await eventually { log.entries.last == "eins:ocr-start" })
        m.stopRecognition()
        await m.waitUntilIdle()
        idx["eins"]!.holdRecognition = false
        m.ocrPreferences.recognizeText = false
        await m.waitUntilIdle()
        m.ocrPreferences.recognizeText = true
        await m.waitUntilIdle()
        #expect(log.entries.last == "eins:ocr-end")
        #expect(!m.isRecognitionStopped)
    }

    // MARK: Task 6: output (spec 1.2 §6)

    /// A text PDF page, a scan page and an image, ticked and saved: three pages in grid order, the image
    /// as an A4 page.
    @Test(.timeLimit(.minutes(2))) func mixedSelectionSavesInGridOrder() async throws {
        let folder = base.appendingPathComponent("gemischt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("a_text.pdf"), pages: ["Der Vertrag mit Textebene ist hier."])
        try OCRFixtures.makeScanPDF(at: folder.appendingPathComponent("b_scan.pdf"),
                                    images: [try OCRFixtures.textImage(["Vertrag gescannt"], size: CGSize(width: 1654, height: 2339)).image])
        try OCRFixtures.write(try OCRFixtures.textImage(["Vertrag im Foto"]).image, to: folder.appendingPathComponent("c_foto.png"), type: .png)
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let indexURL = base.appendingPathComponent("gemischt.sqlite")
        let settings = makeSettings()
        settings.sort = .fileName
        let m = AppModel(settings: settings, defaults: UserDefaults(suiteName: "OCRQ-\(UUID().uuidString)")!,
                         environment: env, slideCache: testSlideCache, debounce: .zero, openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
        await m.add([folder])
        await m.waitUntilIdle()
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["a_text.pdf", "b_scan.pdf", "c_foto.png"])
        for hit in m.hits.reversed() { m.selection.toggle(PageRef(url: hit.url, pageIndex: 0)) }
        m.saveSelection()
        await m.waitUntilIdle()
        #expect(m.alertMessage == nil)
        let savedURL = try #require(env.saveURL)
        let saved = try #require(PDFDocument(url: savedURL))
        #expect(saved.pageCount == 3)
        #expect(saved.page(at: 0)?.string?.contains("Textebene") == true)
        let a4 = try #require(saved.page(at: 2)).bounds(for: .mediaBox)
        #expect(abs(a4.width - 841.89) < 1 && abs(a4.height - 595.28) < 1)          // landscape photo → A4 landscape
    }
}
