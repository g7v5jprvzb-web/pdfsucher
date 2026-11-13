import Testing
import Foundation
import IndexKit
import TestSupport

@Suite("FolderScanner")
struct FolderScannerTests {
    private let fm = FileManager.default

    private func touch(_ url: URL, _ contents: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test func findsPdfsCaseInsensitive() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("a.pdf"))
        try touch(root.appendingPathComponent("B.PDF"))
        try touch(root.appendingPathComponent("c.txt"))
        let files = try FolderScanner().scan(root: root)
        #expect(files.map(\.relativePath) == ["B.PDF", "a.pdf"])
    }

    @Test func fillsMetadataAndUsesSlashPaths() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("sub/inner/doc.pdf")
        try touch(file, "12345")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let files = try FolderScanner().scan(root: root)
        let scanned = try #require(files.first)
        #expect(files.count == 1)
        #expect(scanned.relativePath == "sub/inner/doc.pdf")
        #expect(scanned.fileSize == 5)
        #expect(abs(scanned.modifiedAt.timeIntervalSince(date)) < 0.001)
        #expect(scanned.url.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    @Test func respectsDepthLimit() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        // A pdf at depth 0 (root) and in each of 11 nested dirs (depths 1…11).
        var dir = root
        try touch(dir.appendingPathComponent("p0.pdf"))
        for depth in 1...11 {
            dir = dir.appendingPathComponent("d\(depth)", isDirectory: true)
            try touch(dir.appendingPathComponent("p\(depth).pdf"))
        }
        let names = Set(try FolderScanner().scan(root: root).map { ($0.relativePath as NSString).lastPathComponent })
        #expect(names.count == 11)
        #expect(names == Set((0...10).map { "p\($0).pdf" }))
        #expect(!names.contains("p11.pdf"))
    }

    @Test func customDepthLimit() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("top.pdf"))
        try touch(root.appendingPathComponent("a/one.pdf"))
        try touch(root.appendingPathComponent("a/b/two.pdf"))
        #expect(try FolderScanner(maxDepth: 0).scan(root: root).map(\.relativePath) == ["top.pdf"])
        #expect(try FolderScanner(maxDepth: 1).scan(root: root).map(\.relativePath) == ["a/one.pdf", "top.pdf"])
    }

    @Test func skipsHiddenAndPackages() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent(".hidden.pdf"))
        try touch(root.appendingPathComponent(".hiddendir/inside.pdf"))
        try touch(root.appendingPathComponent("x.app/y.pdf"))
        #expect(try FolderScanner().scan(root: root).isEmpty)
    }

    @Test func survivesSymlinkLoop() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("sub/a.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("sub/loop").path, withDestinationPath: "..")
        let start = Date()
        let files = try FolderScanner().scan(root: root)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(files.map(\.relativePath) == ["sub/a.pdf"])
    }

    @Test func followsSymlinkedFile() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("real/doc.pdf"), "abc")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link.pdf").path, withDestinationPath: "real/doc.pdf")
        let files = try FolderScanner().scan(root: root)
        #expect(files.map(\.relativePath) == ["link.pdf", "real/doc.pdf"])
        // The link reports the target's size, not the link's.
        #expect(files.allSatisfy { $0.fileSize == 3 })
    }

    @Test func followsSymlinkedDirectoryOutsideRoot() throws {
        let root = try PDFFixtures.tempDirectory()
        let outside = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try touch(outside.appendingPathComponent("ext.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["linked/ext.pdf"])
    }

    @Test func rootMayBeASymlink() throws {
        let real = try PDFFixtures.tempDirectory()
        let holder = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: real); try? fm.removeItem(at: holder) }
        try touch(real.appendingPathComponent("sub/r.pdf"))
        let link = holder.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let files = try FolderScanner().scan(root: link)
        #expect(files.map(\.relativePath) == ["sub/r.pdf"])
        #expect(files.first?.url.path.hasPrefix(link.standardizedFileURL.path) == true)
    }

    @Test func skipsBrokenSymlink() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("ok.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dead.pdf").path, withDestinationPath: "nowhere.pdf")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("deaddir").path, withDestinationPath: "/Volumes/PDFSucherNotMounted/x")
        let result = try FolderScanner().scanDetailed(root: root)
        #expect(result.files.map(\.relativePath) == ["ok.pdf"])
        // Broken links may point to an unmounted volume: reported, so their documents are kept.
        #expect(result.unreachablePaths == ["dead.pdf", "deaddir"])
    }

    @Test func directoryNamedPdfIsNotAFile() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("folder.pdf/real.pdf"))
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["folder.pdf/real.pdf"])
    }

    @Test func realDirectoryWinsOverLinkToIt() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("zreal/a.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("alink").path, withDestinationPath: "zreal")
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["zreal/a.pdf"])
    }

    @Test func deepLinkDoesNotShadowShallowRealDirectory() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("z_shared/top.pdf"))
        try touch(root.appendingPathComponent("z_shared/s1/deep.pdf"))
        let deep = root.appendingPathComponent("a/l1/l2/l3/l4/l5/l6/l7/l8", isDirectory: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: deep.appendingPathComponent("link").path,
                                  withDestinationPath: root.appendingPathComponent("z_shared").path)
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["z_shared/s1/deep.pdf", "z_shared/top.pdf"])
    }

    @Test func linkToPrivateTmpIsFollowed() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        let target = URL(fileURLWithPath: "/private/tmp/PDFSucherScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: target) }
        try touch(target.appendingPathComponent("t.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("tmp").path,
                                  withDestinationPath: "/tmp/" + target.lastPathComponent)
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["tmp/t.pdf"])
    }

    @Test func reportsUnreadableSubdirectoryAndKeepsSiblings() throws {
        let root = try PDFFixtures.tempDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        try touch(locked.appendingPathComponent("secret.pdf"))
        try touch(root.appendingPathComponent("open/ok.pdf"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let result = try FolderScanner().scanDetailed(root: root)
        #expect(result.files.map(\.relativePath) == ["open/ok.pdf"])
        #expect(result.unreachablePaths == ["locked"])
    }

    @Test func hiddenFlagWithoutDotIsSkipped() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        var hidden = root.appendingPathComponent("flagged.pdf")
        try touch(hidden)
        try touch(root.appendingPathComponent("visible.pdf"))
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["visible.pdf"])
    }

    @Test func umlautNamesAreNFCAndOpenable() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        let decomposed = "A\u{0308}nderung/Vertra\u{0308}ge.pdf"
        try touch(root.appendingPathComponent(decomposed), "abc")
        let file = try #require(try FolderScanner().scan(root: root).first)
        #expect(file.relativePath.unicodeScalars.map(\.value)
                == "\u{00C4}nderung/Vertr\u{00E4}ge.pdf".unicodeScalars.map(\.value))
        #expect(try Data(contentsOf: file.url) == Data("abc".utf8))
    }

    @Test func linkToPackageIsSkipped() throws {
        let root = try PDFFixtures.tempDirectory()
        let outside = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try touch(outside.appendingPathComponent("Thing.app/inner.pdf"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("thing").path,
                                  withDestinationPath: outside.appendingPathComponent("Thing.app").path)
        #expect(try FolderScanner().scan(root: root).isEmpty)
    }

    @Test func rootThatIsAFileThrowsNotADirectory() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf")
        try touch(file)
        #expect(throws: FolderScannerError.notADirectory(file)) { try FolderScanner().scan(root: file) }
    }

    @Test func honoursCancellation() async throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("a/b.pdf"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FolderScanner().scan(root: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func throwsForMissingRoot() throws {
        let root = try PDFFixtures.tempDirectory()
        try fm.removeItem(at: root)
        #expect(throws: (any Error).self) { try FolderScanner().scan(root: root) }
    }

    // MARK: Images (spec 1.2 §2)

    @Test func listsImagesWhenEnabled() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        for name in ["a.PNG", "b.jpeg", "c.heic", "d.dng", "e.tiff", "f.Jpg", "x.pdf", "sub/g.HEIC"] {
            try touch(root.appendingPathComponent(name))
        }
        let files = try FolderScanner(includeImages: true).scan(root: root)
        #expect(files.map(\.relativePath) == ["a.PNG", "b.jpeg", "c.heic", "d.dng", "f.Jpg", "sub/g.HEIC", "x.pdf"])
        #expect(files.map(\.kind) == [.image, .image, .image, .image, .image, .image, .pdf])
    }

    @Test func ignoresImagesByDefault() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        try touch(root.appendingPathComponent("a.png"))
        try touch(root.appendingPathComponent("b.pdf"))
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["b.pdf"])
    }

    @Test func kindFromExtension() {
        #expect(DocumentKind(fileExtension: "PDF") == .pdf)
        #expect(DocumentKind(fileExtension: "jpeg") == .image)
        #expect(DocumentKind(fileExtension: "DNG") == .image)
        #expect(DocumentKind(fileExtension: "tif") == nil)
        #expect(DocumentKind(fileExtension: "") == nil)
        #expect(DocumentKind.imageExtensions == ["png", "jpg", "jpeg", "heic", "dng"])
        let file = ScannedFile(relativePath: "x/Foto.JPG", url: URL(fileURLWithPath: "/tmp/x/Foto.JPG"), fileSize: 1, modifiedAt: .now)
        #expect(file.kind == .image)
    }

    @Test func ocrSettingsDefaults() {
        let settings = OCRSettings.default
        #expect(settings.recognizeText && settings.includeImages)
        #expect(settings == OCRSettings(recognizeText: true, includeImages: true))
    }
}
