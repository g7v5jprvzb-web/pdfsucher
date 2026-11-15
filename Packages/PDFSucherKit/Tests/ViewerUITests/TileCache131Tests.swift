import AppKit
import Foundation
import OutputKit
import SearchKit
import Testing
import TestSupport
@testable import ViewerUI

/// 1.3.1: the tile cache does not touch the PDFs of its entries at launch. In 1.3.0 `init` asked every entry's
/// file and folder (142 accesses, 6 in Downloads), and macOS asked for access to the Downloads folder.
@Suite("Tile cache 1.3.1", .timeLimit(.minutes(2)))
struct TileCache131Tests {
    private func fixture(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try PDFFixtures.makePDF(at: url, pages: ["Seite 1"])
        return url
    }

    private func folders(_ disk: TileDiskCache) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: disk.versionDirectory.path)) ?? [])
    }

    private func folder(of url: URL) -> String { TileDiskCache.name(source: url.standardizedFileURL.path, parts: []).folder }

    private func tile(_ url: URL, _ disk: TileDiskCache) async {
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141))
    }

    /// A PDF deleted while the app was closed keeps its tiles at launch; they go with the source's index run
    /// (`pruneStale(under:)`) or with `dropTiles(notUnder:)`.
    @Test func launchDoesNotAskTheSources() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let gone = try fixture("gone.pdf", in: dir)
        let root = try PDFFixtures.tempDirectory().appendingPathComponent("Tiles")
        let first = TileDiskCache(directory: root)
        await tile(gone, first)
        first.flush()
        try FileManager.default.removeItem(at: gone)
        let relaunched = TileDiskCache(directory: root)
        relaunched.flush()
        #expect(folders(relaunched).contains(folder(of: gone)), "no stat of the PDF at launch")
    }

    /// Entries outside the current sources go without a look at their files; entries inside stay for the
    /// index run to check, even when their PDF is gone.
    @Test func dropTilesOutsideTheSourcesWithoutAskingThem() async throws {
        let source = try PDFFixtures.tempDirectory(), other = try PDFFixtures.tempDirectory()
        let inside = try fixture("inside.pdf", in: source)
        let goneInside = try fixture("gone.pdf", in: source)
        let outside = try fixture("outside.pdf", in: other)
        let single = try fixture("single.pdf", in: other)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        for url in [inside, goneInside, outside, single] { await tile(url, disk) }
        disk.flush()
        try FileManager.default.removeItem(at: goneInside)
        // Its PDF gone or not: an entry outside the sources goes without a look at the file.
        try FileManager.default.removeItem(at: other.appendingPathComponent("outside.pdf"))
        disk.dropTiles(notUnder: [source, single])
        disk.flush()
        #expect(folders(disk) == [folder(of: inside), folder(of: goneInside), folder(of: single)])
    }

    @Test func noSourcesDropsEverything() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let a = try fixture("a.pdf", in: dir)
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        await tile(a, disk)
        disk.flush()
        disk.dropTiles(notUnder: [])
        disk.flush()
        #expect(folders(disk).isEmpty)
    }
}
