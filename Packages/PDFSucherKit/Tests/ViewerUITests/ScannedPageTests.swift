import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import TestSupport
@testable import ViewerUI

/// Spec 1.2.3: scanned pages are drawn from a reduced JPEG decode, looking like PDFKit's drawing.
@Suite("ScannedPage")
struct ScannedPageTests {
    /// A JPEG of a red square on blue, 1200×1600.
    static func jpeg() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 1000, width: 600, height: 600))  // top left
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// A one-page "scan": the JPEG drawn over an A4 page, optionally with extra vector content.
    static func scanPDF(extraLine: Bool = false) throws -> URL {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let source = try #require(CGImageSourceCreateWithData(try jpeg() as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        if extraLine {
            ctx.setStrokeColor(.black); ctx.setLineWidth(20)
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: 0), CGPoint(x: 595, y: 842)])
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test func plainScanHasAPlan() throws {
        let page = try #require(PDFDocument(url: try Self.scanPDF())?.page(at: 0)?.pageRef)
        let plan = try #require(ScannedPage.plan(page))
        #expect(plan.pixelWidth == 1200 && plan.pixelHeight == 1600)
    }

    @Test func vectorContentFallsBackToPDFKit() throws {
        let page = try #require(PDFDocument(url: try Self.scanPDF(extraLine: true))?.page(at: 0)?.pageRef)
        #expect(ScannedPage.plan(page) == nil)
    }

    @Test func textPageHasNoPlan() throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("t.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Ein Text"])
        let page = try #require(PDFDocument(url: url)?.page(at: 0)?.pageRef)
        #expect(ScannedPage.plan(page) == nil)
    }

    /// The fast path matches PDFKit's own drawing, also on rotated pages.
    @Test(arguments: [0, 90, 180, 270])
    func looksLikePDFKit(rotation: Int) throws {
        let page = try #require(PDFDocument(url: try Self.scanPDF())?.page(at: 0))
        page.rotation = rotation     // in memory: a rewritten file would no longer be a plain scan
        let size = rotation % 180 == 0 ? CGSize(width: 150, height: 212) : CGSize(width: 212, height: 150)
        let fast = try #require(Self.draw(page, size: size, fast: true))
        let slow = try #require(Self.draw(page, size: size, fast: false))
        #expect(Self.meanDifference(fast, slow) < 6, "rotation \(rotation)")
    }

    static func draw(_ page: PDFPage, size: CGSize, fast: Bool) -> [UInt8]? {
        let w = Int(size.width), h = Int(size.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let box = page.bounds(for: .cropBox)
            let shown = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            let fit = min(size.width / shown.width, size.height / shown.height)
            ctx.scaleBy(x: fit, y: fit)
            if fast { return ScannedPage.draw(page, in: ctx) }
            page.draw(with: .cropBox, to: ctx)
            return true
        }
        return ok ? data : nil
    }

    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }
}
