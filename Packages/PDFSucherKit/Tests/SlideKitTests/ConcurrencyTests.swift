// ConcurrencyTests.swift — Task 12c (SlideKit tests)
// Plan Review Focus 4: many tasks render the slides of one deck at once (unprimed caches) and get exactly what
// a sequential run on a separate deck instance gets. Run under TSan: scripts/test.sh --sanitize=thread.
import CoreGraphics
import Foundation
import IndexKit
import Testing
@testable import SlideKit

/// Everything a consumer reads from one slide.
private struct SlideResult: Equatable, Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let text: String
    let words: [OCRWord]
}

private func result(_ deck: SlideDeck, _ i: Int, maxPixel: Int) -> SlideResult? {
    guard let img = deck.thumbnail(i, maxPixel: maxPixel), let data = img.dataProvider?.data as Data? else { return nil }
    return SlideResult(pixels: data, width: img.width, height: img.height, text: deck.slideText(i), words: deck.wordBoxes(i))
}

/// 8 tasks, each renders every slide (task k starts at slide k, so different slides overlap in time) of one
/// fresh deck; compared with a sequential baseline from another instance of the same file.
private func checkConcurrent(url: URL, maxPixel: Int, tasks: Int = 8) async throws {
    let base = try SlideDeck(url: url)
    let baseline = (0..<base.slideCount).map { result(base, $0, maxPixel: maxPixel) }
    let shared = try SlideDeck(url: url)
    let n = shared.slideCount
    let runs = await withTaskGroup(of: (Int, [Int: SlideResult?]).self) { group in
        for k in 0..<tasks {
            group.addTask {
                var out: [Int: SlideResult?] = [:]
                for j in 0..<n {
                    let i = (j + k) % n
                    out[i] = result(shared, i, maxPixel: maxPixel)
                }
                return (k, out)
            }
        }
        var all: [(Int, [Int: SlideResult?])] = []
        for await r in group { all.append(r) }
        return all
    }
    #expect(runs.count == tasks)
    for (k, out) in runs {
        for i in 0..<n {
            let got = out[i] ?? nil
            #expect(got != nil, "\(url.lastPathComponent) task \(k) slide \(i): no thumbnail")
            #expect(got == baseline[i], "\(url.lastPathComponent) task \(k) slide \(i) differs from the sequential run")
        }
    }
}

@Suite struct ConcurrencyTests {
    /// Six slides: text boxes, a table, pictures, filled and shadowed shapes, a group.
    private func deck() throws -> OpenedDeck {
        let shadow = "<a:effectLst><a:outerShdw blurRad=\"38100\" dist=\"76200\" dir=\"2700000\"><a:srgbClr val=\"000000\">"
            + "<a:alpha val=\"50000\"/></a:srgbClr></a:outerShdw></a:effectLst>"
        var f = PptxFixture()
        f.media = ["ppt/media/image1.png": pngData(255, 0, 0), "ppt/media/image2.png": pngData(0, 128, 255)]
        let rels = PptxFixture.imageRel("rId5", "../media/image1.png") + PptxFixture.imageRel("rId6", "../media/image2.png")
        f.slides = (0..<6).map { k in .init(shapes: slideShapes(k, shadow: shadow), rels: rels) }
        return try f.open()
    }

    private func slideShapes(_ k: Int, shadow: String) -> String {
        let title = X.words(2, CGRect(x: 60, y: 40, width: 800, height: 60), ["Folie \(k + 1) Überschrift Größe"])
        let box = X.sp(3, CGRect(x: 60 + Double(k) * 20, y: 140, width: 200, height: 120),
                       fill: k % 2 == 0 ? "FF8800" : "3366CC", extra: shadow)
        let rows: [[String]] = [["Kopf \(k)", "Spalte", "Wert"], ["Zeile", "ä ö ü", "\(k * 17)"], ["Summe", "", "\(k * 42)"]]
        let table = X.table(4, CGRect(x: 320, y: 140, width: 560, height: 120), rows)
        let pic = X.pic(5, CGRect(x: 60, y: 300, width: 160, height: 120), rId: k % 2 == 0 ? "rId5" : "rId6")
        let inner = X.words(7, CGRect(x: 300, y: 320, width: 500, height: 100),
                            ["Gruppe \(k) mit etwas längerem Text, der umbricht und", "zweiter Absatz"])
        return title + box + table + pic + X.group(6, inner)
    }

    @Test func eightTasksRenderLikeASequentialRun() async throws {
        let o = try deck()
        #expect(o.deck.slideCount == 6)
        #expect(o.deck.slideText(5).contains("Folie 6 Überschrift"))
        #expect(o.deck.slideText(5).contains("Summe"))
        #expect(o.deck.pixels(5).hex(150, 400) == "0080FF")
        try await checkConcurrent(url: o.url, maxPixel: 480)
    }

    /// The same on Chris' decks (PDFSUCHER_PPTX_CORPUS); PDFSUCHER_PPTX_CORPUS_DECK=<file name> limits it to one.
    @Test(.enabled(if: DeckCorpusTests.corpus != nil), .timeLimit(.minutes(30)))
    func corpusDecksRenderLikeASequentialRun() async throws {
        let dir = URL(fileURLWithPath: try #require(DeckCorpusTests.corpus))
        let only = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS_DECK"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) && (only == nil || $0.lastPathComponent == only) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for url in files {
            let clock = ContinuousClock()
            let elapsed = try await clock.measure { try await checkConcurrent(url: url, maxPixel: 256) }
            print("[corpus-concurrency] \(url.lastPathComponent): \(elapsed)")
        }
    }
}
