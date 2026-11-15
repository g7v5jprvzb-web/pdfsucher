import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import ViewerUI

/// Merge 1.2.4: the disk-cache cleanup decides by path, modification date and size only — never by
/// file kind — so the tile folders of Word and PowerPoint files (valid sources since 1.3) stay.
struct OfficeTileCacheTests {
    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    private func folderExists(_ disk: TileDiskCache, for path: String) -> Bool {
        FileManager.default.fileExists(atPath: disk.folderURL(TileDiskCache.name(source: path, parts: []).folder).path)
    }

    @Test func diskCacheCleanupKeepsOfficeTiles() throws {
        let dir = try PDFFixtures.tempDirectory()
        let names = ["a.pdf", "b.docx", "c.pptx", "orphan.docx"]
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        disk.flush()
        for url in urls {
            let path = url.standardizedFileURL.path
            let source = try #require(TileDiskCache.Source.current(path))
            disk.store(image(), named: TileDiskCache.name(source: path, parts: ["0"]), source: source)
        }
        disk.flush()
        try FileManager.default.removeItem(at: urls[3])          // the orphan: its file is gone

        disk.pruneStale(under: dir)                              // after indexing
        disk.dropTiles(notUnder: [dir])                          // at launch (1.3.1: no look at the files)
        disk.flush()

        for url in urls.prefix(3) {
            #expect(folderExists(disk, for: url.standardizedFileURL.path), "\(url.lastPathComponent) keeps its tiles")
        }
        #expect(!folderExists(disk, for: urls[3].standardizedFileURL.path), "the orphan's tiles are gone")
    }
}
