import AppKit
import CoreGraphics
import Foundation
import IndexKit
import OOXMLKit
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// Task 7 (1.3 Office): interim Word layout via NSAttributedString + TextKit 1.
@Suite("TextKit Word")
struct TextKitWordTests {
    let dir: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
    }

    /// A4 from the fixture's `w:sectPr` (11906 × 16838 twips), margins 1417/1417/1134/1417 twips.
    static let a4 = CGSize(width: 11906.0 / 20, height: 16838.0 / 20)

    @Test func pageBreaksFromFixture() async throws {
        let url = try OfficeFixtures.docx(paragraphs: ["Erste Seite Alpha", "Zweite Seite Beta", "Dritte Seite Gamma"],
                                          pageBreakAfter: [0, 1], in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageCount == 3)
        let texts = (0..<document.pageCount).map { document.page($0).text }
        #expect(texts[0].contains("Alpha") && !texts[0].contains("Beta"))
        #expect(texts[1].contains("Beta") && !texts[1].contains("Alpha") && !texts[1].contains("Gamma"))
        #expect(texts[2].contains("Gamma") && !texts[2].contains("Beta"))
        #expect(document.pageSize(0) == Self.a4)

        let result = try await TextKitWordSource().layout(of: url, kind: .word)
        #expect(result.renderer == "textkit" && result.layoutVersion == 1)
        #expect(result.pages.map(\.text) == texts)
        #expect(result.pages.allSatisfy { $0.size == Self.a4 })
    }

    /// `.docm` (macro-enabled) and `.dotx` (template) carry another main content type; both import like docx.
    @Test(arguments: ["Makro.docm", "Vorlage.dotx"])
    func macroAndTemplateVariantsLayOut(name: String) async throws {
        let url = try OfficeFixtures.docx(paragraphs: ["Variante Alpha", "Variante Beta"], pageBreakAfter: [0], name: name, in: dir)
        let types = try String(decoding: #require(ZipArchive(officePackage: url).data(at: "[Content_Types].xml")), as: UTF8.self)
        #expect(types.contains(name.hasSuffix("docm") ? "macroEnabled.main+xml" : "template.main+xml"))
        let result = try await TextKitWordSource().layout(of: url, kind: .word)
        #expect(result.pages.count == 2)
        #expect(result.pages[0].text.contains("Alpha") && result.pages[1].text.contains("Beta"))
        #expect(!result.pages[0].words.isEmpty)
        #expect(result.pages[0].size == Self.a4)
    }

    @Test func longTextFlowsOntoNextPage() throws {
        let paragraphs = (1...300).map { "Absatz \($0) mit etwas Text, damit die Zeile nicht ganz leer ist." }
        let url = try OfficeFixtures.docx(paragraphs: paragraphs, in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageCount > 1)
        let pages = (0..<document.pageCount).map { document.page($0) }
        #expect(pages.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && !$0.words.isEmpty })
        // Every paragraph exactly once, in order.
        let all = pages.map(\.text).joined(separator: " ")
        let tokens = all.split(separator: " ")
        let numbers = tokens.indices.compactMap { index -> Int? in
            guard tokens[index] == "Absatz", index + 1 < tokens.count else { return nil }
            return Int(tokens[index + 1])
        }
        #expect(numbers == Array(1...300))
    }

    @Test func wordBoxMatchesDrawnWord() throws {
        let url = try OfficeFixtures.docx(paragraphs: ["Müller wohnt in der Hauptstraße 5."], in: dir)
        let document = try TextKitWordDocument(url: url)
        let page = document.page(0)
        let range = (page.text as NSString).range(of: "Müller")
        #expect(range.location != NSNotFound)
        let word = try #require(page.words.first { $0.range == range })
        // Left edge on the left margin (1417 twips), with 10 % tolerance of the word width.
        let margin = 1417.0 / 20 / Self.a4.width
        #expect(abs(word.box.minX - margin) <= word.box.width * 0.1)
        #expect(word.box.minY > 0 && word.box.maxY < 0.2)
        // Right edge just before the next word: the gap is one space (well under 2 % of the page width).
        let next = try #require(page.words.first { $0.range == (page.text as NSString).range(of: "wohnt") })
        let gap = next.box.minX - word.box.maxX
        #expect(gap > 0 && gap < 0.02)
        #expect(abs(next.box.midY - word.box.midY) < 0.001)

        let width = 1190, height = Int((Double(width) * Self.a4.height / Self.a4.width).rounded())
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / Self.a4.width, y: CGFloat(height) / Self.a4.height)
        document.draw(page: 0, in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Bitmap memory is top-down: row 0 is the top of the page, like the box.
        func darkPixels(in box: CGRect) -> Int {
            let x0 = Int(box.minX * Double(width)), x1 = Int(box.maxX * Double(width))
            let y0 = Int(box.minY * Double(height)), y1 = Int(box.maxY * Double(height))
            var count = 0
            for y in max(0, y0)..<min(height, y1) {
                for x in max(0, x0)..<min(width, x1) where pixels[(y * width + x) * 4] < 128 { count += 1 }
            }
            return count
        }
        #expect(darkPixels(in: word.box) > 20)
        // Nothing left of the word (inside the margin) on its line, beyond 10 % of the word width.
        let left = CGRect(x: 0, y: word.box.minY, width: word.box.minX - word.box.width * 0.1, height: word.box.height)
        #expect(darkPixels(in: left) == 0)
        // Nor in the space between the two words.
        #expect(darkPixels(in: CGRect(x: word.box.maxX + 0.001, y: word.box.minY, width: max(0, gap - 0.002),
                                      height: word.box.height)) == 0)
    }

    @Test func docFormatReadable() throws {
        let docx = try OfficeFixtures.docx(paragraphs: ["Kündigungsfrist für Herrn Müller", "Zweiter Absatz"],
                                           pageBreakAfter: [0], in: dir)
        // Word import/export by AppKit: under the lock of all Word TextKit work, as in the app.
        let data = try TextKitWordDocument.textKit.withLock {
            let string = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                documentAttributes: nil)
            return try string.data(from: NSRange(location: 0, length: string.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
        }
        let doc = dir.appendingPathComponent("Alt.doc")
        try data.write(to: doc)
        let result = try TextKitWordDocument(url: doc)
        #expect(result.page(0).text.contains("Kündigungsfrist für Herrn Müller"))
        let all = (0..<result.pageCount).map { result.page($0).text }.joined(separator: " ")
        #expect(all.contains("Zweiter Absatz"))
    }

    @Test func imageOnlyDocxHasPagesButNoText() throws {
        let png = dir.appendingPathComponent("bild.png")
        try ImageFixtures.makeSolidImage(at: png, size: CGSize(width: 200, height: 100), format: .png)
        let url = try OfficeFixtures.docx(paragraphs: [], imagePNG: Data(contentsOf: png), in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageCount >= 1)
        for index in 0..<document.pageCount {
            #expect(document.page(index).text.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(document.page(index).words.isEmpty)
        }
    }

    @Test func emptyDocumentHasOnePage() throws {
        let url = try OfficeFixtures.docx(paragraphs: [], in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageCount == 1)
        #expect(document.page(0).words.isEmpty)
        #expect(document.thumbnail(0, maxPixel: 200) != nil)
    }

    @Test func textBeyondPageCapIsAppendedToLastPage() throws {
        let paragraphs = (1...300).map { "Absatz \($0) mit etwas Text, damit die Zeile nicht ganz leer ist." }
        let url = try OfficeFixtures.docx(paragraphs: paragraphs, in: dir)
        let document = try TextKitWordDocument(url: url, maxPages: 2)
        #expect(document.pageCount == 2)
        let last = document.page(1)
        #expect(last.text.contains("Absatz 300 mit etwas Text"))
        #expect(!document.page(0).text.contains("Absatz 300 "))
        // Word boxes only for what was laid out on the page.
        let text = last.text as NSString
        let overflow = text.range(of: "Absatz 300 ")
        #expect(!last.words.isEmpty)
        #expect(last.words.allSatisfy { NSMaxRange($0.range) < overflow.location })
        #expect(last.words.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.box) })
    }

    @Test func docxWithoutSectionPropertiesIsA4() throws {
        // The importer reports its Letter default here; the page size comes from the package or is A4.
        let url = try OfficeFixtures.docx(paragraphs: ["Ohne Abschnitt"], sectionProperties: false, in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageSize(0) == CGSize(width: 595.28, height: 841.89))
        let word = try #require(document.page(0).words.first)
        #expect(abs(word.box.minX - 70.87 / 595.28) < 0.001)
    }

    @Test func trailingPageBreakLeavesNoEmptyLastPage() throws {
        // The importer gives "Eins\n\u{0C}\n": the last paragraph mark alone on page 2 is left out.
        let url = try OfficeFixtures.docx(paragraphs: ["Eins"], pageBreakAfter: [0], in: dir)
        let document = try TextKitWordDocument(url: url)
        #expect(document.pageCount == 1)
        // Two page breaks in a row keep the empty page between them.
        let twice = try OfficeFixtures.docx(paragraphs: ["Eins", "", "Drei"], pageBreakAfter: [0, 1], name: "Zweimal.docx", in: dir)
        #expect(try TextKitWordDocument(url: twice).pageCount == 3)
    }

    @Test(arguments: ["garbage.docx", "verschluesselt.docx", "garbage.doc", "leer.docx"])
    func garbageIsUnreadable(name: String) async throws {
        let url = dir.appendingPathComponent(name)
        var bytes = name.hasPrefix("verschluesselt") ? [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] as [UInt8] : []
        if !name.hasPrefix("leer") {
            var rng = SystemRandomNumberGenerator()
            bytes += (0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        try Data(bytes).write(to: url)
        #expect(throws: LayoutSourceError.unreadable(url, reason: TextKitWordDocument.unreadableReason)) {
            try TextKitWordDocument(url: url)
        }
        await #expect(throws: LayoutSourceError.unreadable(url, reason: TextKitWordDocument.unreadableReason)) {
            try await TextKitWordSource().layout(of: url, kind: .word)
        }
    }

    @Test func missingFileIsNotUnreadable() async throws {
        let url = dir.appendingPathComponent("Fehlt.docx")
        #expect {
            try TextKitWordDocument(url: url)
        } throws: { !($0 is LayoutSourceError) }
        await #expect {
            try await TextKitWordSource().layout(of: url, kind: .word)
        } throws: { !($0 is LayoutSourceError) }
    }

    @Test func powerPointIsNotHandled() async throws {
        let url = try OfficeFixtures.pptx(slides: ["Folie"], in: dir)
        await #expect(throws: LayoutSourceError.self) {
            try await TextKitWordSource().layout(of: url, kind: .powerpoint)
        }
        #expect(TextKitWordSource().renderer(for: .word) == ("textkit", 1))
    }

    /// Via an own LRU, so other tests filling the shared cache can't disturb it.
    @Test func cacheReturnsSameInstance() throws {
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 4)
        // An own, finished gate: the shared one may finish during the test (another test starts it), which changes
        // the cache key (font state) and would give a new instance.
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        gate.wait()
        let url = try OfficeFixtures.docx(paragraphs: ["Erste Fassung"], name: "Cache.docx", in: dir)
        let first = try TextKitWordDocument.cached(url: url, in: cache, fontGate: gate)
        #expect(try TextKitWordDocument.cached(url: url, in: cache, fontGate: gate) === first)
        // Same path, other path spelling: same entry.
        let spelled = URL(fileURLWithPath: dir.appendingPathComponent("./Cache.docx").path)
        #expect(try TextKitWordDocument.cached(url: spelled, in: cache, fontGate: gate) === first)

        // A changed file is not served stale, and replaces the old entry.
        try OfficeFixtures.docx(paragraphs: ["Zweite Fassung, länger als die erste"], name: "Cache.docx", in: dir)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        let changed = try TextKitWordDocument.cached(url: url, in: cache, fontGate: gate)
        #expect(changed !== first)
        #expect(changed.page(0).text.contains("Zweite Fassung"))
        #expect(cache.keys.count == 1)

        // The shared cache (smoke test; other tests may use it too, so only a direct repeat).
        let shared = try TextKitWordDocument.cached(url: url)
        #expect(shared.page(0).text.contains("Zweite Fassung"))
    }

    @Test func lruEvictsLeastRecentlyUsed() {
        final class Box: Sendable { let id: Int; init(_ id: Int) { self.id = id } }
        let lru = DocumentLRU<Int, Box>(capacity: 4)
        var made: [Int] = []
        func value(_ key: Int) -> Box { lru.value(for: key) { made.append(key); return Box(key) } }
        let one = value(1)
        for key in 2...4 { _ = value(key) }
        #expect(value(1) === one)   // touch the oldest
        _ = value(5)                // evicts 2 (least recently used), not 1 (first inserted)
        #expect(lru.keys == [3, 4, 1, 5])
        #expect(value(1) === one)
        made.removeAll()
        _ = value(2)
        #expect(made == [2])        // 2 was made anew
        #expect(lru.keys == [4, 5, 1, 2])
    }

    /// Spec §8 „Obergrenze nach Speicher“: besides the count, the total weight (pages) is limited; the least
    /// recently used go first, but the newest document always stays, however heavy.
    @Test func lruLimitsTotalWeight() {
        final class Box: Sendable { let pages: Int; init(_ pages: Int) { self.pages = pages } }
        let lru = DocumentLRU<String, Box>(capacity: 4, maxWeight: 100) { $0.pages }
        _ = lru.value(for: "a") { Box(40) }
        _ = lru.value(for: "b") { Box(40) }
        #expect(lru.keys == ["a", "b"] && lru.totalWeight == 80)
        _ = lru.value(for: "a") { Box(40) } // touch a
        _ = lru.value(for: "c") { Box(30) } // 110 > 100: evicts b (least recently used)
        #expect(lru.keys == ["a", "c"] && lru.totalWeight == 70)
        _ = lru.value(for: "riesig") { Box(500) } // heavier than the limit alone: kept, everything else goes
        #expect(lru.keys == ["riesig"] && lru.totalWeight == 500)
        _ = lru.value(for: "d") { Box(1) }
        #expect(lru.keys == ["d"])
        #expect(TextKitWordDocument.cacheMaxPages == 2_000)
    }

    /// office-speed: simultaneous misses on one key make one value; the others wait for it (six tile workers imported
    /// one document six times, one after the other under `textKit`).
    @Test func lruSimultaneousMissesMakeOneValue() {
        final class Box: Sendable {}
        let lru = DocumentLRU<String, Box>(capacity: 4)
        let made = Mutex(0)
        let ids = Mutex<Set<ObjectIdentifier>>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let box = lru.value(for: "a") {
                made.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.05)
                return Box()
            }
            ids.withLock { _ = $0.insert(ObjectIdentifier(box)) }
        }
        #expect(made.withLock { $0 } == 1)
        #expect(ids.withLock { $0.count } == 1)
    }

    /// A failing `make` is shared by the waiters and not kept: the next request tries again.
    @Test func lruSharesAFailureWithoutKeepingIt() {
        final class Box: Sendable {}
        struct Boom: Error {}
        let lru = DocumentLRU<String, Box>(capacity: 4)
        let made = Mutex(0), failed = Mutex(0), arrived = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            arrived.withLock { $0 += 1 }
            do {
                _ = try lru.value(for: "a") { () throws -> Box in
                    made.withLock { $0 += 1 }
                    // Fail only once every caller is on its way (a caller after the failure would make again).
                    while arrived.withLock({ $0 }) < 6 { Thread.sleep(forTimeInterval: 0.001) }
                    Thread.sleep(forTimeInterval: 0.05)
                    throw Boom()
                }
            } catch { failed.withLock { $0 += 1 } }
        }
        #expect(made.withLock { $0 } == 1 && failed.withLock { $0 } == 6)
        #expect(lru.keys.isEmpty)
        #expect((try? lru.value(for: "a") { Box() }) != nil)
    }

    @Test func sharedWordCacheKeepsMoreDocuments() {
        #expect(TextKitWordDocument.cacheCapacity == 16)
    }

    @Test func lruReplacesMatchingEntries() {
        final class Box: Sendable {}
        let lru = DocumentLRU<String, Box>(capacity: 4)
        _ = lru.value(for: "a.docx|1") { Box() }
        _ = lru.value(for: "b.docx|1") { Box() }
        _ = lru.value(for: "a.docx|2", replacing: { $0.hasPrefix("a.docx|") }) { Box() }
        #expect(lru.keys == ["b.docx|1", "a.docx|2"])
    }

    @Test func thumbnailHasPageAspectAndWhiteBackground() throws {
        let url = try OfficeFixtures.docx(paragraphs: ["Vorschau"], in: dir)
        let document = try TextKitWordDocument(url: url)
        let image = try #require(document.thumbnail(0, maxPixel: 400))
        #expect(image.height == 400)
        #expect(abs(image.width - Int((400 * Self.a4.width / Self.a4.height).rounded())) <= 1)
        // Corner pixels (in the margin) are white.
        var pixel = [UInt8](repeating: 0, count: 4)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: image.width - 1, y: image.height - 1)] {
            let ctx = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: -corner.x, y: -corner.y, width: CGFloat(image.width), height: CGFloat(image.height)))
            #expect(pixel[0] > 250 && pixel[1] > 250 && pixel[2] > 250)
        }
    }

    /// Threading finding (decisions.md): the importer runs off the main thread; 64 tasks at once (the layouts themselves
    /// run one at a time under `textKit` since 1.3.2).
    @Test func concurrentImportsOffMainAreStable() async throws {
        let docx = try OfficeFixtures.docx(paragraphs: ["Parallel Müller", "Zwei"], pageBreakAfter: [0], in: dir)
        let doc = dir.appendingPathComponent("Parallel.doc")
        try TextKitWordDocument.textKit.withLock {      // as in the app: Word import/export under the Word TextKit lock
            let string = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                documentAttributes: nil)
            try string.data(from: NSRange(location: 0, length: string.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]).write(to: doc)
        }
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    #expect(pthread_main_np() == 0) // off the main thread
                    let document = try TextKitWordDocument(url: index.isMultiple(of: 2) ? docx : doc)
                    return document.pageCount
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts.count == 64 && counts.allSatisfy { $0 == 2 })
    }

    // MARK: Page setup from the package

    @Test func pageSetupFromLastSection() {
        let xml = Data("""
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
            <w:p><w:pPr><w:sectPr><w:pgSz w:w="16838" w:h="11906"/><w:pgMar w:top="500" w:left="500" w:bottom="500" w:right="500"/>\
            </w:sectPr></w:pPr></w:p>\
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1800" w:bottom="-1440" w:left="1800" \
            w:gutter="200"/></w:sectPr></w:body></w:document>
            """.utf8)
        let setup = WordPageSetup(documentXML: xml)
        #expect(setup?.size == CGSize(width: 612, height: 792))
        #expect(setup.map { NSEdgeInsetsEqual($0.margins, NSEdgeInsets(top: 72, left: 100, bottom: 72, right: 90)) } == true)
    }

    @Test func pageSetupWithoutPageSizeIsNil() {
        let xml = Data(#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>"#.utf8)
        #expect(WordPageSetup(documentXML: xml) == nil)
    }

    /// 1.3.2: Word TextKit work runs one at a time in the process – layout (`init`), page text and drawing
    /// (`thumbnail`) each wait for `textKit`, and each runs once it is free.
    @Test(.timeLimit(.minutes(1))) func textKitWorkWaitsForTheProcessWideLock() throws {
        let url = try OfficeFixtures.docx(paragraphs: ["Eine Seite"], in: dir)
        let document = try TextKitWordDocument(url: url)
        let steps: [(String, @Sendable () -> Void)] = [
            ("init", { _ = try? TextKitWordDocument(url: url) }),
            ("page", { _ = document.page(0) }),
            ("thumbnail", { _ = document.thumbnail(0, maxPixel: 32) }),
        ]
        for (name, step) in steps {
            let finished = DispatchSemaphore(value: 0)
            TextKitWordDocument.textKit.lock()
            Thread { step(); finished.signal() }.start()
            let early = finished.wait(timeout: .now() + .milliseconds(100))
            TextKitWordDocument.textKit.unlock()
            #expect(early == .timedOut, "\(name) ran while textKit was held")
            #expect(finished.wait(timeout: .now() + 20) == .success, "\(name) did not run after textKit was free")
        }
    }

    /// office-speed: tiles and the preview go before a running layout at `textKit`: the layout paginates in chunks
    /// and steps aside while a display path waits (30 tiles took 1 s behind two layouts instead of 76 ms).
    @Test(.timeLimit(.minutes(1))) func displayGoesBeforeARunningLayout() throws {
        let tile = try TextKitWordDocument(url: try OfficeFixtures.docx(paragraphs: ["Kachel"], name: "Kachel.docx", in: dir))
        let paragraphs = (0..<400).map { "Abschnitt \($0): " + String(repeating: "Text zum Umbrechen ", count: 20) }
        let big = try OfficeFixtures.docx(paragraphs: paragraphs, pageBreakAfter: Set(0..<400), name: "Gross.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        gate.wait()
        let layoutDone = Mutex(false)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = try? TextKitWordDocument(url: big, maxPages: TextKitWordDocument.maxPages, fontGate: gate, fonts: .start)
            layoutDone.withLock { $0 = true }
            finished.signal()
        }.start()
        // Until the layout holds the lock.
        while TextKitWordDocument.textKit.try() {
            TextKitWordDocument.textKit.unlock()
            Thread.sleep(forTimeInterval: 0.001)
        }
        for _ in 0..<30 { _ = tile.thumbnail(0, maxPixel: 200) }
        #expect(!layoutDone.withLock { $0 }, "the tiles waited for the whole layout")
        #expect(finished.wait(timeout: .now() + 50) == .success)
    }

    @Test func pageSetupFallsBackToA4() {
        #expect(WordPageSetup.a4.size == CGSize(width: 595.28, height: 841.89))
        #expect(NSEdgeInsetsEqual(WordPageSetup.a4.margins, NSEdgeInsets(top: 70.87, left: 70.87, bottom: 70.87, right: 70.87)))
    }
}
