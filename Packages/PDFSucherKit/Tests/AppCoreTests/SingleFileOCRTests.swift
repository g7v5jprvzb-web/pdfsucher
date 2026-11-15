import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.2 §2: images and scanned PDFs as single sources (open panel, drag and drop), recognized in the
/// background like folders.
@MainActor @Suite("Single images and scans", .serialized)
struct SingleFileOCRTests {
    let base: URL

    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    func model(defaults: UserDefaults? = nil) -> AppModel {
        AppModel(settings: makeSettings(), defaults: defaults ?? UserDefaults(suiteName: "SFO-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: { _ in FakeIndex() }, officeRendering: PowerPointDisplaySetting())
    }

    func image(_ name: String, _ lines: [String]) throws -> URL {
        let url = base.appendingPathComponent(name)
        try OCRFixtures.write(try OCRFixtures.textImage(lines).image, to: url, type: .png)
        return url
    }

    /// Review minor: a single file changed on disk shows no word boxes of its old version until it is
    /// recognized again.
    @Test(.timeLimit(.minutes(1))) func changedFileShowsNoStaleBoxes() async throws {
        let png = try image("foto.png", ["Mietvertrag Müller"])
        let m = model()
        await m.add([png])
        await m.waitUntilIdle()
        #expect(await m.ocrText(for: PageRefLike(url: png, pageIndex: 0)) != nil)
        try OCRFixtures.write(try OCRFixtures.textImage(["Ganz anderer Inhalt hier"], size: CGSize(width: 1200, height: 900)).image, to: png, type: .png)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: png.path)
        #expect(await m.ocrText(for: PageRefLike(url: png, pageIndex: 0)) == nil)
    }

    /// Final review minor: Vision for single files runs on its own utility thread, not on a thread of the
    /// cooperative pool (search and thumbnails share that pool).
    @Test func singleFileRecognitionRunsOnItsOwnThread() async throws {
        let png = try image("foto.png", ["Mietvertrag"])
        let probe = ThreadProbe()
        let text = try await SingleFileOCR.recognizeOnThread(png, pageIndex: 0, isImage: true, source: probe)
        #expect(text.text == "probe")
        #expect(probe.threadName == "PDFSucher OCR")
    }

    @Test func singleFileRecognitionPassesErrorsOn() async throws {
        let png = try image("foto.png", ["Mietvertrag"])
        await #expect(throws: OCRSourceError.self) {
            try await SingleFileOCR.recognizeOnThread(png, pageIndex: 0, isImage: true, source: FailingOCR())
        }
    }

    /// Final review minor: several single files dropped together are recognized in the order given.
    @Test(.timeLimit(.minutes(1))) func singleFilesAreRecognizedInOrder() async throws {
        let a = try image("a.png", ["Erstes Bild"]), b = try image("b.png", ["Zweites Bild"])
        let m = model()
        await m.add([a, b])
        #expect(m.recognitionQueueForTesting.prefix(2).map { URL(fileURLWithPath: $0).lastPathComponent } == ["a.png", "b.png"])
        await m.waitUntilIdle()
    }

    @Test func classifierAcceptsImagesWhenEnabled() throws {
        let png = try image("a.png", ["x"])
        let upper = base.appendingPathComponent("B.JPG")
        try FileManager.default.copyItem(at: png, to: upper)
        #expect(SourceClassifier.classify([png, upper], includeImages: true).sources.count == 2)
        let off = SourceClassifier.classify([png], includeImages: false)
        #expect(off.sources.isEmpty && off.ignored == [png])
    }

    @Test(.timeLimit(.minutes(1))) func singleImageIsSearchableAfterRecognition() async throws {
        let png = try image("foto.png", ["Mietvertrag Müller"])
        let m = model()
        await m.add([png])
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["foto.png"])          // browsing
        #expect(m.hits.first?.isImage == true)
        #expect(m.hits.first?.pageCount == 1)
        m.queryText = "müller"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["foto.png"])
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [0])
        #expect(m.hits.first?.isImage == true)                      // review minor: symbol also on search hits
        #expect(m.notice == nil)
        let text = await m.ocrText(for: PageRefLike(url: png, pageIndex: 0))
        #expect(text?.text.contains("Müller") == true)
        #expect(text?.words.isEmpty == false)
    }

    @Test(.timeLimit(.minutes(1))) func singleScanPDFPages() async throws {
        let pdf = base.appendingPathComponent("gemischt.pdf")
        try OCRFixtures.makeMixedPDF(at: pdf, text: "Seite eins mit Vertrag und mehr Text als zwanzig Zeichen",
                                     image: try OCRFixtures.textImage(["Kündigung zum Jahresende"], size: CGSize(width: 1654, height: 2339)).image)
        let m = model()
        await m.add([pdf])
        await m.waitUntilIdle()
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [0])
        m.queryText = "Kündigung"
        await m.waitUntilIdle()
        #expect(m.hits.first?.pageHits.map(\.pageIndex) == [1])
        #expect(m.notice == nil)
    }

    @Test func singleImageUnreadable() async throws {
        let broken = base.appendingPathComponent("kaputt.png")
        try Data("kein Bild".utf8).write(to: broken)
        let m = model()
        await m.add([broken])
        await m.waitUntilIdle()
        #expect(m.hits.first?.isUnreadable == true)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.isEmpty)
        #expect(m.notice == "Bild kann nicht gelesen werden")
    }

    @Test func imagesOffIgnoresDroppedImages() async throws {
        let png = try image("foto.png", ["x"])
        let defaults = UserDefaults(suiteName: "SFO-\(UUID().uuidString)")!
        defaults.set(false, forKey: "ocr.includeImages")
        let m = model(defaults: defaults)
        await m.add([png])
        #expect(m.sources.isEmpty)
        #expect(m.notice == "1 Datei ignoriert (nur Ordner und PDFs)")
    }

    // MARK: Review of Task 3

    @Test func ocrOffShowsScanHintForSingleScan() async throws {
        let scan = base.appendingPathComponent("scan.pdf")
        try PDFFixtures.makePDF(at: scan, pages: ["", " "])
        let defaults = UserDefaults(suiteName: "SFO-\(UUID().uuidString)")!
        defaults.set(false, forKey: "ocr.recognizeText")
        let m = model(defaults: defaults)
        await m.add([scan])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.notice == "PDF enthält keinen Text (Scan)")
        let png = try image("foto.png", ["Vertrag"])
        let m2 = model(defaults: defaults)
        await m2.add([png])
        m2.queryText = "Vertrag"
        await m2.waitUntilIdle()
        #expect(m2.notice == "Texterkennung ist aus: Bilder und Scans werden nicht durchsucht")
    }

    @Test(.timeLimit(.minutes(1))) func blankImageSaysNoTextRecognized() async throws {
        let blank = base.appendingPathComponent("leer.png")
        try ImageFixtures.makeSolidImage(at: blank, size: CGSize(width: 400, height: 300), format: .png)
        let m = model()
        await m.add([blank])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.notice == "Im Bild wurde kein Text erkannt")
    }

    /// A file changed after its recognition: the old recognized text is not laid over the new file.
    @Test func staleRecognitionIsIgnored() throws {
        let pdf = base.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Ein neuer Text mit mehr als zwanzig Zeichen"])
        let old = FileStamp.of(pdf)!
        let recognized = [0: OCRPageText(text: "alter Text", words: [])]
        #expect(try OverlayTextSource(isImage: false, recognized: recognized, stamp: old).pages(of: pdf).first?.text == "alter Text")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: pdf.path)
        #expect(try OverlayTextSource(isImage: false, recognized: recognized, stamp: old).pages(of: pdf).first?.text.contains("neuer Text") == true)
    }

    /// Review of Task 6 (§8): a single scan in which recognition found nothing says so.
    @Test(.timeLimit(.minutes(1))) func scanWithoutRecognizedTextSaysSo() async throws {
        let scan = base.appendingPathComponent("leer.pdf")
        try PDFFixtures.makePDF(at: scan, pages: ["", " "])
        let m = model()
        await m.add([scan])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.notice == "Im PDF wurde kein Text erkannt")
    }
}

typealias PageRefLike = OutputKit.PageRef

/// Records the name of the thread `recognize` runs on.
private final class ThreadProbe: OCRSource, @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    var threadName: String? { lock.withLock { name } }
    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult {
        let current = Thread.current.name
        lock.withLock { name = current }
        return OCRResult(text: "probe", words: [])
    }
}

private struct FailingOCR: OCRSource {
    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult { throw OCRSourceError.unreadable(url) }
}
