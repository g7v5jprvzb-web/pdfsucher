import CoreGraphics
import Foundation
import IndexKit
import Synchronization
import Testing
import TestSupport
import WebKit
@testable import OfficeKit

/// Task 6 (1.3 Office): PowerPoint slides from the Quick Look HTML preview (WKWebView snapshots + text + word boxes).
/// Needs macOS's own `Office.qlgenerator`; without it every test that renders records an issue instead of passing.
@Suite("Quick Look slide source", .serialized)
struct QuickLookSlideSourceTests {
    let dir: URL
    let cacheRoot: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        cacheRoot = dir.appendingPathComponent("SlideCache", isDirectory: true)
    }

    private static let slides = ["Alpha Kündigungsfrist", "Beta", "Gamma"]

    /// False (and an issue recorded) when this Mac has no Office Quick Look generator.
    private func generatorAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: QuickLookHTML.officeGenerator) else {
            Issue.record("\(QuickLookHTML.officeGenerator) fehlt – PowerPoint-Vorschau über Quick Look nicht testbar")
            return false
        }
        return true
    }

    private func source(generator: (@Sendable (URL) async throws -> QuickLookOutput)? = nil) -> QuickLookSlideSource {
        let cache = SlideCache(root: cacheRoot)
        guard let generator else { return QuickLookSlideSource(cache: cache) }
        return QuickLookSlideSource(cache: cache, generate: generator)
    }

    private func key(for url: URL) throws -> SlideCacheKey {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SlideCacheKey(url: url, fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// Names in the cache root ending in `.tmp` (unfinished entries); empty when the root does not exist.
    private func tmpFolders() throws -> [String] {
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).filter { $0.hasSuffix(".tmp") }
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    /// Records the folders the injected generator handed out.
    private final class Folders: Sendable {
        let value = Mutex<[URL]>([])
        var all: [URL] { value.withLock { $0 } }
        func record(_ url: URL) { value.withLock { $0.append(url) } }
    }

    // MARK: PresentationSlides

    @Test func visibleSlidesSkipHidden() throws {
        let deck = try OfficeFixtures.pptx(slides: ["Eins", "Zwei", "Drei", "Vier"], hidden: [1], in: dir)
        #expect(try PresentationSlides.visibleSlideNumbers(of: deck) == [1, 3, 4])
    }

    @Test func slideListRespectsFirstSlideNumber() throws {
        let deck = try OfficeFixtures.pptx(slides: ["Eins", "Zwei", "Drei"], hidden: [0], in: dir)
        let slides = try PresentationSlides.slides(of: deck)
        #expect(slides.map(\.partPath) == ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml"])
        #expect(slides.map(\.hidden) == [true, false, false])
        #expect(slides.map(\.powerPointNumber) == [1, 2, 3])
        #expect(PresentationSlides.firstSlideNumber(inPresentationXML: Data(#"<p:presentation xmlns:p="x" firstSlideNum="5"/>"#.utf8)) == 5)
    }

    @Test func notAZipIsUnreadable() throws {
        let garbage = dir.appendingPathComponent("kaputt.pptx")
        try Data("kein zip".utf8).write(to: garbage)
        #expect(throws: LayoutSourceError.self) { try PresentationSlides.visibleSlideNumbers(of: garbage) }
    }

    // MARK: QuickLookSlideSource

    @Test func rendererIsQuickLook() {
        let renderer = QuickLookSlideSource().renderer(for: .powerpoint)
        #expect(renderer.name == "quicklook")
        #expect(renderer.version == 1)
    }

    @Test func textPerSlideMatchesFixture() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let result = try await source().layout(of: deck, kind: .powerpoint)
        #expect(result.renderer == "quicklook")
        #expect(result.layoutVersion == 1)
        try #require(result.pages.count == 3)
        #expect(result.pages[0].text.contains(TextNormalizer.normalize("Kündigungsfrist")))
        #expect(result.pages[1].text.contains("Beta"))
        #expect(result.pages[2].text.contains("Gamma"))
        #expect(result.pages[0].size == CGSize(width: 720, height: 540))
    }

    /// `.pptm` (macro-enabled content type) goes through Quick Look like `.pptx`.
    @Test func macroEnabledDeckLaysOut() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, name: "Makro.pptm", in: dir)
        let types = try String(decoding: #require(ZipArchive(url: deck).data(at: "[Content_Types].xml")), as: UTF8.self)
        #expect(types.contains("presentation.macroEnabled.main+xml"))
        let result = try await source().layout(of: deck, kind: .powerpoint)
        try #require(result.pages.count == 3)
        #expect(result.pages[1].text.contains("Beta"))
        #expect(!result.pages[0].words.isEmpty)
    }

    @Test func wordBoxesInsideSlide() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let result = try await source().layout(of: deck, kind: .powerpoint)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for page in result.pages {
            #expect(!page.words.isEmpty)
            for word in page.words {
                #expect(unit.contains(word.box), "\(word.box)")
                #expect(NSMaxRange(word.range) <= (page.text as NSString).length)
            }
        }
        let page = try #require(result.pages.first)
        let target = TextNormalizer.normalize("Kündigungsfrist")
        let word = try #require(page.words.first { Self.substring(page.text, $0.range) == target })
        #expect(word.box.width > 0.1)
        #expect(word.box.height > 0.02)
        #expect(word.box.maxY < 0.5) // the fixture's text box sits at the top of the slide
        let alpha = try #require(page.words.first { Self.substring(page.text, $0.range) == "Alpha" })
        #expect(alpha.box.maxX <= word.box.minX) // "Alpha" stands left of "Kündigungsfrist"
    }

    @Test func slideNumberPlaceholderReplaced() async throws {
        guard generatorAvailable() else { return }
        // Slide 2 hidden: the last visible slide is PowerPoint slide 3, not the second div in the HTML.
        let deck = try OfficeFixtures.pptx(slides: Self.slides, hidden: [1], slideNumberFieldOn: [2], in: dir)
        let result = try await source().layout(of: deck, kind: .powerpoint)
        try #require(result.pages.count == 2)
        let last = result.pages[1].text
        #expect(last.contains("Gamma"))
        #expect(last.split(separator: " ").contains("3"), "\(last)")
        #expect(!last.contains("‹#›"))
        #expect(!last.contains("<#>"))
        #expect(result.pages[1].words.contains { Self.substring(last, $0.range) == "3" })
    }

    @Test func imagesCached() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let rescales = await SlideSnapshotter.rescaleCount
        _ = try await source().layout(of: deck, kind: .powerpoint)
        #expect(await SlideSnapshotter.rescaleCount == rescales) // WebKit already delivered 2800 px, no upscale
        let cache = SlideCache(root: cacheRoot)
        let key = try key(for: deck)
        #expect(cache.slideCount(for: key) == 3)
        let image = try #require(cache.image(for: key, slide: 0))
        #expect(max(image.width, image.height) == SlideCache.maxLongSide)
        #expect(image.width * 3 == image.height * 4)
        #expect(try tmpFolders().isEmpty)
    }

    @Test func slideCountMismatchIsUnreadable() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let fake = source(generator: Self.fakeGenerator(slides: 1, folders: folders)) // the deck has 3
        await #expect(throws: LayoutSourceError.unreadable(deck, reason: "Vorschau nicht möglich")) {
            try await fake.layout(of: deck, kind: .powerpoint)
        }
        let folder = try #require(folders.all.first)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(SlideCache(root: cacheRoot).slideCount(for: try key(for: deck)) == nil)
        #expect(try tmpFolders().isEmpty)
    }

    /// Each slide image goes into the cache's `.tmp` folder right after its snapshot (Task 10b: no array of all
    /// images in memory); the entry appears only after the last slide.
    @Test func slideImagesAreStreamedIntoTheCache() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let root = cacheRoot
        let seen = Mutex<[[String]]>([])
        let streaming = QuickLookSlideSource(cache: SlideCache(root: root), generate: Self.fakeGenerator(slides: 3, folders: folders)) {
            step, _ in
            guard case .beforeSlide = step else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let tmp = names.first { $0.hasSuffix(".tmp") }
            let files = tmp.flatMap { try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent($0).path) } ?? []
            seen.withLock { $0.append(files.sorted()) }
        }
        let result = try await streaming.layout(of: deck, kind: .powerpoint)
        #expect(result.pages.count == 3)
        #expect(seen.withLock { $0 } == [[], ["0.heic"], ["0.heic", "1.heic"]])
        #expect(SlideCache(root: cacheRoot).slideCount(for: try key(for: deck)) == 3)
        #expect(try tmpFolders().isEmpty)
    }

    /// The image sink (where `QuickLookSlideSource` HEIC-encodes) runs off the main thread, although the snapshotter
    /// itself is main-actor bound. `QuickLookSlideSource` additionally checks this with a debug `dispatchPrecondition`.
    @Test func imageSinkRunsOffMainThread() async throws {
        let folders = Folders()
        let output = try await Self.fakeGenerator(slides: 3, folders: folders)(dir)
        defer { output.remove() }
        let onMain = Mutex<[Bool]>([])
        let slides = try await SlideSnapshotter().slides(fromHTML: output.html, readAccess: output.directory,
                                                         maxPixel: 400, slideNumbers: [1, 2, 3]) { _, _ in
            let main = pthread_main_np() != 0 // Thread.isMainThread is unavailable in async code
            onMain.withLock { $0.append(main) }
        }
        #expect(slides.count == 3)
        #expect(onMain.withLock { $0 } == [false, false, false])
    }

    /// A failure after some slides were written leaves neither a partial entry nor a `.tmp` folder, and an older
    /// complete entry of the same key stays.
    @Test func failureAfterSomeSlidesLeavesNoPartialEntry() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let failing = QuickLookSlideSource(cache: SlideCache(root: cacheRoot), generate: Self.fakeGenerator(slides: 3, folders: folders)) {
            step, view in
            if step == .beforeSlide(2) { _ = try await view.call("throw new Error('kaputt')") }
        }
        await #expect(throws: LayoutSourceError.unreadable(deck, reason: "Vorschau nicht möglich")) {
            try await failing.layout(of: deck, kind: .powerpoint)
        }
        #expect(SlideCache(root: cacheRoot).slideCount(for: try key(for: deck)) == nil)
        #expect(try tmpFolders().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(folders.all.first).path))
    }

    @Test func cancellationRemovesTemporaryDirectory() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let cancelling = source { url in
            let output = try await QuickLookHTML().generate(for: url)
            folders.record(output.directory)
            withUnsafeCurrentTask { $0?.cancel() } // as if the Indexer gave up right after the HTML was written
            return output
        }
        // In its own task, so cancelling it does not cancel the test.
        let result = await Task { try await cancelling.layout(of: deck, kind: .powerpoint) }.result
        #expect(throws: CancellationError.self) { try result.get() }
        let folder = try #require(folders.all.first)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Weak references to the snapshotter's web view, filled by the hook.
    @MainActor private final class ViewProbe {
        weak var wrapper: SnapshotWebView?
        weak var webView: WKWebView?
    }

    /// Cancels the layout at a set step (from inside the snapshotter, so no timing is involved) and checks that the
    /// error is `CancellationError`, the preview folder is gone and the web view was released.
    @Test(arguments: [SlideSnapshotter.Step.beforeLoad, .afterLoad, .beforeImageWait, .beforeWarmUp, .beforeSlide(1)])
    func cancellationInsideSnapshotterCleansUp(step: SlideSnapshotter.Step) async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let probe = ViewProbe()
        let cancelling = QuickLookSlideSource(cache: SlideCache(root: cacheRoot), generate: Self.fakeGenerator(slides: 3, folders: folders)) {
            current, view in
            probe.wrapper = view
            probe.webView = view.view
            if current == step { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await Task { try await cancelling.layout(of: deck, kind: .powerpoint) }.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: try #require(folders.all.first).path))
        #expect(SlideCache(root: cacheRoot).slideCount(for: try key(for: deck)) == nil)
        #expect(try tmpFolders().isEmpty)
        await MainActor.run {
            #expect(probe.wrapper == nil)
            #expect(probe.webView == nil)
        }
    }

    /// Cancelling while WebKit is still loading the preview (a named pipe as image keeps the load from finishing)
    /// ends the layout promptly with `CancellationError` and cleans up — the Indexer's cancel reaches the web view.
    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileLoadingEndsPromptly() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let fifo = Mutex<URL?>(nil)
        let generator: @Sendable (URL) async throws -> QuickLookOutput = { url in
            let output = try await Self.fakeGenerator(slides: 3, folders: folders)(url)
            let pipe = output.directory.appendingPathComponent("haengt.png")
            #expect(mkfifo(pipe.path, 0o600) == 0)
            fifo.withLock { $0 = pipe }
            try Data("<html><body><img src=\"haengt.png\"><div class=\"slide\" style=\"width:720px;height:540px\">A</div></body></html>".utf8)
                .write(to: output.html)
            return output
        }
        let loaded = Mutex(false)
        let source = QuickLookSlideSource(cache: SlideCache(root: cacheRoot), generate: generator) { step, _ in
            if step == .afterLoad { loaded.withLock { $0 = true } }
        }
        let task = Task { try await source.layout(of: deck, kind: .powerpoint) }
        try await Task.sleep(for: .milliseconds(500)) // well inside the (never finishing) load
        // Take WebKit's reader out of its blocking open(): it then waits in read() until we close, so the load
        // still does not finish, and no WebKit thread stays stuck after the test (-1 if nobody reads yet).
        let writer = try #require(fifo.withLock { $0 }).withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_NONBLOCK) }
        defer { if writer >= 0 { close(writer) } }
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = await task.result
        #expect(clock.now - start < .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!loaded.withLock { $0 }) // it really was cancelled during the load
        #expect(!FileManager.default.fileExists(atPath: try #require(folders.all.first).path))
        #expect(try tmpFolders().isEmpty)
    }

    @Test func webKitFailureIsUnreadable() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let folders = Folders()
        let failing = QuickLookSlideSource(cache: SlideCache(root: cacheRoot), generate: Self.fakeGenerator(slides: 3, folders: folders)) {
            step, view in
            if step == .beforeImageWait { _ = try await view.call("throw new Error('kaputt')") }
        }
        await #expect(throws: LayoutSourceError.unreadable(deck, reason: "Vorschau nicht möglich")) {
            try await failing.layout(of: deck, kind: .powerpoint)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(folders.all.first).path))
        #expect(try tmpFolders().isEmpty)
    }

    @MainActor @Test func scriptAndDecodingErrorsBecomeSnapshotterErrors() async throws {
        let folders = Folders()
        let output = try await Self.fakeGenerator(slides: 1, folders: folders)(dir)
        defer { output.remove() }
        let view = SnapshotWebView()
        defer { view.tearDown() }
        try await view.load(output.html, readAccess: output.directory)
        await #expect(throws: SlideSnapshotterError.self) { _ = try await view.call("throw new Error('kaputt')") }
        await #expect(throws: SlideSnapshotterError.self) { _ = try await view.decode(Int.self, "return 'kein json'") }
        await #expect(throws: SlideSnapshotterError.self) { _ = try await view.decode(Int.self, "return 42") }
    }

    /// A Quick Look stand-in that writes `slides` plain `div.slide`s into a fresh `PDFSucher-QL` folder.
    private static func fakeGenerator(slides: Int, folders: Folders) -> @Sendable (URL) async throws -> QuickLookOutput {
        { _ in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFSucher-QL", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            folders.record(directory)
            let html = directory.appendingPathComponent("Preview.html")
            let body = (0..<slides).map {
                #"<div class="slide" style="position:relative;width:720px;height:540px;margin:5px 8px"><p>Folie \#($0 + 1)</p></div>"#
            }.joined()
            try Data("<html><body>\(body)</body></html>".utf8).write(to: html)
            return QuickLookOutput(directory: directory, html: html)
        }
    }

    @Test func cacheKeyUsesGivenPathWithSizeAndDateOfTarget() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let link = dir.appendingPathComponent("Verweis.pptx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: deck)
        _ = try await source().layout(of: link, kind: .powerpoint)
        let values = try deck.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = SlideCacheKey(url: link, fileSize: Int64(try #require(values.fileSize)),
                                modifiedAt: try #require(values.contentModificationDate))
        #expect(SlideCache(root: cacheRoot).slideCount(for: key) == 3)
    }

    // MARK: ZIP reader limits

    /// Copies the deck and overwrites 4 bytes at `offset` from the central directory entry of `ppt/presentation.xml`
    /// (or, with `eocd`, from the end-of-central-directory record).
    private func patchedDeck(at offset: Int, eocd: Bool = false, value: UInt32) throws -> URL {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, name: "Basis-\(UUID().uuidString).pptx", in: dir)
        var bytes = [UInt8](try Data(contentsOf: deck))
        let base: Int
        if eocd {
            base = try #require((0...(bytes.count - 22)).reversed().first { bytes[$0..<$0 + 4] == [0x50, 0x4B, 0x05, 0x06] })
        } else {
            let name = Array("ppt/presentation.xml".utf8)
            base = try #require((0..<(bytes.count - 46)).first {
                bytes[$0..<$0 + 4] == [0x50, 0x4B, 0x01, 0x02] && Array(bytes[($0 + 46)..<min($0 + 46 + name.count, bytes.count)]) == name
            })
        }
        for i in 0..<4 { bytes[base + offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        let patched = dir.appendingPathComponent("patched-\(UUID().uuidString).pptx")
        try Data(bytes).write(to: patched)
        return patched
    }

    @Test func oversizedEntryIsNotInflated() throws {
        let deck = try patchedDeck(at: 24, value: UInt32(ZipArchive.maxEntrySize + 1)) // uncompressed size
        #expect(try ZipArchive(url: deck).data(at: "ppt/presentation.xml") == nil)
        #expect(throws: LayoutSourceError.self) { try PresentationSlides.visibleSlideNumbers(of: deck) }
    }

    @Test func zip64MarkersAreRejected() throws {
        for (offset, eocd, value) in [(42, false, UInt32.max), (20, false, UInt32.max), (24, false, UInt32.max),
                                      (16, true, UInt32.max), (8, true, UInt32(0xFFFF_FFFF))] {
            let deck = try patchedDeck(at: offset, eocd: eocd, value: value)
            #expect(throws: ZipArchive.Failure.self) { try ZipArchive(url: deck) }
            #expect(throws: LayoutSourceError.self) { try PresentationSlides.visibleSlideNumbers(of: deck) }
        }
    }

    @Test func garbageFileIsUnreadable() async throws {
        let garbage = dir.appendingPathComponent("x.pptx")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        await #expect(throws: LayoutSourceError.unreadable(garbage, reason: "Vorschau nicht möglich")) {
            try await source().layout(of: garbage, kind: .powerpoint)
        }
    }

    // MARK: SlideSnapshotter

    @MainActor @Test func snapshotLongSideIsMaxPixel() async throws {
        guard generatorAvailable() else { return }
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let output = try await QuickLookHTML().generate(for: deck)
        defer { output.remove() }
        let rescales = SlideSnapshotter.rescaleCount
        let images = Mutex<[Int: CGImage]>([:])
        let slides = try await SlideSnapshotter().slides(fromHTML: output.html, readAccess: output.directory,
                                                         maxPixel: 1000, slideNumbers: [1, 2, 3]) { index, image in
            images.withLock { $0[index] = image }
        }
        try #require(slides.count == 3)
        #expect(images.withLock { $0.keys.sorted() } == [0, 1, 2])
        let first = try #require(images.withLock { $0[0] })
        #expect(first.width == 1000)
        #expect(first.height == 750)
        #expect(SlideSnapshotter.rescaleCount == rescales)
        #expect(slides[0].size == CGSize(width: 720, height: 540))
        #expect(slides[0].text.contains("Alpha Kündigungsfrist"))
        #expect(Self.imageHasInk(first))
    }

    /// The preview must never reach the network: http/https images and frames in Quick Look's HTML are blocked
    /// (content rule list + navigation policy), and the slides are still rendered. A local listening socket counts
    /// every connection attempt (it accepts and closes at once, so an unblocked load would not hang).
    @Test(.timeLimit(.minutes(1)))
    func previewMakesNoNetworkRequests() async throws {
        let listener = try LocalListener()
        defer { listener.stop() }
        let directory = dir.appendingPathComponent("netz", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let html = directory.appendingPathComponent("Preview.html")
        let port = listener.port
        try Data("""
            <html><head><link rel="stylesheet" href="http://127.0.0.1:\(port)/s.css"></head><body>
            <img src="http://127.0.0.1:\(port)/x.png"><img src="https://127.0.0.1:\(port)/y.png">
            <iframe src="http://127.0.0.1:\(port)/f.html"></iframe>
            <div class="slide" style="position:relative;width:720px;height:540px"><p>Folie Netz</p></div>
            </body></html>
            """.utf8).write(to: html)
        let slides = try await SlideSnapshotter().slides(fromHTML: html, readAccess: directory, maxPixel: 400,
                                                         slideNumbers: [1]) { _, _ in }
        #expect(slides.count == 1)
        #expect(slides.first?.text.contains("Folie Netz") == true)
        try await Task.sleep(for: .milliseconds(200)) // a late connection would still be counted
        #expect(listener.connections == 0)
    }

    /// A TCP listener on 127.0.0.1 (random port) that counts and closes every connection.
    private final class LocalListener: Sendable {
        let port: Int
        private let fd: Int32
        private let count = Mutex(0)
        var connections: Int { count.withLock { $0 } }

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            try #require(bound == 0 && listen(fd, 16) == 0)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = Int(UInt16(bigEndian: address.sin_port))
            self.fd = fd
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return } // listener closed
                    count.withLock { $0 += 1 }
                    close(client)
                }
            }
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// True when the image is not one flat colour (the slide's text was drawn).
    private static func imageHasInk(_ image: CGImage) -> Bool {
        let width = 200, height = 150
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var dark = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) where pixels[i] < 100 && pixels[i + 1] < 100 && pixels[i + 2] < 100 {
            dark += 1
        }
        return dark > 20
    }
}
