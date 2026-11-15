import Foundation
import OutputKit
import Testing
import TestSupport
@testable import ViewerUI
@testable import AppCore

/// 1.3.1: once the sources are restored, tiles of PDFs outside them go without a look at those PDFs (in 1.3.0
/// the launch asked every entry's PDF, and macOS asked for access to Downloads). Remembered missing sources (an
/// unplugged disk) keep theirs.
@MainActor @Suite("Tiles dropped at launch", .timeLimit(.minutes(1)))
struct TileDropAtLaunchTests {
    func tile(_ url: URL, _ disk: TileDiskCache) async {
        _ = await ThumbnailCache(disk: disk).thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141))
    }

    func folders(_ disk: TileDiskCache) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: disk.versionDirectory.path)) ?? [])
    }

    func folder(of url: URL) -> String { TileDiskCache.name(source: url.standardizedFileURL.path, parts: []).folder }

    @Test func restoreDropsTilesOutsideTheSources() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let akten = base.appendingPathComponent("Akten", isDirectory: true)
        let stick = base.appendingPathComponent("Stick", isDirectory: true)          // unplugged at the next launch
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)  // not a source (any more)
        for dir in [akten, stick, downloads] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let inAkten = akten.appendingPathComponent("a.pdf"), onStick = stick.appendingPathComponent("s.pdf")
        let inDownloads = downloads.appendingPathComponent("d.pdf")
        for url in [inAkten, onStick, inDownloads] { try PDFFixtures.makePDF(at: url, pages: ["x"]) }
        let disk = TileDiskCache(directory: base.appendingPathComponent("Tiles"))
        for url in [inAkten, onStick, inDownloads] { await tile(url, disk) }
        disk.flush()
        try FileManager.default.removeItem(at: stick)

        let defaults = UserDefaults(suiteName: "TileDrop-\(UUID().uuidString)")!
        defaults.set([akten.path, stick.path], forKey: "sources")
        let m = AppModel(settings: makeSettings(), defaults: defaults, environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                         openIndex: { _ in FakeIndex() })
        m.tileDisk = disk
        await m.restoreSources()
        await m.waitUntilIdle()
        disk.flush()
        #expect(folders(disk) == [folder(of: inAkten), folder(of: onStick)])
    }

    /// No saved sources: nothing to keep.
    @Test func noSavedSourcesDropsAllTiles() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let pdf = base.appendingPathComponent("a.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["x"])
        let disk = TileDiskCache(directory: base.appendingPathComponent("Tiles"))
        await tile(pdf, disk)
        disk.flush()
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "TileDrop-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: { _ in FakeIndex() })
        m.tileDisk = disk
        await m.restoreSources()
        disk.flush()
        #expect(folders(disk).isEmpty)
    }

    /// A folder whose index cannot be opened now stays remembered, and so do its tiles.
    @Test func aSourceWhoseIndexFailsKeepsItsTiles() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let broken = base.appendingPathComponent("Kaputt", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let pdf = broken.appendingPathComponent("k.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["x"])
        let disk = TileDiskCache(directory: base.appendingPathComponent("Tiles"))
        await tile(pdf, disk)
        disk.flush()
        let defaults = UserDefaults(suiteName: "TileDrop-\(UUID().uuidString)")!
        defaults.set([broken.path], forKey: "sources")
        let m = AppModel(settings: makeSettings(), defaults: defaults, environment: FakeEnvironment(), slideCache: testSlideCache,
                         debounce: .zero, openIndex: { _ in throw CocoaError(.fileReadCorruptFile) })
        m.tileDisk = disk
        await m.restoreSources()
        await m.waitUntilIdle()
        disk.flush()
        #expect(folders(disk) == [folder(of: pdf)])
    }
}
