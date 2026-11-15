import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OOXMLKit

/// Runs only with PDFSUCHER_PPTX_CORPUS=<folder of .pptx>. Parses and renders every EMF/WMF/EMZ/WMZ in
/// ppt/media of every deck (read in place, never copied) and writes 512 px renders plus a contact sheet to
/// /tmp/slidekit-emf/ for visual inspection.
@Suite struct MetafileCorpusTests {
    static let corpus = ProcessInfo.processInfo.environment["PDFSUCHER_PPTX_CORPUS"]

    @Test(.enabled(if: corpus != nil))
    func everyCorpusMetafileParsesAndRenders() throws {
        let dir = URL(fileURLWithPath: ((Self.corpus ?? "") as NSString).expandingTildeInPath)
        let decks = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["pptx", "pptm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let out = URL(fileURLWithPath: "/tmp/slidekit-emf")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var renders: [(String, CGImage)] = []
        var unknown: [UInt32: Int] = [:]
        var files = 0, drew = 0, emfPlusOnly = 0, empty = 0
        var lines: [String] = []
        for deck in decks {
            let zip = try ZipArchive(url: deck)
            for name in zip.entryNames.sorted() where name.hasPrefix("ppt/media/") {
                let ext = (name as NSString).pathExtension.lowercased()
                guard ["emf", "wmf", "emz", "wmz"].contains(ext) else { continue }
                files += 1
                let data = try zip.data(name)
                let t0 = Date()
                guard let meta = Metafile.decode(data) else {
                    Issue.record("\(deck.lastPathComponent) \(name): not decodable")
                    continue
                }
                var count = 0
                var unk: [UInt32: Int] = [:]
                var plusOnly = false
                switch meta {
                case .emf(let d): count = d.recordCount; unk = d.unknownRecordTypes; plusOnly = d.isEMFPlusOnly
                case .wmf(let d): count = d.recordCount; unk = d.unknownRecordTypes
                }
                for (k, v) in unk { unknown[k, default: 0] += v }
                let t1 = Date()
                let img = render(meta, size: 512)
                let ms = (Int(t1.timeIntervalSince(t0) * 1000), Int(Date().timeIntervalSince(t1) * 1000))
                let ink = img.map(Self.hasInk) ?? false
                if ink { drew += 1 }
                if plusOnly { emfPlusOnly += 1 }
                if !ink && !plusOnly { empty += 1 }
                let label = "\(files) \(deck.deletingPathExtension().lastPathComponent.prefix(24)) \(name.dropFirst(10))"
                lines.append("\(label): records \(count), unknown \(unk.sorted { $0.key < $1.key }), "
                             + "drew \(ink)\(plusOnly ? ", EMF+ only" : ""), bounds \(meta.bounds), parse \(ms.0) ms, render \(ms.1) ms")
                if let img {
                    renders.append((label, img))
                    write(img, to: out.appendingPathComponent(String(format: "%02d.png", files)))
                }
            }
        }
        if let sheet = contactSheet(renders.map(\.1), cell: 200) {
            write(sheet, to: out.appendingPathComponent("contact-sheet.png"))
        }
        let summary = "files \(files), drew \(drew), EMF+ only \(emfPlusOnly), drew nothing otherwise \(empty), "
            + "unknown record types \(unknown.sorted { $0.key < $1.key })"
        try (lines + [summary]).joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"),
                                                                atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        print(summary)
        #expect(files > 0)
    }

    /// Renders on transparent, fitted into size × size keeping the frame's aspect.
    private func render(_ m: Metafile, size: Int) -> CGImage? {
        let b = m.bounds
        let aspect = b.width > 0 && b.height > 0 ? b.width / b.height : 1
        let w = aspect >= 1 ? size : max(Int(CGFloat(size) * aspect), 1)
        let h = aspect >= 1 ? max(Int(CGFloat(size) / aspect), 1) : size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        m.draw(in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func hasInk(_ img: CGImage) -> Bool {
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        for y in 0..<img.height {
            for x in 0..<img.width where p[y * img.bytesPerRow + x * 4 + 3] != 0 { return true }
        }
        return false
    }

    /// 8-column grid on gray; each render fitted and centred on a white cell.
    private func contactSheet(_ images: [CGImage], cell: Int) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let cols = 8, rows = (images.count + cols - 1) / cols, pad = 6
        let w = cols * (cell + pad) + pad, h = rows * (cell + pad) + pad
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, img) in images.enumerated() {
            let cx = pad + (i % cols) * (cell + pad), cy = h - (pad + (i / cols + 1) * (cell + pad)) + pad
            let cellRect = CGRect(x: cx, y: cy, width: cell, height: cell)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(cellRect)
            let s = min(CGFloat(cell) / CGFloat(img.width), CGFloat(cell) / CGFloat(img.height))
            let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: cellRect.midX - iw / 2, y: cellRect.midY - ih / 2, width: iw, height: ih))
        }
        return ctx.makeImage()
    }

    private func write(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
