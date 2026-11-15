import Testing
import AppKit
import Foundation
import IndexKit
import OutputKit
import PDFKit
import SearchKit
import TestSupport
@testable import ViewerUI

/// 1.3.4: tiles follow the page shape; landscape rows are lower, so more rows fit.
@Suite("Tile shape")
struct TileShapeTests {
    private static let base = CGSize(width: 100, height: 141.4)

    private func pdf(_ size: CGSize, rotation: Int = 0) throws -> URL {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("p.pdf")
        var box = CGRect(origin: .zero, size: size)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        if rotation != 0 {
            let doc = try #require(PDFDocument(url: url))
            doc.page(at: 0)!.rotation = rotation
            #expect(doc.write(to: url))
        }
        return url
    }

    private func hit(_ url: URL, kind: DocumentKind = .pdf) -> DocumentHit {
        DocumentHit(url: url, relativePath: url.lastPathComponent, modifiedAt: Date(), pageHits: [], totalMatches: 0,
                    relevance: 0, sourceRoot: url.deletingLastPathComponent(), pageCount: 1, kind: kind)
    }

    @Test func portraitKeepsTheA4Tile() {
        #expect(GridLayout.tileSize(base: Self.base, pageAspect: nil) == Self.base)
        #expect(GridLayout.tileSize(base: Self.base, pageAspect: 842.0 / 595.0) == Self.base)
        let letter = GridLayout.tileSize(base: Self.base, pageAspect: 11.0 / 8.5)
        #expect(letter.width == 100 && abs(letter.height - 129.41) < 0.01)
    }

    @Test func landscapeKeepsTheWidthAndIsLower() {
        let slide = GridLayout.tileSize(base: Self.base, pageAspect: 9.0 / 16.0)
        #expect(slide.width == 100)
        #expect(abs(slide.height - 56.25) < 0.01)
    }

    @Test func tallPagesKeepTheHeight() {
        let strip = GridLayout.tileSize(base: Self.base, pageAspect: 3)
        #expect(abs(strip.height - 141.4) < 0.01)
        #expect(abs(strip.width - 141.4 / 3) < 0.01)
    }

    @Test func nonsenseIsClampedOrIgnored() {
        #expect(GridLayout.tileSize(base: Self.base, pageAspect: 0) == Self.base)
        #expect(GridLayout.tileSize(base: Self.base, pageAspect: .nan) == Self.base)
        #expect(GridLayout.tileSize(base: .zero, pageAspect: 0.5) == .zero)
        let banner = GridLayout.tileSize(base: Self.base, pageAspect: 0.01)
        #expect(abs(banner.height - 20) < 0.01)
    }

    @Test func pageAspectOfPDFs() throws {
        let cache = ThumbnailCache()
        let portrait = try #require(cache.pageAspect(of: try pdf(CGSize(width: 595, height: 842))))
        #expect(abs(portrait - 842.0 / 595.0) < 0.001)
        let landscape = try #require(cache.pageAspect(of: try pdf(CGSize(width: 960, height: 540))))
        #expect(abs(landscape - 0.5625) < 0.001)
        let turned = try #require(cache.pageAspect(of: try pdf(CGSize(width: 595, height: 842), rotation: 90)))
        #expect(abs(turned - 595.0 / 842.0) < 0.001)
        #expect(cache.pageAspect(of: URL(fileURLWithPath: "/nonexistent/x.pdf")) == nil)
    }

    @Test func pageAspectOfImages() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("wide.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        let aspect = try #require(ThumbnailCache.imageAspect(url))
        #expect(abs(aspect - 0.5) < 0.001)
    }

    @MainActor @Test func shapesResolveOnceAndGuessSlides() async throws {
        let shapes = PageShapes()
        let cache = ThumbnailCache()
        let wide = hit(try pdf(CGSize(width: 800, height: 600)))
        #expect(!shapes.isResolved(wide.url, revision: 0))
        #expect(shapes.tileSize(for: wide, base: Self.base) == Self.base)
        await shapes.resolve(wide, revision: 0, cache: cache)
        #expect(shapes.isResolved(wide.url, revision: 0))
        #expect(shapes.tileSize(for: wide, base: Self.base) == CGSize(width: 100, height: 75))

        // A deck not laid out yet: guessed 16:9, asked again at a newer layout revision.
        let deck = hit(URL(fileURLWithPath: "/nonexistent/deck.pptx"), kind: .powerpoint)
        await shapes.resolve(deck, revision: 1, cache: cache)
        #expect(shapes.isResolved(deck.url, revision: 1))
        #expect(!shapes.isResolved(deck.url, revision: 2))
        #expect(shapes.tileSize(for: deck, base: Self.base) == CGSize(width: 100, height: 56.25))
    }

    @MainActor @Test func prefetchGroupsBySize() {
        let a = URL(fileURLWithPath: "/a.pdf"), b = URL(fileURLWithPath: "/b.pptx"), c = URL(fileURLWithPath: "/c.pdf")
        let refs = [PageRef(url: a, pageIndex: 0), PageRef(url: b, pageIndex: 0), PageRef(url: c, pageIndex: 1),
                    PageRef(url: a, pageIndex: 1)]
        let sizes: [URL: CGSize] = [a: Self.base, b: CGSize(width: 100, height: 56)]
        let groups = TilePrefetcher.grouped(refs, sizes: sizes)
        #expect(groups.count == 2)
        #expect(groups[0].0 == Self.base && groups[0].1 == [refs[0], refs[3]])
        #expect(groups[1].1 == [refs[1]])   // c has no size yet: left out
    }
}
