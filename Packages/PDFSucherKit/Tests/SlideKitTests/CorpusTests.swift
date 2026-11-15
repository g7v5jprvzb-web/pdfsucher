// CorpusTests.swift — Task 14 (SlideKit tests)
// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx> (real decks, read in place, never copied into the
// repo). Renders every visible slide of every deck at 1600 px and writes side-by-side contact sheets
// (Quick Look left, SlideKit right) outside the repo for the visual review in docs/slidekit-vergleich.md.
// The benchmark (PDFSUCHER_BENCH=1, release build) measures opening, thumbnails, full renders and text.
// PowerPoint mode (slidekit-ref): `PowerPointReferenceTests` compares every slide with PowerPoint's own PDF export
// `<deck>.pdf` next to the deck (scores + PowerPoint | SlideKit | diff sheets under <out>/ppt/), and
// `TextLineMeasurements` (PDFSUCHER_PPT_TEXT="D1:7,D3" or "all") dumps PowerPoint's text baselines from the PDF
// content stream next to SlideKit's laid-out lines (<out>/ppt/text/, matched-lines.tsv). A release build is
// much faster: `scripts/test.sh -c release --filter SlideKitTests.PowerPointReferenceTests`.
//
// Deck labels (D1…D7) and the matching Quick Look folders come from local files outside the repo:
//   <out>/labels.txt                  "D1|<short>|<file name>" per line ('#' = comment)
//   <quick look root>/<short>-quicklook-slides/slide-NN.png   NN = visible slide number (hidden ones skipped)
// Defaults: out = ~/Developer/PDFSucher-spikes/slidekit-vergleich (PDFSUCHER_SLIDEKIT_COMPARE_OUT),
// quick look root = ~/Developer/PDFSucher-spikes/pptx-bordmittel (PDFSUCHER_QUICKLOOK_SLIDES).
// PDFSUCHER_FONT_SUBST=powerPoint|similar picks the decks' FontSubstitution (default powerPoint; an unknown value stops the run).
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import OOXMLKit
import PDFKit
import UniformTypeIdentifiers
@testable import SlideKit

private let env = ProcessInfo.processInfo.environment

private func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

/// One deck of the corpus with its neutral label.
struct CorpusDeck {
    let label: String
    let short: String?
    let url: URL

    /// Decks of the corpus folder, labelled from labels.txt (unlisted decks get D<n> after the listed ones).
    static func all() throws -> [CorpusDeck] {
        guard let dir = env["PDFSUCHER_PPTX_CORPUS"].map(expand) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var labels: [String: (String, String)] = [:]
        if let text = try? String(contentsOf: outDir.appendingPathComponent("labels.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "|", maxSplits: 2).map(String.init)
                if f.count == 3 { labels[f[2].precomposedStringWithCanonicalMapping] = (f[0], f[1]) }
            }
        }
        var next = labels.count + 1
        return files.map { url in
            if let (label, short) = labels[url.lastPathComponent.precomposedStringWithCanonicalMapping] {
                return CorpusDeck(label: label, short: short, url: url)
            }
            defer { next += 1 }
            return CorpusDeck(label: "D\(next)", short: nil, url: url)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// `PDFSUCHER_FONT_SUBST` ("powerPoint" / "similar"), else the default.
    static var fontSubstitution: FontSubstitution {
        guard let raw = env["PDFSUCHER_FONT_SUBST"] else { return .powerPoint }
        guard let value = FontSubstitution(rawValue: raw) else {
            preconditionFailure("PDFSUCHER_FONT_SUBST=\(raw): expected powerPoint or similar")
        }
        return value
    }

    /// The deck opened with `fontSubstitution`.
    func open() throws -> SlideDeck { try SlideDeck(url: url, fontSubstitution: Self.fontSubstitution) }

    static var outDir: URL {
        expand(env["PDFSUCHER_SLIDEKIT_COMPARE_OUT"] ?? "~/Developer/PDFSucher-spikes/slidekit-vergleich")
    }

    /// Quick Look image of visible slide `n` (1-based), if present.
    func quickLook(_ n: Int) -> CGImage? {
        guard let short else { return nil }
        let root = expand(env["PDFSUCHER_QUICKLOOK_SLIDES"] ?? "~/Developer/PDFSucher-spikes/pptx-bordmittel")
        let url = root.appendingPathComponent("\(short)-quicklook-slides/slide-\(String(format: "%02d", n)).png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

@Suite struct CorpusTests {
    static let enabled = env["PDFSUCHER_PPTX_CORPUS"] != nil
    static let pairsPerSheet = 6

    @Test(.enabled(if: enabled))
    func everyVisibleSlideRendersAndContactSheetsAreWritten() throws {
        let out = CorpusDeck.outDir
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        var total = 0
        for deck in try CorpusDeck.all() {
            let d = try deck.open()
            #expect(d.slideCount > 0, "\(deck.label): no visible slides")
            let slideDir = out.appendingPathComponent(deck.label)
            try? FileManager.default.removeItem(at: slideDir)
            try FileManager.default.createDirectory(at: slideDir, withIntermediateDirectories: true)
            var pairs: [(String, CGImage?, CGImage)] = []
            for i in 0..<d.slideCount {
                let t0 = Date()
                guard let img = d.thumbnail(i, maxPixel: 1600) else {
                    Issue.record("\(deck.label) slide \(i + 1): no image")
                    continue
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                total += 1
                let n = i + 1, ppt = d.slides[i].powerPointNumber
                log.append("\(deck.label) \(n) (PowerPoint \(ppt)): \(ms) ms, \(d.wordBoxes(i).count) words")
                write(img, to: slideDir.appendingPathComponent(String(format: "sk-%02d.png", n)))
                pairs.append(("\(deck.label)  #\(n)  (PowerPoint \(ppt))   Quick Look | SlideKit", deck.quickLook(n), img))
            }
            for (k, start) in stride(from: 0, to: pairs.count, by: Self.pairsPerSheet).enumerated() {
                let page = Array(pairs[start..<min(start + Self.pairsPerSheet, pairs.count)])
                if let sheet = Self.sheet(page) {
                    write(sheet, to: out.appendingPathComponent("\(deck.label)-\(String(format: "%02d", k + 1)).png"))
                }
            }
        }
        try log.joined(separator: "\n").write(to: out.appendingPathComponent("render-log.txt"), atomically: true, encoding: .utf8)
        #expect(total > 0)
    }

    /// Rows of (label, Quick Look, SlideKit), each image aspect-fit into a 780 px cell.
    static func sheet(_ rows: [(String, CGImage?, CGImage)]) -> CGImage? {
        let cellW: CGFloat = 780, gap: CGFloat = 12, labelH: CGFloat = 30
        let cellH = rows.map { CGFloat($0.2.height) / CGFloat($0.2.width) * cellW }.max() ?? cellW * 9 / 16
        let rowH = labelH + cellH + gap
        let w = Int(cellW * 2 + gap * 3), h = Int(rowH * CGFloat(rows.count) + gap)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.55, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
        for (r, row) in rows.enumerated() {
            let top = CGFloat(h) - gap - CGFloat(r) * rowH
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            if let str = CFAttributedStringCreate(nil, row.0 as CFString, attrs) {
                ctx.textPosition = CGPoint(x: gap, y: top - labelH + 8)
                CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
            }
            for (c, img) in [row.1, row.2].enumerated() {
                let cell = CGRect(x: gap + CGFloat(c) * (cellW + gap), y: top - labelH - cellH, width: cellW, height: cellH)
                ctx.setFillColor(gray: 0.85, alpha: 1)
                ctx.fill(cell)
                guard let img else { continue }
                let s = min(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: cell.midX - iw / 2, y: cell.maxY - ih, width: iw, height: ih))
            }
        }
        return ctx.makeImage()
    }
}

private func write(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// PDFSUCHER_BENCH=1 plus PDFSUCHER_PPTX_CORPUS; meant for a release build:
/// `PDFSUCHER_BENCH=1 PDFSUCHER_PPTX_CORPUS=… scripts/test.sh -c release --no-parallel --filter SlideKitBenchmark`
@Suite struct SlideKitBenchmark {
    static let enabled = env["PDFSUCHER_BENCH"] == "1" && env["PDFSUCHER_PPTX_CORPUS"] != nil

    private static func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    private static func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        guard !s.isEmpty else { return "– / –" }
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return String(format: "%.1f / %.1f", median, s[s.count - 1])
    }

    @Test(.enabled(if: enabled))
    func measure() throws {
        var lines = ["| Deck | Slides | Open (ms, 1st / median of 5) | Thumb 256 cold | Thumb 256 warm | Render 1600 cold | "
                     + "Render 1600 warm | slideText + wordBoxes |",
                     "|---|---|---|---|---|---|---|---|"]
        var notes: [String] = []
        for deck in try CorpusDeck.all() {
            var opens: [Double] = []
            var d: SlideDeck?
            for _ in 0..<5 { opens.append(Self.ms { d = try? SlideDeck(url: deck.url) }) }
            guard let deckA = d else { Issue.record("\(deck.label): open failed"); continue }
            let n = deckA.slideCount
            // Thumbnails on a fresh deck (parse + image decode on first touch), then again (all caches warm).
            let thumbCold = (0..<n).map { i in Self.ms { _ = deckA.thumbnail(i, maxPixel: 256) } }
            let thumbWarm = (0..<n).map { i in Self.ms { _ = deckA.thumbnail(i, maxPixel: 256) } }
            let deckB = try SlideDeck(url: deck.url)
            let fullCold = (0..<n).map { i in Self.ms { _ = deckB.thumbnail(i, maxPixel: 1600) } }
            let fullWarm = (0..<n).map { i in Self.ms { _ = deckB.thumbnail(i, maxPixel: 1600) } }
            let deckC = try SlideDeck(url: deck.url)
            let text = (0..<n).map { i in Self.ms { _ = deckC.slideText(i); _ = deckC.wordBoxes(i) } }
            let open = String(format: "%.1f / %.1f", opens[0], opens.sorted()[2])
            lines.append("| \(deck.label) | \(n) | \(open) | \(Self.stats(thumbCold)) | \(Self.stats(thumbWarm)) | "
                         + "\(Self.stats(fullCold)) | \(Self.stats(fullWarm)) | \(Self.stats(text)) |")
            // Every bitmap in ppt/media decoded once at full resolution (what ImageDecoder does on first use).
            var decodeMs = 0.0, pixels = 0, count = 0
            if let zip = try? ZipArchive(url: deck.url) {
                let decoder = ImageDecoder(package: OPCPackage(zip: zip))
                for name in zip.entryNames where name.hasPrefix("ppt/media/") {
                    var img: DecodedImage?
                    decodeMs += Self.ms { img = decoder.image(part: name) }
                    if case .bitmap(let cg)? = img { pixels += cg.width * cg.height; count += 1 }
                }
            }
            notes.append(String(format: "%@ media: %d bitmaps, %.0f Mpx, full decode %.0f ms", deck.label, count,
                                Double(pixels) / 1e6, decodeMs))
            let slow = thumbCold.enumerated().sorted { $0.element > $1.element }.prefix(3)
            notes.append("\(deck.label) slowest cold 256 px thumbnails: "
                         + slow.map { String(format: "#%d %.0f ms", $0.offset + 1, $0.element) }.joined(separator: ", "))
        }
        lines += [""] + notes
        let table = lines.joined(separator: "\n")
        print(table)
        let out = CorpusDeck.outDir
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try table.write(to: out.appendingPathComponent("bench-\(Int(Date().timeIntervalSince1970)).md"),
                        atomically: true, encoding: .utf8)
    }
}

// MARK: - PowerPoint reference (slidekit-ref)

/// PowerPoint mode: every deck `<name>.pptx` with a PowerPoint PDF export `<name>.pdf` next to it (the ground
/// truth). Each visible slide is rendered at 1600 px (long side) on white, next to its PDF page at the same pixel
/// size, and scored; sheets (PowerPoint | SlideKit | diff heat map) and `scores-<tag>.tsv` go to
/// `<out>/ppt/` (outside the repo). `PDFSUCHER_PPT_TAG` names the score file (default "latest").
/// Run: `PDFSUCHER_PPTX_CORPUS=… scripts/test.sh --filter SlideKitTests.PowerPointReferenceTests`
@Suite struct PowerPointReferenceTests {
    static let enabled = env["PDFSUCHER_PPTX_CORPUS"] != nil
    static let maxPixel = 1600
    /// A pixel "differs" when its largest channel difference exceeds this (0…255).
    static let pixelThreshold = 48
    /// Coarse score: 8×8 px block means compared, a block differs above this (0…255).
    static let block = 8
    static let blockThreshold = 24

    /// PDF page index for each visible slide. The export contains either all slides (hidden ones included) or
    /// only the visible ones; anything else is reported (nil = no mapping).
    static func pageMap(info: PresentationInfo, pageCount: Int) -> [Int]? {
        if pageCount == info.slides.count {
            return info.slides.enumerated().filter { !$0.element.hidden }.map(\.offset)
        }
        if pageCount == info.visibleSlides.count { return Array(0..<pageCount) }
        return nil
    }

    @Test(.enabled(if: enabled))
    func compareWithPowerPointPDFs() throws {
        let out = CorpusDeck.outDir.appendingPathComponent("ppt")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows = ["deck\tslide\tpptNumber\tpage\tmad\tpctDiff\tcoarsePct\twordJaccard"]
        var summary: [String] = []
        for deck in try CorpusDeck.all() {
            let pdfURL = deck.url.deletingPathExtension().appendingPathExtension("pdf")
            guard let pdf = PDFDocument(url: pdfURL) else { summary.append("\(deck.label): no PDF"); continue }
            let info = try PresentationInfo(package: OPCPackage(zip: ZipArchive(url: deck.url)))
            let d = try deck.open()
            guard let map = Self.pageMap(info: info, pageCount: pdf.pageCount) else {
                let counts = "\(pdf.pageCount) PDF pages, \(info.slides.count) slides, \(info.visibleSlides.count) visible"
                Issue.record("\(deck.label): \(counts)")
                continue
            }
            let hidden = info.slides.count - info.visibleSlides.count
            summary.append("\(deck.label): \(pdf.pageCount) PDF pages, \(info.slides.count) slides (\(hidden) hidden) → "
                           + (pdf.pageCount == info.slides.count && hidden > 0 ? "hidden slides exported, skipped" : "1:1"))
            let dir = out.appendingPathComponent(deck.label)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var triples: [(String, CGImage, CGImage, CGImage)] = []
            for i in 0..<d.slideCount {
                guard let page = pdf.page(at: map[i]), let (w, h) = SlideDeck.thumbnailSize(d.slideSize, maxPixel: Self.maxPixel),
                      let ref = Self.renderPDF(page, width: w, height: h),
                      let sk = Self.renderSlide(d, i, width: w, height: h) else {
                    Issue.record("\(deck.label) slide \(i + 1): render failed")
                    continue
                }
                let score = Self.score(ref, sk)
                let jac = Self.wordJaccard(page.string ?? "", d.slideText(i))
                let n = i + 1
                rows.append("\(deck.label)\t\(n)\t\(d.slides[i].powerPointNumber)\t\(map[i] + 1)\t"
                            + String(format: "%.2f\t%.2f\t%.2f\t%.2f", score.mad, score.pct, score.coarse, jac))
                write(ref.image, to: dir.appendingPathComponent(String(format: "ppt-%02d.png", n)))
                write(sk.image, to: dir.appendingPathComponent(String(format: "sk-%02d.png", n)))
                if let heat = Self.heatMap(ref, sk) {
                    let label = String(format: "%@ #%d  MAD %.1f  diff %.1f %%  coarse %.1f %%", deck.label, n,
                                       score.mad, score.pct, score.coarse)
                    if let t = Self.sheet([(label, ref.image, sk.image, heat)], cellW: 960) {
                        write(t, to: dir.appendingPathComponent(String(format: "cmp-%02d.png", n)))
                    }
                    triples.append((label, ref.image, sk.image, heat))
                }
            }
            for (k, start) in stride(from: 0, to: triples.count, by: 4).enumerated() {
                if let s = Self.sheet(Array(triples[start..<min(start + 4, triples.count)]), cellW: 640) {
                    write(s, to: out.appendingPathComponent("\(deck.label)-\(String(format: "%02d", k + 1)).png"))
                }
            }
        }
        let tag = env["PDFSUCHER_PPT_TAG"] ?? "latest"
        try rows.joined(separator: "\n").write(to: out.appendingPathComponent("scores-\(tag).tsv"), atomically: true, encoding: .utf8)
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("mapping.txt"), atomically: true, encoding: .utf8)
        #expect(rows.count > 1)
    }

    /// RGBA8 pixels on white.
    struct Pixels {
        let image: CGImage
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    static func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Pixels? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        draw(ctx)
        guard let img = ctx.makeImage(), let data = ctx.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return Pixels(image: img, bytes: bytes, width: width, height: height)
    }

    static func renderPDF(_ page: PDFPage, width: Int, height: Int) -> Pixels? {
        let b = page.bounds(for: .cropBox)
        return bitmap(width: width, height: height) { ctx in
            ctx.scaleBy(x: CGFloat(width) / b.width, y: CGFloat(height) / b.height)
            page.draw(with: .cropBox, to: ctx)
        }
    }

    static func renderSlide(_ d: SlideDeck, _ i: Int, width: Int, height: Int) -> Pixels? {
        bitmap(width: width, height: height) { ctx in
            d.render(i, in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    struct Score {
        /// Mean absolute channel difference (0…255).
        let mad: Double
        /// Percent of pixels whose largest channel difference exceeds `pixelThreshold`.
        let pct: Double
        /// Percent of 8×8 blocks whose mean colour differs by more than `blockThreshold` (insensitive to
        /// anti-aliasing and sub-pixel glyph shifts; what stays is real geometry, colour and missing elements).
        let coarse: Double
    }

    static func score(_ a: Pixels, _ b: Pixels) -> Score {
        let n = a.width * a.height
        var sum = 0, over = 0
        for p in 0..<n {
            let o = p * 4
            let dr = abs(Int(a.bytes[o]) - Int(b.bytes[o]))
            let dg = abs(Int(a.bytes[o + 1]) - Int(b.bytes[o + 1]))
            let db = abs(Int(a.bytes[o + 2]) - Int(b.bytes[o + 2]))
            sum += dr + dg + db
            if max(dr, dg, db) > pixelThreshold { over += 1 }
        }
        let bw = a.width / block, bh = a.height / block
        var blocksOver = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                var sa = [0, 0, 0], sb = [0, 0, 0]
                for y in by * block..<(by + 1) * block {
                    for x in bx * block..<(bx + 1) * block {
                        let o = (y * a.width + x) * 4
                        for c in 0..<3 { sa[c] += Int(a.bytes[o + c]); sb[c] += Int(b.bytes[o + c]) }
                    }
                }
                let d = (0..<3).map { abs(sa[$0] - sb[$0]) / (block * block) }.max() ?? 0
                if d > blockThreshold { blocksOver += 1 }
            }
        }
        return Score(mad: Double(sum) / Double(n * 3), pct: 100 * Double(over) / Double(n),
                     coarse: 100 * Double(blocksOver) / Double(max(bw * bh, 1)))
    }

    /// Light grey PowerPoint image with the per-pixel difference in red (full red at ≥ 128).
    static func heatMap(_ a: Pixels, _ b: Pixels) -> CGImage? {
        var px = [UInt8](repeating: 255, count: a.width * a.height * 4)
        for p in 0..<(a.width * a.height) {
            let o = p * 4
            let lum = (Int(a.bytes[o]) * 3 + Int(a.bytes[o + 1]) * 6 + Int(a.bytes[o + 2])) / 10
            let base = 255 - (255 - lum) / 4
            let d = (0..<3).map { abs(Int(a.bytes[o + $0]) - Int(b.bytes[o + $0])) }.max() ?? 0
            let t = min(Double(d) / 128, 1)
            px[o] = UInt8(Double(base) * (1 - t) + 230 * t)
            px[o + 1] = UInt8(Double(base) * (1 - t))
            px[o + 2] = UInt8(Double(base) * (1 - t))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: a.width, height: a.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: a.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Word-set overlap of the PDF page text and slideText (checks the page mapping).
    static func wordJaccard(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Rows of (label, PowerPoint, SlideKit, heat map), each image aspect-fit into a `cellW` cell.
    static func sheet(_ rows: [(String, CGImage, CGImage, CGImage)], cellW: CGFloat) -> CGImage? {
        let gap: CGFloat = 10, labelH: CGFloat = 28
        let cellH = rows.map { CGFloat($0.1.height) / CGFloat($0.1.width) * cellW }.max() ?? cellW * 9 / 16
        let rowH = labelH + cellH + gap
        let w = Int(cellW * 3 + gap * 4), h = Int(rowH * CGFloat(rows.count) + gap)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.45, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
        for (r, row) in rows.enumerated() {
            let top = CGFloat(h) - gap - CGFloat(r) * rowH
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            if let str = CFAttributedStringCreate(nil, (row.0 + "      PowerPoint | SlideKit | diff") as CFString, attrs) {
                ctx.textPosition = CGPoint(x: gap, y: top - labelH + 8)
                CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
            }
            for (c, img) in [row.1, row.2, row.3].enumerated() {
                let cell = CGRect(x: gap + CGFloat(c) * (cellW + gap), y: top - labelH - cellH, width: cellW, height: cellH)
                let s = min(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: cell.midX - iw / 2, y: cell.maxY - ih, width: iw, height: ih))
            }
        }
        return ctx.makeImage()
    }
}

// MARK: - Text line measurements (slidekit-ref)

/// One text-showing operator of a PDF content stream: baseline start in page points (y down) and the font size
/// in page points (text matrix × CTM).
struct PDFTextOp {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
}

/// Minimal content-stream walker (CGPDFScanner): tracks q/Q/cm, BT/Tm/Td/TD/T*/TL/Tf and form XObjects (Do), and
/// records where each Tj/TJ/'/" starts. Good enough for PowerPoint's PDF export (no Type 3 fonts, no text clip
/// tricks); advances inside a TJ are not tracked, only the operator's start point.
final class PDFTextScanner {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var tm = CGAffineTransform.identity
    var tlm = CGAffineTransform.identity
    var fontSize: CGFloat = 0
    var leading: CGFloat = 0
    var ops: [PDFTextOp] = []
    let pageHeight: CGFloat
    let pageOrigin: CGPoint
    var streams: [CGPDFContentStreamRef] = []

    init(page: CGPDFPage) {
        let box = page.getBoxRect(.cropBox)
        pageHeight = box.height
        pageOrigin = box.origin
        scan(CGPDFContentStreamCreateWithPage(page))
    }

    func scan(_ stream: CGPDFContentStreamRef) {
        streams.append(stream)
        defer { streams.removeLast() }
        guard let table = CGPDFOperatorTableCreate() else { return }
        func set(_ name: String, _ cb: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, cb) }
        set("q") { _, i in guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }; s.stack.append(s.ctm) }
        set("Q") { _, i in guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }; if let c = s.stack.popLast() { s.ctm = c } }
        set("cm") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }), let m = PDFTextScanner.matrix(sc) else { return }
            s.ctm = m.concatenating(s.ctm)
        }
        set("BT") { _, i in guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }; s.tm = .identity; s.tlm = .identity }
        set("Tm") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }), let m = PDFTextScanner.matrix(sc) else { return }
            s.tm = m; s.tlm = m
        }
        set("Td") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var ty: CGPDFReal = 0, tx: CGPDFReal = 0
            guard CGPDFScannerPopNumber(sc, &ty), CGPDFScannerPopNumber(sc, &tx) else { return }
            s.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(s.tlm); s.tm = s.tlm
        }
        set("TD") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var ty: CGPDFReal = 0, tx: CGPDFReal = 0
            guard CGPDFScannerPopNumber(sc, &ty), CGPDFScannerPopNumber(sc, &tx) else { return }
            s.leading = -ty
            s.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(s.tlm); s.tm = s.tlm
        }
        set("TL") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var l: CGPDFReal = 0
            if CGPDFScannerPopNumber(sc, &l) { s.leading = l }
        }
        set("T*") { _, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            s.tlm = CGAffineTransform(translationX: 0, y: -s.leading).concatenating(s.tlm); s.tm = s.tlm
        }
        set("Tf") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var size: CGPDFReal = 0
            if CGPDFScannerPopNumber(sc, &size) { s.fontSize = size }
        }
        let show: CGPDFOperatorCallback = { _, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            s.record()
        }
        set("Tj", show)
        set("TJ", show)
        set("'") { _, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            s.tlm = CGAffineTransform(translationX: 0, y: -s.leading).concatenating(s.tlm); s.tm = s.tlm; s.record()
        }
        set("Do") { sc, i in
            guard let s = i.map({ Unmanaged<PDFTextScanner>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(sc, &name), let name, let cur = s.streams.last,
                  let obj = CGPDFContentStreamGetResource(cur, "XObject", name) else { return }
            var st: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &st), let st, let dict = CGPDFStreamGetDictionary(st) else { return }
            var sub: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &sub), let sub, String(cString: sub) == "Form" else { return }
            let saved = s.ctm
            var arr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                for k in 0..<6 { CGPDFArrayGetNumber(arr, k, &v[k]) }
                s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
            }
            s.scan(CGPDFContentStreamCreateWithStream(st, dict, cur))
            s.ctm = saved
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    static func matrix(_ sc: CGPDFScannerRef) -> CGAffineTransform? {
        var v = [CGPDFReal](repeating: 0, count: 6)
        for k in (0..<6).reversed() { guard CGPDFScannerPopNumber(sc, &v[k]) else { return nil } }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    func record() {
        let m = tm.concatenating(ctm)
        let p = CGPoint.zero.applying(m)
        let size = fontSize * hypot(m.c, m.d)
        ops.append(PDFTextOp(x: p.x - pageOrigin.x, y: pageHeight - (p.y - pageOrigin.y), size: size))
    }
}

/// Dumps measured text lines of selected slides (PDFSUCHER_PPT_TEXT="D1:7,D3:12" or "all"): PowerPoint baselines
/// (content stream) with PDFKit's line text, and SlideKit's baselines from the laid-out lines, in slide points.
@Suite struct TextLineMeasurements {
    static let spec = env["PDFSUCHER_PPT_TEXT"]
    static let enabled = env["PDFSUCHER_PPTX_CORPUS"] != nil && spec != nil

    static func wanted(_ label: String, _ n: Int) -> Bool {
        guard let spec, spec != "all" else { return true }
        return spec.split(separator: ",").contains { $0 == "\(label):\(n)" || $0 == label }
    }

    @Test(.enabled(if: enabled))
    func dumpTextLines() throws {
        let out = CorpusDeck.outDir.appendingPathComponent("ppt/text")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var matched = ["deck\tslide\tshape\tanchor\tpara\tline\tspacing\tfirstSpcBef\tskSize\tpptSize\tskY\tpptY\tdelta\tdescent\ttext"]
        var bulletGaps = ["deck\tslide\tshape\tsize\tbulletEnd\tskTextX\tpptTextX\tdelta"]
        defer {
            try? bulletGaps.joined(separator: "\n").write(to: out.appendingPathComponent("bullet-gaps.tsv"), atomically: true,
                                                         encoding: .utf8)
            try? matched.joined(separator: "\n").write(to: out.appendingPathComponent("matched-lines.tsv"), atomically: true,
                                                        encoding: .utf8)
        }
        for deck in try CorpusDeck.all() {
            let pdfURL = deck.url.deletingPathExtension().appendingPathExtension("pdf")
            guard let pdf = PDFDocument(url: pdfURL) else { continue }
            let info = try PresentationInfo(package: OPCPackage(zip: ZipArchive(url: deck.url)))
            let d = try deck.open()
            guard let map = PowerPointReferenceTests.pageMap(info: info, pageCount: pdf.pageCount) else { continue }
            for i in 0..<d.slideCount where Self.wanted(deck.label, i + 1) {
                guard let page = pdf.page(at: map[i]), let cg = page.pageRef else { continue }
                var lines: [String] = ["# \(deck.label) slide \(i + 1)", "## PowerPoint (baseline y, x, size | text of the PDFKit line)"]
                let h = page.bounds(for: .cropBox).height
                let pdfLines = (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).map { sel in
                    (sel.string ?? "", sel.bounds(for: page))
                }
                var seen = Set<String>()
                let ops = PDFTextScanner(page: cg).ops
                for op in ops {
                    let key = String(format: "%.2f|%.1f", op.y, op.size)
                    let text = pdfLines.first { l in
                        let r = l.1
                        return h - op.y >= r.minY - 1 && h - op.y <= r.maxY + 1 && op.x >= r.minX - 2 && op.x <= r.maxX + 2
                    }?.0 ?? "?"
                    guard seen.insert(key + text).inserted else { continue }
                    lines.append(String(format: "%8.2f %8.2f %6.2f | ", op.y, op.x, op.size) + String(text.prefix(60)))
                }
                lines.append("## SlideKit (baseline y, x, size, pitch, ascent, descent | text)")
                let layout = d.store.textLayout(d.slides[i])
                for shape in layout.shapes where shape.layer == .slide {
                    // Anchor as placed: first line at the box top, last line at its bottom, else centred.
                    let bottom = shape.pieces.map { p in
                        p.origin.y - (shape.sets[p.paragraph].lines.first?.top ?? 0)
                            + shape.sets[p.paragraph].lines[p.lines].reduce(0) { $0 + $1.height }
                    }.max() ?? 0
                    let anchor = abs(shape.pieces.first?.origin.y ?? 0) < 0.01 ? "t"
                        : abs(bottom - shape.boxSize.height) < 0.01 ? "b" : "c"
                    for piece in shape.pieces {
                        let set = shape.sets[piece.paragraph], para = shape.paragraphs[piece.paragraph]
                        guard set.lines.indices.contains(piece.lines.lowerBound) else { continue }
                        let dy = piece.origin.y - set.lines[piece.lines.lowerBound].top
                        for li in piece.lines where set.lines.indices.contains(li) {
                            let l = set.lines[li]
                            let p = CGPoint(x: piece.origin.x + l.origin.x, y: dy + l.origin.y).applying(shape.toSlide)
                            let size = (para.runs.first?.style.size ?? para.endRunStyle.size) * CGFloat(shape.fontScale)
                            let ns = set.plainText as NSString
                            let r = NSRange(location: l.range.lowerBound, length: min(l.range.count, ns.length - l.range.lowerBound))
                            let text = r.length > 0 ? ns.substring(with: r) : ""
                            lines.append(String(format: "%8.2f %8.2f %6.2f %6.2f %6.2f %6.2f | ", p.y, p.x, size, l.height,
                                                l.ascent, l.descent) + String(text.prefix(60)))
                            // Bullet that pushes the first line's text: SlideKit's text x vs the nearest PowerPoint
                            // text start on that baseline right of the bullet.
                            if li == 0, let b = set.bullet, b.text != nil, l.origin.x > para.style.marginLeft + 0.01 {
                                let bx = CGPoint(x: piece.origin.x + b.rect.maxX, y: dy + l.origin.y).applying(shape.toSlide).x
                                if let m = ops.filter({ abs($0.y - p.y) < 1 && $0.x > bx - 0.5 })
                                    .min(by: { abs($0.x - p.x) < abs($1.x - p.x) }) {
                                    bulletGaps.append(String(format: "%@\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f", deck.label, i + 1,
                                                             shape.tag, size, bx, p.x, m.x, p.x - m.x))
                                }
                            }
                            // Matched PowerPoint baseline: same start x (±1.5 pt), size (±1.2 pt), nearest y (±8 pt).
                            let cands = ops.filter { abs($0.x - p.x) < 1.5 && abs($0.size - size) < 1.2 && abs($0.y - p.y) < 8 }
                            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  shape.toSlide.b == 0, shape.toSlide.c == 0,
                                  let m = cands.min(by: { abs($0.y - p.y) < abs($1.y - p.y) }) else { continue }
                            let f: String = switch para.style.lineSpacing {
                            case .multiple(let v): String(format: "m%.3f", v - shape.lineSpaceReduction)
                            case .exact(let v): String(format: "e%.2f", v)
                            case .atLeast(let v): String(format: "a%.2f", v)
                            }
                            matched.append(String(format: "%@\t%d\t%d\t%@\t%d\t%d\t%@\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%@", deck.label, i + 1,
                                                  shape.tag, anchor, piece.paragraph, li, f, shape.sets[0].spaceBefore, size, m.size, p.y, m.y, p.y - m.y, l.descent,
                                                  String(text.prefix(24)).replacingOccurrences(of: "\t", with: " ")
                                                    .replacingOccurrences(of: "\n", with: " ")))
                        }
                    }
                }
                try lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(deck.label)-\(String(format: "%02d", i + 1)).txt"),
                                                       atomically: true, encoding: .utf8)
            }
        }
    }
}
