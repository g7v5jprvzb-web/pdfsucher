// OfficeFontsTests.swift — Office's own fonts registered for the process (OfficeFonts, FontResolver.registerFonts).
// No dependency on Office: the fixture font is macOS's Andale Mono renamed (same length, so no table offsets
// change) to a family nobody has installed. Note: `registerFonts` first registers Office's own fonts if Office is
// installed (once per test process; `PDFSUCHER_NO_OFFICE_FONTS=1` turns that off), which other suites then see too;
// the fixture families are unique, so no test depends on it.
import AppKit
import CoreText
import Foundation
import Synchronization
import Testing
@testable import OOXMLKit

/// A folder laid out like Office's: `DFonts/` with the renamed font, a `PreviewFont/` folder that must be skipped,
/// a non-font file. Removed when the value dies.
private final class FixtureFonts {
    static let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Andale Mono.ttf")
    let root: URL
    let family: String
    let previewFamily: String

    /// `tag`: 6 ASCII letters replacing "Andale" (family "<tag> Mono", PostScript "<tag>Mono").
    init(tag: String, previewTag: String) throws {
        precondition(tag.utf8.count == 6 && previewTag.utf8.count == 6)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("App/DFonts/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Cache/PreviewFont"), withIntermediateDirectories: true)
        let original = try Data(contentsOf: Self.source)
        try Self.renamed(original, to: tag).write(to: root.appendingPathComponent("App/DFonts/sub/fixture.ttf"))
        try Self.renamed(original, to: previewTag).write(to: root.appendingPathComponent("Cache/PreviewFont/preview.ttf"))
        try Data("kein Font".utf8).write(to: root.appendingPathComponent("App/DFonts/readme.txt"))
        family = "\(tag) Mono"
        previewFamily = "\(previewTag) Mono"
    }

    /// Unregisters what a test registered from here, then removes the files.
    deinit {
        let root = root
        FontResolver.fontGate.exclusiveFontChange {
            OfficeFonts.fontFiles(in: [root]).filter { CTFontManagerUnregisterFontsForURL($0 as CFURL, .process, nil) }.count
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Replaces "Andale" in the name table's ASCII and UTF-16BE strings.
    static func renamed(_ data: Data, to tag: String) -> Data {
        var bytes = [UInt8](data)
        func replace(_ from: [UInt8], _ to: [UInt8]) {
            var i = 0
            while i + from.count <= bytes.count {
                if Array(bytes[i..<(i + from.count)]) == from {
                    bytes.replaceSubrange(i..<(i + from.count), with: to)
                    i += from.count
                } else { i += 1 }
            }
        }
        replace(Array("Andale".utf8), Array(tag.utf8))
        replace(Array("Andale".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] },
                Array(tag.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        return Data(bytes)
    }
}

@Suite(.serialized) struct OfficeFontsTests {
    @Test func fixtureFontIsNotInstalledBeforeRegistration() throws {
        let fx = try FixtureFonts(tag: "Pdfsua", previewTag: "Pdfsub")
        let names = OfficeFonts.fontFiles(in: [fx.root]).map(\.lastPathComponent)
        #expect(names == ["fixture.ttf"]) // PreviewFont and non-fonts skipped
        let d = CTFontManagerCreateFontDescriptorsFromURL(OfficeFonts.fontFiles(in: [fx.root])[0] as CFURL) as? [CTFontDescriptor]
        #expect((d?.first).flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String } == fx.family)
        #expect(!FontResolver(theme: nil).isInstalled(fx.family))
    }

    @Test func registeredFontsAreResolvedInBothModes() throws {
        let fx = try FixtureFonts(tag: "Pdfsuc", previewTag: "Pdfsud")
        let pp = FontResolver(theme: nil, substitution: .powerPoint)
        let similar = FontResolver(theme: nil, substitution: .similar)
        #expect(pp.resolvedFamily(fx.family) != fx.family) // missing: substituted
        let added = FontResolver.registerFonts(in: [fx.root])
        #expect(added == [fx.family])
        // Resolvers made before the registration see it too (installed families are shared).
        #expect(pp.resolvedFamily(fx.family) == fx.family)
        #expect(similar.resolvedFamily(fx.family) == fx.family)
        let font = FontResolver(theme: nil).font(typeface: fx.family, size: 12, bold: false, italic: false)
        #expect(CTFontCopyFamilyName(font) as String == fx.family)
        #expect(!pp.isInstalled(fx.previewFamily)) // preview fonts are not registered
    }

    @Test func registeringAgainAddsNothing() throws {
        let fx = try FixtureFonts(tag: "Pdfsue", previewTag: "Pdfsuf")
        #expect(FontResolver.registerFonts(in: [fx.root]) == [fx.family])
        #expect(FontResolver.registerFonts(in: [fx.root]).isEmpty)
        // A second copy of the same font (as Word, Excel and PowerPoint each carry DFonts) is skipped.
        let copy = try FixtureFonts(tag: "Pdfsue", previewTag: "Pdfsug")
        #expect(FontResolver.registerFonts(in: [copy.root]).isEmpty)
    }

    @Test func installedSystemFontsAreNotRegisteredAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: FixtureFonts.source, to: dir.appendingPathComponent("Andale Mono.ttf"))
        #expect(FontResolver.registerFonts(in: [dir]).isEmpty)
    }

    @Test func defaultDirectoriesFollowOfficesLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("home")
        try fm.createDirectory(at: apps.appendingPathComponent("Microsoft Word.app/Contents/Resources/DFonts"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent("Microsoft Excel.app/Contents/Resources"),
                               withIntermediateDirectories: true) // no DFonts
        // Office in ~/Applications is not looked for (only the fixed /Applications place).
        try fm.createDirectory(at: home.appendingPathComponent("Applications/Microsoft PowerPoint.app/Contents/Resources/DFonts"),
                               withIntermediateDirectories: true)
        let cache = home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/FontCache")
        try fm.createDirectory(at: cache.appendingPathComponent("4/CloudFonts/Lato"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache.appendingPathComponent("4/PreviewFont"), withIntermediateDirectories: true)
        func paths(_ use: OfficeFontUse) -> [String] {
            OfficeFonts.defaultDirectories(applications: apps, home: home, use: use).map { $0.standardizedFileURL.path }
        }
        let word = apps.appendingPathComponent("Microsoft Word.app/Contents/Resources/DFonts").standardizedFileURL.path
        let cloud = cache.appendingPathComponent("4/CloudFonts").standardizedFileURL.path
        #expect(paths(.all) == [word, cloud])
        #expect(paths(.bundled) == [word])
        #expect(paths(.off).isEmpty)
        #expect(OfficeFonts.defaultDirectories(applications: root.appendingPathComponent("none"),
                                               home: root.appendingPathComponent("none")).isEmpty)
        #expect(OfficeFontUse(rawValue: "bundled") == .bundled && OfficeFontUse.settingKey == "office.officeFonts")
    }

    /// Bug 1.3.0 (Downloads prompt at launch): the font discovery may only touch the fixed Office roots. A fake
    /// home with Downloads/Desktop/Documents full of fonts, and symbolic links into them from every place the
    /// discovery looks at (an Office app, a DFonts entry, a DFonts subfolder, the group container, a CloudFonts
    /// entry): every path the discovery touches is recorded; none is in a user folder, links are never followed.
    @Test func discoveryNeverTouchesUserFoldersNorFollowsLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("home")
        let font = try Data(contentsOf: FixtureFonts.source)
        func write(_ rel: String, under base: URL) throws {
            let url = base.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try font.write(to: url)
        }
        func link(_ rel: String, under base: URL, to target: URL) throws {
            let url = base.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: url, withDestinationURL: target)
        }
        let userFolders = ["Downloads", "Desktop", "Documents"].map { home.appendingPathComponent($0) }
        for folder in userFolders {
            try write("evil.ttf", under: folder)
            try write("Microsoft PowerPoint.app/Contents/Resources/DFonts/evil.ttf", under: folder)
            try write("FontCache/4/CloudFonts/evil.ttf", under: folder)
        }
        let downloads = userFolders[0], desktop = userFolders[1], documents = userFolders[2]
        // Real Office places with one font each …
        try write("Microsoft Word.app/Contents/Resources/DFonts/word.ttf", under: apps)
        try write("Library/Group Containers/UBF8T346G9.Office/FontCache/4/CloudFonts/Lato/lato.ttf", under: home)
        // … and links into the user folders from each of them.
        try link("Microsoft PowerPoint.app", under: apps, to: downloads.appendingPathComponent("Microsoft PowerPoint.app"))
        try link("Microsoft Word.app/Contents/Resources/DFonts/linked.ttf", under: apps, to: desktop.appendingPathComponent("evil.ttf"))
        try link("Microsoft Word.app/Contents/Resources/DFonts/Sub", under: apps, to: documents)
        try link("Library/Group Containers/UBF8T346G9.Office/FontCache/4/CloudFonts/Linked", under: home, to: downloads)
        try link("Library/Group Containers/UBF8T346G9.Office/FontCache/5", under: home,
                 to: desktop.appendingPathComponent("FontCache/4"))

        let touched = Mutex<[String]>([])
        let fs = OfficeFonts.DiscoveryFS(record: { path in touched.withLock { $0.append(path) } })
        let dirs = OfficeFonts.defaultDirectories(applications: apps, home: home, use: .all, fs: fs)
        let files = OfficeFonts.fontFiles(in: dirs, fs: fs)

        #expect(files.map(\.lastPathComponent) == ["word.ttf", "lato.ttf"])
        let paths = touched.withLock { $0 }
        #expect(!paths.isEmpty)
        let forbidden = userFolders.map { $0.standardizedFileURL.path }
        for path in paths {
            #expect(!forbidden.contains { path == $0 || path.hasPrefix($0 + "/") }, "touched \(path)")
            let allowed = path.hasPrefix(apps.standardizedFileURL.path + "/Microsoft ")
                || path.hasPrefix(home.standardizedFileURL.path + "/Library")
            #expect(allowed, "outside the Office roots: \(path)")
        }
        // General invariant: no recorded access goes through a link. Every ancestor of a recorded path below the
        // injected root is checked here with lstat (not through the seam); none may be a symbolic link. The path
        // itself may be one (it is looked at with lstat, never followed).
        let base = root.standardizedFileURL.path
        for path in paths {
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.hasPrefix(base + "/") {
                var st = stat()
                #expect(lstat(ancestor, &st) == 0 && (st.st_mode & S_IFMT) != S_IFLNK, "\(path) goes through link \(ancestor)")
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        // The links themselves may be looked at (lstat), never what they point to.
        #expect(paths.contains(apps.appendingPathComponent("Microsoft PowerPoint.app").standardizedFileURL.path))
    }

    @Test func plainDirectoryChecksAreLexicalAndBounded() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("a/link"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        let base = root.standardizedFileURL.path
        #expect(OfficeFonts.isPlainDirectory(base + "/a/b", below: base, fs: .plain))
        #expect(!OfficeFonts.isPlainDirectory(base + "/a/link", below: base, fs: .plain))
        #expect(!OfficeFonts.isPlainDirectory(base + "/a/../elsewhere", below: base + "/a", fs: .plain))
        #expect(!OfficeFonts.isPlainDirectory(base + "/a/b", below: base + "/x", fs: .plain))
        #expect(!OfficeFonts.isPlainDirectory(base, below: base, fs: .plain))
        #expect(OfficeFonts.isPlainDirectory("/Library", below: "/", fs: .plain))
    }

    /// The same check on this Mac's real places (only with PDFSUCHER_TEST_OFFICE_FONTS=1: tests never read the real
    /// Office folders by default): whatever is installed, the discovery touches nothing under
    /// ~/Downloads, ~/Desktop or ~/Documents (nor ~/Applications) and stays in the Office roots.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_TEST_OFFICE_FONTS"] == "1"))
    func realDiscoveryStaysInOfficeRoots() {
        let touched = Mutex<[String]>([])
        let fs = OfficeFonts.DiscoveryFS(record: { path in touched.withLock { $0.append(path) } })
        _ = OfficeFonts.fontFiles(in: OfficeFonts.defaultDirectories(applications: URL(fileURLWithPath: "/Applications"),
                                                                      home: FileManager.default.homeDirectoryForCurrentUser,
                                                                      use: .all, fs: fs), fs: fs)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for path in touched.withLock({ $0 }) {
            for folder in ["Downloads", "Desktop", "Documents", "Applications"] {
                #expect(!path.hasPrefix(home + "/" + folder), "touched \(path)")
            }
            #expect(path.hasPrefix("/Applications/Microsoft ") || path.hasPrefix(home + "/Library"), "outside: \(path)")
        }
    }

    /// No test reads the real Office folders or group container: a test process defaults to `.none`, and after
    /// the lazy registration has run (prewarm) the process-wide discovery log holds no real Office path.
    @Test func testProcessNeverReadsTheRealOfficeFolders() {
        #expect(OfficeFonts.isTestProcess)
        guard ProcessInfo.processInfo.environment["PDFSUCHER_TEST_OFFICE_FONTS"] != "1" else { return }
        #expect(FontResolver.officeFontRoots == .none)
        FontResolver.prewarm()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for path in OfficeFonts.processLog.withLock({ $0 }) {
            #expect(!path.hasPrefix(home + "/Library/Group Containers"), "read \(path)")
            #expect(!path.hasPrefix("/Applications/Microsoft"), "read \(path)")
        }
    }

    /// A folder laid out like /Applications with one Office app whose DFonts holds the renamed fixture font.
    private static func fakeApplications(tag: String) throws -> (root: URL, family: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        let dfonts = root.appendingPathComponent("Microsoft Word.app/Contents/Resources/DFonts")
        try FileManager.default.createDirectory(at: dfonts, withIntermediateDirectories: true)
        try FixtureFonts.renamed(try Data(contentsOf: FixtureFonts.source), to: tag).write(to: dfonts.appendingPathComponent("a.ttf"))
        return (root, "\(tag) Mono")
    }

    /// The cloud read blocks (macOS holding it for a prompt): the caller goes on after the time limit with the
    /// DFonts registered; the cloud result that arrives later is dropped (no registration after the limit: TextKit
    /// may be laying out text then), so the cloud font stays unavailable for this process.
    @Test func blockedCloudReadIsDroppedAndRegistersNothingLate() async throws {
        let apps = try Self.fakeApplications(tag: "Pdfsur")
        let cloud = try FixtureFonts(tag: "Pdfsus", previewTag: "Pdfsut")
        defer { try? FileManager.default.removeItem(at: apps.root); withExtendedLifetime(cloud) {} }
        let cloudFile = OfficeFonts.fontFiles(in: [cloud.root])
        let arrived = Mutex(false)
        let dropped = OfficeFonts.discardedLateReads.withLock { $0 }
        let start = ContinuousClock.now
        let added = FontResolver.registerOfficeFonts(
            roots: OfficeFontRoots(applications: apps.root, home: URL(fileURLWithPath: "/nonexistent")),
            timeout: 2, cloudFiles: { Thread.sleep(forTimeInterval: 3); arrived.withLock { $0 = true }; return cloudFile })
        let waited = ContinuousClock.now - start
        // 2 s limit + headroom for queue wait and load from suites running in parallel.
        #expect(waited < .milliseconds(2500), "caller waited \(waited)")
        #expect(waited >= .milliseconds(1900))
        #expect(added == [apps.family]) // DFonts at once
        #expect(FontResolver(theme: nil).isInstalled(apps.family))
        // The read finishes later: dropped, nothing registered.
        let deadline = ContinuousClock.now + .seconds(5)
        while !arrived.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(arrived.withLock { $0 })
        #expect(OfficeFonts.discardedLateReads.withLock { $0 } == dropped + 1)
        #expect(!FontResolver(theme: nil).isInstalled(cloud.family))
        // Straight from Core Text too (not only FontResolver's cached list).
        let available = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        #expect(!available.contains(cloud.family))
    }

    /// The real once-per-process path (inside the first build of the installed-family list), with injected roots
    /// and a slow fake cloud read: every font-resolving caller started meanwhile waits for the registration and
    /// returns only after it finished, with the registered font found. So no registration overlaps layout.
    @Test func callersReturnOnlyAfterTheRegistrationFinished() throws {
        let apps = try Self.fakeApplications(tag: "Pdfsux")
        let cloud = try FixtureFonts(tag: "Pdfsuy", previewTag: "Pdfsuz")
        let readerStarted = Mutex<ContinuousClock.Instant?>(nil)
        var previous: OfficeFontRoots?
        defer {
            // Back to the previous roots (nil = default, e.g. the opt-in for corpus runs); the once-path runs again
            // with them at the next use.
            FontResolver.resetOfficeFontsForTests(roots: previous, cloudFiles: nil)
            try? FileManager.default.removeItem(at: apps.root)
            withExtendedLifetime(cloud) {}
        }
        let cloudFile = OfficeFonts.fontFiles(in: [cloud.root])
        previous = FontResolver.resetOfficeFontsForTests(
            roots: OfficeFontRoots(applications: apps.root, home: URL(fileURLWithPath: "/nonexistent")),
            cloudFiles: { readerStarted.withLock { $0 = .now }; Thread.sleep(forTimeInterval: 0.6); return cloudFile })
        let results = Mutex<[(family: String, started: ContinuousClock.Instant, returned: ContinuousClock.Instant)]>([])
        let group = DispatchGroup()
        let appFamily = apps.family, cloudFamily = cloud.family
        for i in 0..<12 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let started = ContinuousClock.now
                let r = FontResolver(theme: nil)
                let name = i.isMultiple(of: 2) ? cloudFamily : appFamily
                if i % 3 == 0 { FontResolver.prewarm() }
                let family = r.resolvedFamily(name)
                _ = r.font(typeface: name, size: 12, bold: false, italic: false)
                results.withLock { $0.append((family == name ? name : "substitute:\(family)", started, .now)) }
            }
        }
        #expect(group.wait(timeout: .now() + 10) == .success)
        let end = try #require(OfficeFonts.lastRegistrationEnd.withLock { $0 })
        for result in results.withLock({ $0 }) {
            #expect(!result.family.hasPrefix("substitute"), "resolved before the registration: \(result.family)")
            #expect(result.returned >= end, "a caller returned before the registration finished")
        }
        #expect(results.withLock { $0.count } == 12)
        // The callers really overlapped the registration (else the checks above would be trivial).
        #expect(results.withLock { $0 }.contains { $0.started < end }, "no caller started before the registration ended")
        #expect(readerStarted.withLock { $0 } != nil)
    }

    /// office-speed: display paths (`withoutWaitingForRegistration`) resolve during a slow registration without
    /// waiting for it, with substitutes and without remembering anything; afterwards every caller gets the registered
    /// font. A caller that waits (layout, output) still waits.
    @Test func displayLookupsDoNotWaitForTheRegistration() throws {
        let apps = try Self.fakeApplications(tag: "Pdfsra")
        let cloud = try FixtureFonts(tag: "Pdfsrb", previewTag: "Pdfsrc")
        var previous: OfficeFontRoots?
        defer {
            FontResolver.resetOfficeFontsForTests(roots: previous, cloudFiles: nil)
            try? FileManager.default.removeItem(at: apps.root)
            withExtendedLifetime(cloud) {}
        }
        let cloudFile = OfficeFonts.fontFiles(in: [cloud.root])
        let readerStarted = DispatchSemaphore(value: 0)
        previous = FontResolver.resetOfficeFontsForTests(
            roots: OfficeFontRoots(applications: apps.root, home: URL(fileURLWithPath: "/nonexistent")),
            cloudFiles: { readerStarted.signal(); Thread.sleep(forTimeInterval: 0.8); return cloudFile })
        let registered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { FontResolver.prewarm(); registered.signal() }
        #expect(readerStarted.wait(timeout: .now() + 5) == .success)
        #expect(!FontResolver.officeFontsReady)
        let started = ContinuousClock.now
        let cloudFamily = cloud.family
        let early = FontResolver.withoutWaitingForRegistration { () -> String in
            let r = FontResolver(theme: nil)
            _ = r.font(typeface: cloudFamily, size: 12, bold: false, italic: false)
            return r.resolvedFamily(cloudFamily)
        }
        let waited = ContinuousClock.now - started
        #expect(waited < .milliseconds(400), "a display lookup waited \(waited)")
        #expect(early != cloudFamily, "the cloud font is not there before its registration")
        #expect(!FontResolver.officeFontsReady)
        #expect(registered.wait(timeout: .now() + 10) == .success)
        #expect(FontResolver.officeFontsReady)
        // Nothing provisional was kept: the same name resolves to the registered font now, waiting or not.
        #expect(FontResolver(theme: nil).resolvedFamily(cloudFamily) == cloudFamily)
        #expect(FontResolver.withoutWaitingForRegistration { FontResolver(theme: nil).resolvedFamily(cloudFamily) } == cloudFamily)
    }

    /// The cloud read given up after the limit is reported (`cloudMissed`; the once-per-process path stores it as
    /// `FontResolver.officeFontsIncomplete`). Fake reader, no real fonts, no group container.
    @Test func missedCloudReadIsReported() {
        let missed = Mutex(0)
        let dropped = OfficeFonts.discardedLateReads.withLock { $0 }
        _ = FontResolver.registerOfficeFonts(roots: OfficeFontRoots(applications: nil, home: URL(fileURLWithPath: "/nonexistent")),
                                        use: .all, timeout: 0.2,
                                        cloudFiles: { Thread.sleep(forTimeInterval: 0.6); return [] },
                                        cloudMissed: { missed.withLock { $0 += 1 } })
        #expect(missed.withLock { $0 } == 1)
        // The late read ends after this call; wait for it, so it is not counted by another test's
        // `discardedLateReads` check.
        let deadline = Date().addingTimeInterval(5)
        while OfficeFonts.discardedLateReads.withLock({ $0 }) < dropped + 1, Date() < deadline { usleep(10_000) }
        #expect(OfficeFonts.discardedLateReads.withLock { $0 } == dropped + 1)
        _ = FontResolver.registerOfficeFonts(roots: OfficeFontRoots(applications: nil, home: URL(fileURLWithPath: "/nonexistent")),
                                        use: .all, timeout: 2, cloudFiles: { [] },
                                        cloudMissed: { missed.withLock { $0 += 1 } })
        #expect(missed.withLock { $0 } == 1, "a read in time is not missed")
    }

    /// Resetting the once-per-process registration (tests) forgets a missed cloud read too.
    @Test func resetForgetsTheMissedCloudRead() {
        OfficeFonts.defaultMissedCloud.withLock { $0 = true }
        #expect(FontResolver.officeFontsIncomplete)
        let previous = FontResolver.resetOfficeFontsForTests(roots: .none, cloudFiles: nil)
        #expect(!FontResolver.officeFontsIncomplete)
        FontResolver.resetOfficeFontsForTests(roots: previous, cloudFiles: nil)
    }

    /// One registration pass holds the gate exclusively once, however many files it registers (held per file,
    /// waiting layouts would slow each file down and keep the font queue blocked).
    @Test func oneExclusiveGateHoldPerRegistrationPass() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            FontResolver.fontGate.exclusiveFontChange {
                OfficeFonts.fontFiles(in: [root]).filter { CTFontManagerUnregisterFontsForURL($0 as CFURL, .process, nil) }.count
            }
            try? fm.removeItem(at: root)
        }
        let source = try Data(contentsOf: FixtureFonts.source)
        for tag in ["Pdfsvc", "Pdfsvd", "Pdfsve"] {
            try FixtureFonts.renamed(source, to: tag).write(to: root.appendingPathComponent("\(tag).ttf"))
        }
        let before = FontResolver.fontGate.exclusiveAcquisitions
        #expect(FontResolver.registerFonts(in: [root]) == ["Pdfsvc Mono", "Pdfsvd Mono", "Pdfsve Mono"])
        #expect(FontResolver.fontGate.exclusiveAcquisitions - before == 1)
        // Nothing new: no exclusive hold at all.
        #expect(FontResolver.registerFonts(in: [root]).isEmpty)
        #expect(FontResolver.fontGate.exclusiveAcquisitions - before == 1)
    }

    /// AppKit posts one NSFontSetChanged per registered file, later, on the main thread; TextKit then calls
    /// `-fontSetChanged` on every live text storage there, also on one a background thread is laying out inside the
    /// gate (measured: ~350 such overlaps per probe run without this, 0 with it). So a registration keeps the gate
    /// until those notifications have been delivered: when `registerFonts` returns, all of them have arrived.
    @Test func registrationHoldsTheGateUntilAppKitDeliveredTheFontSetChanges() async throws {
        _ = NSTextStorage(string: "TextKit loaded") // as in the app: AppKit's text system observes font-set changes
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            FontResolver.fontGate.exclusiveFontChange {
                OfficeFonts.fontFiles(in: [root]).filter { CTFontManagerUnregisterFontsForURL($0 as CFURL, .process, nil) }.count
            }
            try? fm.removeItem(at: root)
        }
        let source = try Data(contentsOf: FixtureFonts.source)
        for tag in ["Pdfsvf", "Pdfsvg", "Pdfsvh", "Pdfsvi"] {
            try FixtureFonts.renamed(source, to: tag).write(to: root.appendingPathComponent("\(tag).ttf"))
        }
        let delivered = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: Notification.Name("NSFontSetChangedNotification"),
                                                           object: nil, queue: nil) { _ in delivered.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        // Other suites may keep the main thread busy for a while: a long limit, so only a missing wait fails.
        let previousLimit = FontResolver.FontGate.defaultDeliveryTimeout.withLock { l -> TimeInterval in let o = l; l = 10; return o }
        defer { FontResolver.FontGate.defaultDeliveryTimeout.withLock { $0 = previousLimit } }
        let timeouts = FontResolver.fontGate.deliveryTimeouts
        // Count at the moment the hold ends (when layout may run again), not later.
        let atRelease = Mutex<Int?>(nil)
        FontResolver.fontGate.beforeRelease.withLock { $0 = { atRelease.withLock { $0 = delivered.withLock { $0 } } } }
        defer { FontResolver.fontGate.beforeRelease.withLock { $0 = nil } }
        let added = await Task.detached { FontResolver.registerFonts(in: [root]) }.value
        FontResolver.fontGate.beforeRelease.withLock { $0 = nil }
        #expect(added.count == 4)
        let count = try #require(atRelease.withLock { $0 })
        #expect(count >= 4, "only \(count) of 4 font-set changes delivered when the hold ended")
        #expect(FontResolver.fontGate.deliveryTimeouts == timeouts)
    }

    /// The font gate: a registration waits while text layout holds `withStableFonts`.
    @Test func registrationWaitsForLayoutInsideTheGate() throws {
        let fx = try FixtureFonts(tag: "Pdfsva", previewTag: "Pdfsvb")
        try withExtendedLifetime(fx) {
            let entered = DispatchSemaphore(value: 0)
            let released = Mutex<ContinuousClock.Instant?>(nil)
            let registered = Mutex<ContinuousClock.Instant?>(nil)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                FontResolver.withStableFonts {
                    entered.signal()
                    Thread.sleep(forTimeInterval: 0.5)
                    released.withLock { $0 = .now }
                }
            }
            entered.wait()
            let root = fx.root
            DispatchQueue.global().async(group: group) {
                FontResolver.registerFonts(in: [root])
                registered.withLock { $0 = .now }
            }
            #expect(group.wait(timeout: .now() + 10) == .success)
            let r = try #require(released.withLock { $0 }), g = try #require(registered.withLock { $0 })
            #expect(g >= r, "the registration finished while layout held the gate")
            #expect(FontResolver(theme: nil).isInstalled(fx.family))
        }
    }

    @Test func cloudReadInTimeIsRegisteredAtOnce() throws {
        let cloud = try FixtureFonts(tag: "Pdfsuv", previewTag: "Pdfsuw")
        withExtendedLifetime(cloud) {
            let files = OfficeFonts.fontFiles(in: [cloud.root])
            let start = ContinuousClock.now
            let added = FontResolver.registerOfficeFonts(
                roots: OfficeFontRoots(applications: nil, home: URL(fileURLWithPath: "/nonexistent")),
                timeout: 2, cloudFiles: { Thread.sleep(forTimeInterval: 0.2); return files })
            #expect(ContinuousClock.now - start < .milliseconds(2000)) // 0.2 s read + registration + parallel-suite load
            #expect(added == [cloud.family])
            #expect(FontResolver(theme: nil).isInstalled(cloud.family))
        }
    }

    @Test func bundledAndOffSkipTheCloudRead() {
        let reads = Mutex(0)
        let reader: @Sendable () -> [URL] = { reads.withLock { $0 += 1 }; return [] }
        let roots = OfficeFontRoots(applications: nil, home: URL(fileURLWithPath: "/nonexistent"))
        FontResolver.registerOfficeFonts(roots: roots, use: .bundled, timeout: 2, cloudFiles: reader)
        FontResolver.registerOfficeFonts(roots: roots, use: .off, timeout: 2, cloudFiles: reader)
        FontResolver.registerOfficeFonts(roots: .none, use: .all, timeout: 2, cloudFiles: reader)
        #expect(reads.withLock { $0 } == 0)
    }

    /// A font that is only a link (into a user folder) is not registered.
    @Test func linkedFontIsNotRegistered() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads"), dfonts = root.appendingPathComponent("DFonts")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: dfonts, withIntermediateDirectories: true)
        let real = downloads.appendingPathComponent("linked.ttf")
        try FixtureFonts.renamed(try Data(contentsOf: FixtureFonts.source), to: "Pdfsuq").write(to: real)
        try fm.createSymbolicLink(at: dfonts.appendingPathComponent("linked.ttf"), withDestinationURL: real)
        #expect(FontResolver.registerFonts(in: [dfonts]).isEmpty)
        #expect(!FontResolver(theme: nil).isInstalled("Pdfsuq Mono"))
    }

    /// A run naming a face by its full name ("Aptos Display": family Aptos, style Display) gets that face.
    @Test func faceFullNameGetsThatFace() throws {
        let fx = try FixtureFonts(tag: "Pdfsuk", previewTag: "Pdfsul")
        withExtendedLifetime(fx) {
            let r = FontResolver(theme: nil, substitution: .powerPoint)
            #expect(r.resolvedFamily("Pdfsuk Mono Regular") != "Pdfsuk Mono") // not there yet
            FontResolver.registerFonts(in: [fx.root])
            for name in ["Pdfsuk Mono Regular", "PdfsukMono", "pdfsuk mono regular"] {
                #expect(r.resolvedFamily(name) == "Pdfsuk Mono", "\(name)")
                let f = r.font(typeface: name, size: 12, bold: false, italic: false)
                #expect(CTFontCopyPostScriptName(f) as String == "PdfsukMono", "\(name)")
            }
            // Installed system faces by full name keep resolving to their face.
            let medium = r.font(typeface: "Helvetica Neue Medium", size: 12, bold: false, italic: false)
            #expect(CTFontCopyPostScriptName(medium) as String == "HelveticaNeue-Medium")
        }
    }

    /// Office's cloud "Aptos Display" belongs to family "Aptos" (style "Display"); a run naming "Aptos" must get
    /// the regular face, not whatever face Core Text lists first.
    @Test func plainFamilyNameGetsTheRegularFaceNotADisplayFace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("officefonts-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Two faces of one family: "Pdfsuj Mono" Regular (Andale Mono renamed) and a "Display" face of the same
        // family (the Regular renamed once more: style "Regular" → "Display", PostScript name changed).
        let regular = FixtureFonts.renamed(try Data(contentsOf: FixtureFonts.source), to: "Pdfsuj")
        var display = [UInt8](regular)
        func swap(_ from: String, _ to: String) {
            for (a, b) in [(Array(from.utf8), Array(to.utf8)),
                           (Array(from.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] },
                            Array(to.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })] {
                var i = 0
                while i + a.count <= display.count {
                    if Array(display[i..<(i + a.count)]) == a { display.replaceSubrange(i..<(i + a.count), with: b); i += a.count }
                    else { i += 1 }
                }
            }
        }
        swap("Regular", "Display")
        swap("PdfsujMono", "PdfsujMonD")
        try Data(display).write(to: root.appendingPathComponent("a-display.ttf"))
        try regular.write(to: root.appendingPathComponent("b-regular.ttf"))
        #expect(FontResolver.registerFonts(in: [root]) == ["Pdfsuj Mono"])
        let font = FontResolver(theme: nil).font(typeface: "Pdfsuj Mono", size: 12, bold: false, italic: false)
        #expect(CTFontCopyPostScriptName(font) as String == "PdfsujMono")
    }

    @Test func prewarmIsIdempotentAndThreadSafe() async throws {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { FontResolver.prewarm() } }
        }
        #expect(FontResolver.isPrewarmed)
        let builds = FontResolver.installedBuilds
        FontResolver.prewarm()
        #expect(FontResolver.installedBuilds == builds) // done: no new build
        #expect(FontResolver.isPrewarmed)
        #expect(FontResolver(theme: nil).isInstalled("Helvetica Neue"))
        // A later registration still reaches resolvers (the list is rebuilt lazily after it).
        let fx = try FixtureFonts(tag: "Pdfsum", previewTag: "Pdfsun")
        withExtendedLifetime(fx) {
            #expect(FontResolver.registerFonts(in: [fx.root]) == [fx.family])
            // (Not asserting the list is dropped here: parallel suites may rebuild it at once.)
            FontResolver.prewarm()
            #expect(FontResolver.isPrewarmed)
            #expect(FontResolver(theme: nil).resolvedFamily(fx.family) == fx.family)
        }
    }

    /// Concurrent first callers after a registration (the list dropped) build it once, not once each.
    @Test func concurrentFirstCallersBuildTheListOnce() async throws {
        let fx = try FixtureFonts(tag: "Pdfsuo", previewTag: "Pdfsup")
        defer { withExtendedLifetime(fx) {} }
        FontResolver.registerFonts(in: [fx.root])
        let before = FontResolver.installedBuilds
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<16 { DispatchQueue.global(qos: .utility).async(group: group) { FontResolver.prewarm() } }
            group.notify(queue: .global()) { done.resume() }
        }
        // Parallel suites may also have triggered a rebuild after the registration; never one per caller.
        #expect(FontResolver.installedBuilds - before <= 2)
        #expect(FontResolver(theme: nil).isInstalled(fx.family))
    }

    @Test func concurrentResolutionDuringRegistrationIsSafe() async throws {
        let fx = try FixtureFonts(tag: "Pdfsuh", previewTag: "Pdfsui")
        let family = fx.family, root = fx.root
        defer { withExtendedLifetime(fx) {} }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    if i == 10 { FontResolver.registerFonts(in: [root]) }
                    _ = FontResolver(theme: nil).font(typeface: i.isMultiple(of: 2) ? family : "Helvetica Neue",
                                                      size: CGFloat(10 + i % 7), bold: false, italic: false)
                }
            }
        }
        #expect(FontResolver(theme: nil).resolvedFamily(family) == family)
    }
}
