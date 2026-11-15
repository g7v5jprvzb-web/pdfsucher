import AppKit
import Foundation
import OutputKit
import PDFKit
import SearchKit
import Synchronization
import Testing
import TestSupport
@testable import ViewerUI

/// Vorschau-Puffer (1.3.4): sharp detection, preview renders, geometry, neighbours, buffer, stage.
@Suite("PreviewBuffer")
@MainActor
struct PreviewBufferTests {
    static func textPDF(_ pages: [String] = ["Vertragsende 2024 und weitere Worte", "Zweite Seite"]) throws -> URL {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("doc.pdf")
        try PDFFixtures.makePDF(at: url, pages: pages)
        return url
    }

    // MARK: Task 1 — sharp detection

    @Test func trackedPageReportsDrawScale() async throws {
        let url = try Self.textPDF()
        guard case .ready(let document) = await DetailDocument.load(PageRef(url: url, pageIndex: 0)) else {
            Issue.record("not loaded"); return
        }
        let tracker = try #require(document.tracker)
        let seen = Mutex<[(ObjectIdentifier, CGFloat)]>([])
        tracker.onDraw = { page, scale in seen.withLock { $0.append((page, scale)) } }
        let page = try #require(document.pdf.page(at: 0))
        let ctx = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 2, y: 2)
        page.draw(with: .cropBox, to: ctx)
        let events = seen.withLock { $0 }
        #expect(events.count == 1)
        #expect(events.first?.0 == ObjectIdentifier(page))
        #expect(abs((events.first?.1 ?? 0) - 2) < 0.01)
    }

    @Test func sharpNeedsNinetyPercentOfTheDeviceScale() {
        #expect(PDFPageView.isSharp(drawScale: 2.4, viewScale: 1.2, backing: 2))
        #expect(PDFPageView.isSharp(drawScale: 2.17, viewScale: 1.2, backing: 2))
        #expect(!PDFPageView.isSharp(drawScale: 0.6, viewScale: 1.2, backing: 2))   // the coarse first picture
        #expect(PDFPageView.isSharp(drawScale: 1, viewScale: 1, backing: 1))
    }

    // MARK: Task 2 — render priority and preview renders

    @Test func queueRunsPreviewBeforePrefetchAfterVisible() async throws {
        let queue = TileRenderQueue(workers: 1)
        let gate = TileRenderQueueTests.Gate()
        let order = Mutex<[String]>([])
        queue.prefetch(key: "gate") { gate.wait(); return nil }
        try await gate.started()
        queue.prefetch(key: "p") { order.withLock { $0.append("p") }; return nil }
        let preview = Task { await queue.image(key: "r", priority: .preview) { order.withLock { $0.append("r") }; return NSImage() } }
        while queue.pendingCount < 2 { try await Task.sleep(for: .milliseconds(1)) }
        let visible = Task { await queue.image(key: "v", priority: .visible) { order.withLock { $0.append("v") }; return NSImage() } }
        while queue.pendingCount < 3 { try await Task.sleep(for: .milliseconds(1)) }
        gate.release()
        _ = await (preview.value, visible.value)
        while order.withLock({ $0.count }) < 3 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(order.withLock { $0 } == ["v", "r", "p"])
    }

    @Test func previewImageIsNotCached() async throws {
        let url = try Self.textPDF()
        let cache = ThumbnailCache()
        let render = await cache.previewImage(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 600, height: 848),
                                              priority: .preview)
        let image = try #require(render?.image)
        #expect(image.width == 1200)
        #expect(cache.cachedImageCount == 0)
        #expect((render?.millis ?? -1) >= 0)
    }

    @Test func previewImageRespectsMaxPixel() async throws {
        let url = try Self.textPDF()
        let render = await ThumbnailCache().previewImage(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 2000, height: 2000),
                                                         priority: .preview)
        let image = try #require(render?.image)
        #expect(max(image.width, image.height) == Int(ThumbnailCache.previewMaxPixelSide))
    }

    @Test func previewImageDrawsMarks() async throws {
        let url = try Self.textPDF()
        let ranges: HighlightRanges = { text in text.range(of: "Vertragsende").map { [$0] } ?? [] }
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        let size = CGSize(width: 300, height: 424)
        let plain = try #require(await cache.previewImage(for: ref, size: size, priority: .preview)?.image)
        let marked = try #require(await cache.previewImage(for: ref, size: size, highlightKey: "v", highlightRanges: ranges,
                                                           priority: .preview)?.image)
        #expect(plain.dataProvider?.data as Data? != marked.dataProvider?.data as Data?)
    }

    @Test func officePreviewIsNil() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("slides.pptx")
        try Data("x".utf8).write(to: url)
        let cache = ThumbnailCache(foreign: OfficePreviewTests.FakeProvider())
        #expect(await cache.previewImage(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 300, height: 424),
                                         priority: .preview) == nil)
    }

    @Test func bestCachedImageFindsAnySize() async throws {
        let url = try Self.textPDF()
        let cache = ThumbnailCache()
        let ref = PageRef(url: url, pageIndex: 0)
        #expect(cache.bestCachedImage(for: ref, highlightKey: "", highlighted: false) == nil)
        _ = await cache.thumbnail(for: ref, size: CGSize(width: 100, height: 141))
        _ = await cache.thumbnail(for: ref, size: CGSize(width: 200, height: 283))
        #expect(cache.bestCachedImage(for: ref, highlightKey: "", highlighted: false)?.size.width == 200)
        #expect(cache.bestCachedImage(for: ref, highlightKey: "q", highlighted: true) == nil)
        #expect(cache.bestCachedImage(for: PageRef(url: url, pageIndex: 1), highlightKey: "", highlighted: false) == nil)
    }

    @Test func storedImageComesFromDiskWithTheLastTileSize() async throws {
        let url = try Self.textPDF()
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        let ref = PageRef(url: url, pageIndex: 0)
        _ = await ThumbnailCache(disk: disk).thumbnail(for: ref, size: CGSize(width: 150, height: 212))
        disk.flush()
        let fresh = ThumbnailCache(disk: disk)
        #expect(await fresh.storedImage(for: ref) == nil)          // no tile size known yet
        _ = await fresh.thumbnail(for: PageRef(url: url, pageIndex: 1), size: CGSize(width: 150, height: 212))
        let stored = await fresh.storedImage(for: ref)
        #expect(stored?.size.width == 150)
    }

    // MARK: Task 3 — geometry

    @Test func scaleMatchesPDFView() async throws {
        let url = try Self.textPDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.document = document
        let pageSize = PreviewGeometry.pageSize(page)
        let viewSize = view.bounds.size
        let cases: [(PreviewZoom.Mode, CGFloat?)] = [(.fitPage, nil), (.percent(150), nil), (.pageWidth(level: 1), nil),
                                                     (.pageWidth(level: 2), 650), (.fitPage, 650)]
        for (mode, reference) in cases {
            PDFPageView.apply(mode, fractions: [100, 80], reference: reference, beyondWidth: true, to: view, page: page)
            let shown = view.autoScales ? view.scaleFactorForSizeToFit : view.scaleFactor
            let mine = PreviewGeometry.scale(mode: mode, fractions: [100, 80], reference: reference, beyondWidth: true,
                                             page: pageSize, view: viewSize)
            #expect(abs(shown - mine) / shown < 0.02, "\(mode) \(String(describing: reference)): \(shown) vs \(mine)")
        }
        // Without zoom beyond the width the page width is the limit.
        let limited = PreviewGeometry.scale(mode: .percent(800), fractions: [100], reference: nil, beyondWidth: false,
                                            page: pageSize, view: viewSize)
        #expect(limited <= 700 / pageSize.width + 0.001)
    }

    @Test func rotatedPageSize() throws {
        let url = try Self.textPDF()
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let upright = PreviewGeometry.pageSize(page)
        page.rotation = 90
        #expect(PreviewGeometry.pageSize(page) == CGSize(width: upright.height, height: upright.width))
    }

    @Test func frameCentredWhenItFitsTopAlignedWhenTallerLeftWhenWider() {
        let view = CGSize(width: 700, height: 900)
        #expect(PreviewGeometry.frame(page: CGSize(width: 600, height: 800), scale: 1, in: view)
                == CGRect(x: 50, y: 50, width: 600, height: 800))
        #expect(PreviewGeometry.frame(page: CGSize(width: 600, height: 800), scale: 1.5, in: view)
                == CGRect(x: 0, y: 0, width: 900, height: 1200))
        #expect(PreviewGeometry.frame(page: CGSize(width: 400, height: 800), scale: 1.5, in: view)
                == CGRect(x: 50, y: 0, width: 600, height: 1200))
    }

    @Test func heavyScanPage() throws {
        let dir = try PDFFixtures.tempDirectory()
        let scan = dir.appendingPathComponent("scan.pdf")
        try OCRFixtures.makeScanPDF(at: scan, images: [try OCRFixtures.textImage(["Scan"], size: CGSize(width: 4000, height: 3500)).image])
        let light = dir.appendingPathComponent("light.pdf")
        try OCRFixtures.makeScanPDF(at: light, images: [try OCRFixtures.textImage(["Scan"], size: CGSize(width: 1000, height: 700)).image])
        #expect(PreviewGeometry.isHeavy(try #require(PDFDocument(url: scan)?.page(at: 0)?.pageRef)))
        #expect(!PreviewGeometry.isHeavy(try #require(PDFDocument(url: light)?.page(at: 0)?.pageRef)))
        // A JPEG scan of 2474 × 3503 px blocked the main thread 256 ms in PDFKit (measured 1.3.4).
        let jpegScan = dir.appendingPathComponent("jpeg.pdf")
        try OCRFixtures.makeScanPDF(at: jpegScan, images: [try OCRFixtures.textImage(["Scan"], size: CGSize(width: 2474, height: 3503)).image])
        #expect(PreviewGeometry.isHeavy(try #require(PDFDocument(url: jpegScan)?.page(at: 0)?.pageRef)))
        #expect(!PreviewGeometry.isHeavy(try #require(PDFDocument(url: try Self.textPDF())?.page(at: 0)?.pageRef)))
    }

    // MARK: Task 4 — neighbours

    static func doc(_ name: String, pages: [Int]) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/docs/\(name)"), relativePath: name, modifiedAt: .distantPast,
                    pageHits: pages.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: pages.count, relevance: 0,
                    sourceRoot: URL(fileURLWithPath: "/docs"), pageCount: 0)
    }
    static func ref(_ hit: DocumentHit, _ page: Int) -> PageRef { PageRef(url: hit.url, pageIndex: page) }

    @Test func afterDownArrowPrefetchesDownThenUp() {
        let a = Self.doc("a", pages: [1, 4]), b = Self.doc("b", pages: [2, 5]), c = Self.doc("c", pages: [3, 6])
        let hits = [a, b, c]
        #expect(PreviewNeighbors.pages(from: Self.ref(a, 4), to: Self.ref(b, 5), hits: hits, showAllPages: false)
                == [Self.ref(c, 6), Self.ref(a, 4)])
    }

    @Test func afterStepBackPrefetchesBackThenForward() {
        let a = Self.doc("a", pages: [1, 4]), b = Self.doc("b", pages: [2, 5])
        let hits = [a, b]
        #expect(PreviewNeighbors.pages(from: Self.ref(b, 2), to: Self.ref(a, 4), hits: hits, showAllPages: false)
                == [Self.ref(a, 1), Self.ref(b, 2)])
    }

    @Test func clickPrefetchesNextThenPrevious() {
        let a = Self.doc("a", pages: [1, 4]), b = Self.doc("b", pages: [2, 5])
        let hits = [a, b]
        #expect(PreviewNeighbors.pages(from: nil, to: Self.ref(a, 4), hits: hits, showAllPages: false)
                == [Self.ref(b, 2), Self.ref(a, 1)])
        #expect(PreviewNeighbors.pages(from: Self.ref(b, 5), to: Self.ref(a, 1), hits: hits, showAllPages: false)
                == [Self.ref(a, 4)])                   // a click far away; nothing before the first page
    }

    @Test func endsGiveFewer() {
        let a = Self.doc("a", pages: [1])
        #expect(PreviewNeighbors.pages(from: nil, to: Self.ref(a, 1), hits: [a], showAllPages: false).isEmpty)
    }

    // MARK: Task 5 — buffer

    static let layout = PreviewBuffer.Layout(mode: .fitPage, fractions: [100], reference: nil, beyondWidth: true,
                                             viewSize: CGSize(width: 400, height: 500))
    static let noOCR: @MainActor (PageRef) async -> OCRPageText? = { _ in nil }

    /// Three files of one hit page each, in this order.
    static func threeFiles() throws -> (hits: [DocumentHit], refs: [PageRef]) {
        let dir = try PDFFixtures.tempDirectory()
        var hits: [DocumentHit] = []
        for name in ["a", "b", "c", "d", "e"] {
            let url = dir.appendingPathComponent("\(name).pdf")
            try PDFFixtures.makePDF(at: url, pages: ["Seite \(name) Vertragsende"])
            hits.append(DocumentHit(url: url, relativePath: name, modifiedAt: .distantPast,
                                    pageHits: [PageHit(pageIndex: 0, matchCount: 1)], totalMatches: 1, relevance: 0,
                                    sourceRoot: dir, pageCount: 1))
        }
        return (hits, hits.map { PageRef(url: $0.url, pageIndex: 0) })
    }

    @Test func preparesNeighbourImages() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(refs[1], from: refs[0], hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.count == 3)
        let image = try #require(buffer.image(for: refs[2], marks: marks, layout: Self.layout))
        let page = try #require(buffer.pageSize(for: refs[2]))
        let fit = min(400 / page.width, 500 / page.height)             // fit page into 400 × 500 pt, 2×
        #expect(image.width == Int((page.width * fit * 2).rounded()))
        #expect(buffer.image(for: refs[0], marks: marks, layout: Self.layout) != nil)
        #expect(buffer.image(for: refs[1], marks: marks, layout: Self.layout) != nil)
        #expect(buffer.document(for: refs[2])?.url == refs[2].url)
        #expect(buffer.pageSize(for: refs[2]) != nil)
        // Another view size: the picture would be the wrong size.
        let wider = PreviewBuffer.Layout(mode: .fitPage, fractions: [100], reference: nil, beyondWidth: true,
                                         viewSize: CGSize(width: 600, height: 800))
        #expect(buffer.image(for: refs[2], marks: marks, layout: wider) == nil)
    }

    @Test func bufferKeepsAtMostThree() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        var old: PageRef?
        for ref in refs {
            buffer.focus(ref, from: old, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
            #expect(buffer.count <= 3)
            old = ref
        }
        await buffer.waitUntilIdle()
        #expect(Set(buffer.refs) == [refs[4], refs[3]])
    }

    @Test func staleNeighboursCancelled() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(refs[1], from: refs[0], hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        buffer.focus(refs[4], from: nil, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(Set(buffer.refs) == [refs[4], refs[3]])
        #expect(buffer.image(for: refs[2], marks: marks, layout: Self.layout) == nil)
    }

    @Test func changedFileDropsEntry() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(refs[0], from: nil, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.image(for: refs[1], marks: marks, layout: Self.layout) != nil)
        try PDFFixtures.makePDF(at: refs[1].url, pages: ["Neu geschrieben"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: refs[1].url.path)
        guard case .ready(let fresh) = await DetailDocument.load(refs[1], reusing: buffer.document(for: refs[1])) else {
            Issue.record("not loaded"); return
        }
        buffer.documentLoaded(fresh, for: refs[1])
        #expect(buffer.image(for: refs[1], marks: marks, layout: Self.layout) == nil)
    }

    @Test func highlightChangeMissesEntry() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "a", ranges: { _ in [] }, color: .yellow)
        buffer.focus(refs[0], from: nil, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.image(for: refs[1], marks: marks, layout: Self.layout) != nil)
        #expect(buffer.image(for: refs[1], marks: .init(highlightKey: "b", ranges: { _ in [] }, color: .yellow), layout: Self.layout) == nil)
        #expect(buffer.image(for: refs[1], marks: .init(highlightKey: "a", ranges: nil, color: .yellow), layout: Self.layout) == nil)
    }

    @Test func officeGetsNoImage() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let url = dir.appendingPathComponent("slides.pptx")
        try Data("x".utf8).write(to: url)
        let hit = DocumentHit(url: url, relativePath: "slides.pptx", modifiedAt: .distantPast,
                              pageHits: [PageHit(pageIndex: 0, matchCount: 1)], totalMatches: 1, relevance: 0, sourceRoot: dir, pageCount: 1)
        let provider = OfficePreviewTests.FakeProvider()
        let buffer = PreviewBuffer(cache: ThumbnailCache(foreign: provider), foreign: provider)
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        let ref = PageRef(url: url, pageIndex: 0)
        buffer.focus(ref, from: nil, hits: [hit], showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.image(for: ref, marks: marks, layout: Self.layout) == nil)
        #expect(provider.state.withLock { $0.onMain.isEmpty })     // no page drawn for it
    }

    // MARK: Task 6 — stage, stand-in, placeholder

    /// Waits until `condition` holds (at most 3 s: the main actor is busy when the whole suite runs).
    static func eventually(_ condition: () -> Bool) async throws -> Bool {
        let end = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    static func stage() -> PreviewStage {
        PreviewStage(rest: .milliseconds(150), quiet: .milliseconds(30), untracked: .milliseconds(100), timeout: .seconds(2))
    }

    static func loaded(_ url: URL, page: Int = 0) async throws -> DetailDocument {
        guard case .ready(let document) = await DetailDocument.load(PageRef(url: url, pageIndex: page)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    @Test func handoverImmediateForLightPage() async throws {
        let url = try Self.textPDF()
        let ref = PageRef(url: url, pageIndex: 0)
        let document = try await Self.loaded(url)
        let stage = Self.stage()
        stage.loaded(document, ref: ref, ocr: nil, heavy: false)
        #expect(stage.shown?.ref == ref)
        #expect(stage.needsStandIn(for: ref))
        stage.drewSharp(pageIndex: 0, document: document.pdf)
        #expect(stage.needsStandIn(for: ref))                       // waits for the other tiles
        #expect(try await Self.eventually { !stage.needsStandIn(for: ref) })
    }

    @Test func coarseOrOtherPageDrawIsNotSharp() async throws {
        let url = try Self.textPDF()
        let ref = PageRef(url: url, pageIndex: 0)
        let document = try await Self.loaded(url)
        let other = try await Self.loaded(try Self.textPDF())
        let stage = Self.stage()
        stage.loaded(document, ref: ref, ocr: nil, heavy: false)
        stage.drewSharp(pageIndex: 1, document: document.pdf)
        stage.drewSharp(pageIndex: 0, document: other.pdf)
        try await Task.sleep(for: .milliseconds(80))
        #expect(stage.needsStandIn(for: ref))
    }

    @Test func handoverWaitsForRestOnHeavyPage() async throws {
        let url = try Self.textPDF()
        let a = PageRef(url: url, pageIndex: 0), b = PageRef(url: url, pageIndex: 1)
        let document = try await Self.loaded(url)
        let stage = Self.stage()
        stage.loaded(document, ref: a, ocr: nil, heavy: true)
        #expect(stage.shown == nil)
        try await Task.sleep(for: .milliseconds(60))
        stage.loaded(document, ref: b, ocr: nil, heavy: true)        // the next key press before the rest is over
        try await Task.sleep(for: .milliseconds(110))
        #expect(stage.shown == nil)                                  // a never handed over, b not yet
        #expect(try await Self.eventually { stage.shown?.ref == b })
    }

    @Test func returnToShownPageIsSharp() async throws {
        let url = try Self.textPDF()
        let a = PageRef(url: url, pageIndex: 0), b = PageRef(url: url, pageIndex: 1)
        let document = try await Self.loaded(url)
        let stage = Self.stage()
        stage.loaded(document, ref: a, ocr: nil, heavy: false)
        stage.drewSharp(pageIndex: 0, document: document.pdf)
        #expect(try await Self.eventually { !stage.needsStandIn(for: a) })
        stage.loaded(document, ref: b, ocr: nil, heavy: true)        // b waits for the rest …
        #expect(stage.needsStandIn(for: b))
        #expect(!stage.needsStandIn(for: a))                          // … and a is still shown, sharp
        stage.loaded(document, ref: a, ocr: nil, heavy: false)        // back to a
        #expect(!stage.needsStandIn(for: a))
        try await Task.sleep(for: .milliseconds(200))
        #expect(stage.shown?.ref == a)                                // b's pending handover was cancelled
    }

    @Test func sharpFallbacks() async throws {
        let url = try Self.textPDF()
        let ref = PageRef(url: url, pageIndex: 0)
        let tracked = try await Self.loaded(url)
        let untracked = DetailDocument(url: url, modifiedAt: nil, pdf: try #require(PDFDocument(url: url)))
        let stage = PreviewStage(rest: .milliseconds(150), quiet: .milliseconds(30), untracked: .milliseconds(40), timeout: .milliseconds(120))
        stage.loaded(untracked, ref: ref, ocr: nil, heavy: false)
        #expect(stage.needsStandIn(for: ref))
        #expect(try await Self.eventually { !stage.needsStandIn(for: ref) })   // no tracker: after `untracked`
        let other = PageRef(url: url, pageIndex: 1)
        stage.loaded(tracked, ref: other, ocr: nil, heavy: false)
        #expect(stage.needsStandIn(for: other))
        #expect(try await Self.eventually { !stage.needsStandIn(for: other) })  // never drawn sharply: after `timeout`
        stage.cleared()
        #expect(stage.shown == nil)
    }

    @Test func standInLevelOrder() throws {
        let image = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let tile = NSImage(size: CGSize(width: 1, height: 1))
        guard case .prepared = PreviewStandIn.Level(prepared: image, tile: tile) else { Issue.record("prepared"); return }
        guard case .tile = PreviewStandIn.Level(prepared: nil, tile: tile) else { Issue.record("tile"); return }
        guard case .blank = PreviewStandIn.Level(prepared: nil, tile: nil) else { Issue.record("blank"); return }
    }

    @Test func placeholderKeepsReadyDocumentNeverASpinner() async throws {
        let url = try Self.textPDF()
        let document = try await Self.loaded(url)
        let other = PageRef(url: try Self.textPDF(), pageIndex: 0)
        #expect(PageDetailView.placeholder(load: .ready(document), loadedURL: url, for: other) == .ready(document))
        #expect(PageDetailView.placeholder(load: .missing, loadedURL: url, for: other) == nil)
        #expect(PageDetailView.placeholder(load: .preparing, loadedURL: other.url, for: other) == .preparing)
        #expect(PageDetailView.placeholder(load: .preparing, loadedURL: url, for: other) == nil)
    }

    @Test func newCacheDropsEntries() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(refs[0], from: nil, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.count == 2)
        buffer.use(ThumbnailCache(), foreign: nil)
        #expect(buffer.count == 0)
    }

    // MARK: Review fixes

    @Test func sameFilePagingKeepsPicture() async throws {
        let url = try Self.textPDF(["Seite eins Vertragsende", "Seite zwei Vertragsende"])
        let hit = DocumentHit(url: url, relativePath: "doc.pdf", modifiedAt: .distantPast,
                              pageHits: [PageHit(pageIndex: 0, matchCount: 1), PageHit(pageIndex: 1, matchCount: 1)],
                              totalMatches: 2, relevance: 0, sourceRoot: url.deletingLastPathComponent(), pageCount: 2)
        let first = PageRef(url: url, pageIndex: 0), second = PageRef(url: url, pageIndex: 1)
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(first, from: nil, hits: [hit], showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.document(for: first)?.pdf === buffer.document(for: second)?.pdf)   // one document per file
        // The preview pages on within the file it shows: its own document of the same, unchanged file.
        let shown = try await Self.loaded(url)
        buffer.documentLoaded(shown, for: second)
        #expect(buffer.image(for: second, marks: marks, layout: Self.layout) != nil)
    }

    @Test func pendingHandoverDroppedWhenFocusMovesOn() async throws {
        let url = try Self.textPDF()
        let a = PageRef(url: url, pageIndex: 0), b = PageRef(url: url, pageIndex: 1)
        let document = try await Self.loaded(url)
        let stage = Self.stage()
        stage.loaded(document, ref: a, ocr: nil, heavy: true)
        stage.focusMoved(to: b)                    // b's load takes longer than the rest
        try await Task.sleep(for: .milliseconds(300))
        #expect(stage.shown == nil)
        stage.loaded(document, ref: b, ocr: nil, heavy: false)
        stage.focusMoved(to: b)                    // no-op for the page shown
        #expect(stage.shown?.ref == b)
    }

    @Test func contentRectFindsThePageInsideTheTile() throws {
        // A 200 × 300 px tile with a landscape page (200 × 100 px) in its middle, the rest transparent.
        let ctx = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 100, width: 200, height: 100))
        let image = try #require(ctx.makeImage())
        #expect(PreviewGeometry.contentRect(of: image) == CGRect(x: 0, y: 100, width: 200, height: 100))
        // Drawn so that this part fills a 400 × 200 frame at (10, 20): the whole tile is 400 × 600, 200 higher.
        #expect(PreviewGeometry.tileFrame(content: CGRect(x: 0, y: 100, width: 200, height: 100), imageSize: CGSize(width: 200, height: 300),
                                          into: CGRect(x: 10, y: 20, width: 400, height: 200))
                == CGRect(x: 10, y: -180, width: 400, height: 600))
        let empty = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        #expect(PreviewGeometry.contentRect(of: empty) == nil)
    }

    @Test func landscapeTileGivesLandscapeShape() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("wide.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Quer"])
        let document = try #require(PDFDocument(url: url))
        document.page(at: 0)?.rotation = 90
        #expect(document.write(to: url))
        let tile = try #require(await ThumbnailCache().thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 200, height: 283)))
        let cg = try #require(tile.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let content = try #require(PreviewGeometry.contentRect(of: cg))
        #expect(content.width > content.height * 1.3)
    }

    @Test func imageNeighbourKeepsNoDocument() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let photo = dir.appendingPathComponent("photo.jpg")
        try ImageFixtures.makeSolidImage(at: photo, size: CGSize(width: 3000, height: 2000), format: .jpeg)
        let pdf = dir.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Vertragsende"])
        let hits = [pdf, photo].map {
            DocumentHit(url: $0, relativePath: $0.lastPathComponent, modifiedAt: .distantPast,
                        pageHits: [PageHit(pageIndex: 0, matchCount: 1)], totalMatches: 1, relevance: 0, sourceRoot: dir, pageCount: 1)
        }
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        let photoRef = PageRef(url: photo, pageIndex: 0)
        buffer.focus(PageRef(url: pdf, pageIndex: 0), from: nil, hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        await buffer.waitUntilIdle()
        #expect(buffer.document(for: photoRef) == nil)          // no 4,000 px decode kept for a neighbour
        #expect(buffer.pageSize(for: photoRef) == CGSize(width: 3000, height: 2000))
        #expect(buffer.image(for: photoRef, marks: marks, layout: Self.layout) != nil)
    }

    @Test func runningPreparationIsNotRestarted() async throws {
        let (hits, refs) = try Self.threeFiles()
        let buffer = PreviewBuffer(cache: ThumbnailCache())
        let marks = PreviewBuffer.Marks(highlightKey: "", ranges: nil, color: .yellow)
        buffer.focus(refs[1], from: refs[0], hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        let started = buffer.preparationsStarted
        buffer.focus(refs[2], from: refs[1], hits: hits, showAllPages: false, marks: marks, layout: Self.layout, ocr: Self.noOCR)
        #expect(buffer.preparationsStarted == started + 1)      // only refs[3] is new; refs[1], refs[2] keep running
        await buffer.waitUntilIdle()
        #expect(buffer.image(for: refs[3], marks: marks, layout: Self.layout) != nil)
    }
}
