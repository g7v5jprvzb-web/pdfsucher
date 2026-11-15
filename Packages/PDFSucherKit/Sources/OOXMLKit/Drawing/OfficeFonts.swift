// OfficeFonts.swift — Microsoft Office's own fonts for FontResolver, when Office is installed on this Mac.
import CoreText
import Foundation
import Synchronization

/// Which of Office's fonts PDFSucher uses (setting `OfficeFontUse.settingKey`, raw values below; default `.all`).
public enum OfficeFontUse: String, Sendable, CaseIterable {
    /// The Office apps' DFonts and Office's cloud font cache.
    case all
    /// Only the DFonts inside the Office apps (no access to Office's group container; see docs/decisions.md).
    case bundled
    /// None.
    case off

    /// UserDefaults key, read once at the lazy registration; missing or unknown value → `.all`.
    public static let settingKey = "office.officeFonts"
}

/// Where PDFSucher looks for Office's own fonts (`FontResolver.officeFontRoots`).
public struct OfficeFontRoots: Sendable, Equatable {
    /// Folder holding the Office apps (their `DFonts`); nil = none.
    public var applications: URL?
    /// Home folder whose Office group container holds the cloud font cache; nil = no cloud fonts.
    public var home: URL?

    public init(applications: URL?, home: URL?) {
        self.applications = applications
        self.home = home
    }

    /// /Applications and the user's home folder.
    public static var standard: OfficeFontRoots {
        OfficeFontRoots(applications: URL(fileURLWithPath: "/Applications"),
                        home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// No Office fonts at all.
    public static let none = OfficeFontRoots(applications: nil, home: nil)
}

/// Fonts that Microsoft Office for Mac brings along but does not install system-wide: the `DFonts` folder inside
/// each Office app (Aptos, Cambria, Garamond, Century Gothic, …) and Office's cloud font cache (Lato, Open Sans,
/// Segoe UI, Aptos Display, …, downloaded by Office when a document needs them). PowerPoint draws decks with them,
/// so SlideKit uses them too when they are there (Chris' decision, 2026-11-13).
///
/// Registration is process-scoped (`CTFontManagerRegisterFontsForURL`, `.process`): the files are only read, never
/// copied, installed or changed, and the fonts vanish when the app quits. A file is skipped when every PostScript
/// name in it is already available (a system-wide Arial or Calibri keeps being the one used; three Office apps
/// carry the same DFonts, registered once). Office's font-menu preview files (`PreviewFont`) are left out.
///
/// FontResolver registers the default folders once, lazily, before it first lists the installed families
/// (`FontResolver.installed`); the setting `office.officeFonts` (`OfficeFontUse`) picks all / bundled / off, read
/// at that moment; `PDFSUCHER_NO_OFFICE_FONTS=1` turns it off (measurements). The fonts are available to the whole
/// process (PDFKit, metafiles, any font UI), not only to SlideKit. Without Office nothing
/// changes. Must run on FontResolver's font queue (Core Text XPC, see `FontResolver.offPool`).
///
/// Discovery (`defaultDirectories`, `fontFiles`) reads only fixed places and never follows a symbolic link below
/// `/Applications` or the home folder (the home folder itself is trusted: a network or automount home that is a
/// link is followed once; everything below it is a fixed name checked with `lstat`). Core Text later opens the
/// files it found by path (`register`); that is outside `DiscoveryFS`.
enum OfficeFonts {
    /// `PDFSUCHER_TEST_OFFICE_FONTS=1`: a test process uses the real Office fonts (corpus measurements only).
    static let testOptInVariable = "PDFSUCHER_TEST_OFFICE_FONTS"
    /// Longest wait for the cloud font cache (another vendor's group container: macOS may hold the read until the
    /// user answers an access prompt).
    static let cloudTimeout: TimeInterval = 2

    /// Whether this process runs tests (XCTest or Swift Testing). Their default roots are `.none`: no test may read
    /// the real Office folders or group container (a pending macOS prompt hung the 1.3.0 test runs).
    static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: { env[$0] != nil }) {
            return true
        }
        let name = ProcessInfo.processInfo.processName
        if name == "xctest" || name.hasPrefix("swiftpm-testing-helper") { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Default roots: `.standard`, but `.none` in a test process unless `PDFSUCHER_TEST_OFFICE_FONTS=1`.
    static var defaultRoots: OfficeFontRoots {
        isTestProcess && ProcessInfo.processInfo.environment[testOptInVariable] != "1" ? .none : .standard
    }

    /// Every path any discovery with `DiscoveryFS.plain` touched in a test process (tests check that the real
    /// group container is never read); empty in the app.
    static let processLog = Mutex<[String]>([])
    static let disableVariable = "PDFSUCHER_NO_OFFICE_FONTS"
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    static let officeApps = ["Microsoft PowerPoint", "Microsoft Word", "Microsoft Excel", "Microsoft Outlook",
                             "Microsoft OneNote"]

    /// Every path the font discovery touches (lstat, directory listing), for tests: `record` sees each path before
    /// the call. Production passes `.plain`. Discovery never follows a symbolic link and never reads outside the
    /// fixed Office roots (bug 1.3.0: a prompt for ~/Downloads at launch was blamed on it; see docs/decisions.md).
    struct DiscoveryFS {
        var record: (@Sendable (String) -> Void)?
        /// Production: no recording; in a test process into `processLog`.
        static let plain: DiscoveryFS = {
            guard OfficeFonts.isTestProcess else { return DiscoveryFS(record: nil) }
            let log: @Sendable (String) -> Void = { path in OfficeFonts.processLog.withLock { $0.append(path) } }
            return DiscoveryFS(record: log)
        }()

        enum Kind { case directory, file, link, other }

        /// `lstat` (the link itself, never its target); nil if missing.
        func kind(_ path: String) -> Kind? {
            record?(path)
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: return .directory
            case S_IFREG: return .file
            case S_IFLNK: return .link
            default: return .other
            }
        }

        /// Names in a directory (readdir; entries are not followed), hidden ones left out.
        func list(_ path: String) -> [String] {
            record?(path)
            return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
    }

    /// Whether `path` is a directory below `base` reached without any symbolic link: every component after `base`
    /// is checked with `lstat`; a link anywhere (e.g. an Office app that is a link into ~/Downloads) → false, and
    /// the link is not followed.
    static func isPlainDirectory(_ path: String, below base: String, fs: DiscoveryFS) -> Bool {
        // Lexical only (`URL.standardizedFileURL`; `NSString.standardizingPath` may resolve links for "..").
        func lexical(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        let base = lexical(base), path = lexical(path)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return false }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { return false }
        var current = base.hasSuffix("/") ? String(base.dropLast()) : base
        for component in components {
            current += "/" + component
            guard fs.kind(current) == .directory else { return false }
        }
        return true
    }

    /// The Office apps' `DFonts` folders directly in `applications` (/Applications), from fixed names only (no
    /// LaunchServices, no search); a folder reached through a symbolic link is left out.
    static func appDirectories(applications: URL, fs: DiscoveryFS = .plain) -> [URL] {
        let apps = applications.standardizedFileURL.path
        return officeApps.compactMap { app in
            let dfonts = apps + "/\(app).app/Contents/Resources/DFonts"
            return isPlainDirectory(dfonts, below: apps, fs: fs) ? URL(fileURLWithPath: dfonts, isDirectory: true) : nil
        }
    }

    /// The cloud font cache folders `<home>/Library/Group Containers/UBF8T346G9.Office/FontCache/<n>/CloudFonts`
    /// (listing `FontCache` may block while macOS asks the user; see `registerDefault`).
    static func cloudDirectories(home: URL, fs: DiscoveryFS = .plain) -> [URL] {
        let homePath = home.standardizedFileURL.path
        let cache = homePath + "/Library/Group Containers/UBF8T346G9.Office/FontCache"
        guard isPlainDirectory(cache, below: homePath, fs: fs) else { return [] }
        return fs.list(cache).compactMap { version in
            let cloud = cache + "/\(version)/CloudFonts"
            return isPlainDirectory(cloud, below: cache, fs: fs) ? URL(fileURLWithPath: cloud, isDirectory: true) : nil
        }
    }

    /// Office font folders under the given roots: `appDirectories`, then, for `.all`, `cloudDirectories`
    /// (synchronously, no time limit; tests only, which pass their roots).
    static func defaultDirectories(applications: URL, home: URL, use: OfficeFontUse = .all,
                                   fs: DiscoveryFS = .plain) -> [URL] {
        guard use != .off else { return [] }
        let apps = appDirectories(applications: applications, fs: fs)
        return use == .all ? apps + cloudDirectories(home: home, fs: fs) : apps
    }

    /// Font files in `directories` and their subfolders, in order: regular files only; symbolic links (to files or
    /// folders) are skipped, not followed; no `PreviewFont` folders, no hidden files, at most `maxDepth` levels.
    static func fontFiles(in directories: [URL], fs: DiscoveryFS = .plain, maxDepth: Int = 8) -> [URL] {
        var files: [URL] = []
        func walk(_ dir: String, _ depth: Int) {
            for name in fs.list(dir) {
                let path = dir + "/" + name
                switch fs.kind(path) {
                case .directory:
                    if name != "PreviewFont", depth < maxDepth { walk(path, depth + 1) }
                case .file:
                    if fontExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        files.append(URL(fileURLWithPath: path))
                    }
                default:
                    continue // links, sockets, …: never followed
                }
            }
        }
        for dir in directories {
            let root = dir.standardizedFileURL.path
            guard fs.kind(root) == .directory else { continue } // a root that is a link is not followed
            walk(root, 0)
        }
        return files
    }

    /// Registers the fonts of `files` for this process, skipping files any of whose PostScript names is available
    /// already (a collection with one face that exists system-wide is left out whole, so no system face is
    /// shadowed or registered twice). Returns the family names that became available. Runs Core Text calls: call on the font queue.
    static func register(_ files: [URL]) -> Set<String> {
        dispatchPrecondition(condition: .onQueue(FontResolver.fontQueue))
        defer { lastRegistrationEnd.withLock { $0 = .now } }
        var known = Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        let familiesBefore = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).map { $0.lowercased() })
        // Pass 1, outside the gate (only reads the files): what is new. A later file whose names an earlier one
        // brings (the same DFonts in Word, Excel, PowerPoint) is left out.
        var candidates: [(file: URL, descriptors: [CTFontDescriptor])] = []
        for file in files {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  !descriptors.isEmpty else { continue }
            let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            guard !names.isEmpty, names.allSatisfy({ !known.contains($0) }) else { continue }
            known.formUnion(names)
            candidates.append((file, descriptors))
        }
        guard !candidates.isEmpty else { return [] }
        // Pass 2: one exclusive hold of the gate for the whole pass (no TextKit layout inside
        // `FontResolver.withStableFonts` runs meanwhile; held per file, waiting layouts would slow every file down
        // and keep the font queue blocked). Errors stay per file.
        // The hold lasts until AppKit delivered the font-set changes (see `FontGate.exclusiveFontChange`).
        var added = Set<String>()
        FontResolver.fontGate.exclusiveFontChange {
            var registered = 0
            for candidate in candidates {
                guard CTFontManagerRegisterFontsForURL(candidate.file as CFURL, .process, nil) else { continue }
                registered += 1
                for d in candidate.descriptors {
                    if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                       !familiesBefore.contains(family.lowercased()) {
                        added.insert(family)
                    }
                }
            }
            return registered
        }
        return added
    }

    private static let defaultDone = Mutex(false)

    /// Whether the once-per-process registration has started (`officeFontRoots` must be set before).
    static var defaultRegistrationStarted: Bool { defaultDone.withLock { $0 } }

    /// Registers Office's fonts from `FontResolver.officeFontRoots` once per process (unless
    /// `PDFSUCHER_NO_OFFICE_FONTS=1`), with the cloud cache limited to `cloudTimeout`. Font queue.
    static func registerDefaultOnce() {
        // The flag is set before registering: safe only because every caller runs on the serial font queue.
        dispatchPrecondition(condition: .onQueue(FontResolver.fontQueue))
        let first = defaultDone.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first, ProcessInfo.processInfo.environment[disableVariable] != "1" else { return }
        let use = UserDefaults.standard.string(forKey: OfficeFontUse.settingKey).flatMap(OfficeFontUse.init(rawValue:)) ?? .all
        let missed = Mutex(false)
        _ = registerDefault(roots: FontResolver.officeFontRoots, use: use, timeout: cloudTimeout,
                            cloudFiles: testCloudReader.withLock { $0 }, cloudMissed: { missed.withLock { $0 = true } })
        defaultMissedCloud.withLock { $0 = missed.withLock { $0 } }
    }

    /// Whether the once-per-process registration gave up on the cloud font cache (its read passed `cloudTimeout`:
    /// typically a macOS prompt not answered in time). Then this process has no cloud fonts.
    static let defaultMissedCloud = Mutex(false)

    /// Tests: replaces the cloud read of the once-per-process registration (`FontResolver.resetOfficeFontsForTests`).
    static let testCloudReader = Mutex<(@Sendable () -> [URL])?>(nil)
    /// Tests: cloud results that arrived after the time limit and were dropped.
    static let discardedLateReads = Mutex(0)
    /// Tests: when the last `register` call finished (every caller of the font list must return after it).
    static let lastRegistrationEnd = Mutex<ContinuousClock.Instant?>(nil)

    /// Tests: lets the once-per-process registration run again.
    static func resetDefaultRegistration() {
        defaultDone.withLock { $0 = false }
        defaultMissedCloud.withLock { $0 = false }
    }

    /// The cloud read's hand-over: the waiting caller takes the files; after the timeout the late result is dropped.
    private final class CloudRead: Sendable {
        enum State { case reading, done([URL]), abandoned }
        let state = Mutex(State.reading)
        let finished = DispatchSemaphore(value: 0)
    }

    /// Registers the DFonts of `roots.applications` and, for `.all`, the cloud fonts of `roots.home`, and returns the
    /// families that became available now. The cloud folders are read on a thread of their own (`cloudFiles`, for
    /// tests, replaces that read); the caller waits for it at most `timeout` from the start (the DFonts are
    /// registered meanwhile). Should it take longer (macOS holding the read for an access prompt), the caller goes
    /// on without cloud fonts, and for the rest of the process there are none: the read keeps running unwaited and
    /// its result is dropped when it arrives (cloud fonts come with the next launch). Registering later is not done
    /// on purpose: a font registration while TextKit lays out a Word document on another thread raises „attempted
    /// layout while textStorage is editing“, and index text and tiles would be laid out with different fonts. Every
    /// registration therefore happens here, inside the first build of the installed-family list, which every
    /// font-resolving caller (and Word layout, via `FontResolver.prewarm()`) waits for. The limit covers the read;
    /// registering files that arrived in time takes its usual short time after it. Fonts already available are never
    /// registered twice (`register`). Font queue.
    /// - Parameter cloudMissed: called when the cloud read is given up (past `timeout`).
    @discardableResult
    static func registerDefault(roots: OfficeFontRoots, use: OfficeFontUse, timeout: TimeInterval,
                                fs: DiscoveryFS = .plain, cloudFiles: (@Sendable () -> [URL])? = nil,
                                cloudMissed: () -> Void = {}) -> Set<String> {
        guard use != .off else { return [] }
        let start = DispatchTime.now()
        var read: CloudRead?
        if use == .all, let home = roots.home {
            let r = CloudRead()
            read = r
            let reader = cloudFiles ?? { fontFiles(in: cloudDirectories(home: home, fs: fs), fs: fs) }
            let thread = Thread {
                let files = reader()
                let late = r.state.withLock { state -> Bool in
                    if case .abandoned = state { return true }
                    state = .done(files)
                    return false
                }
                if late {
                    discardedLateReads.withLock { $0 += 1 } // dropped: no registration after the limit
                } else {
                    r.finished.signal()
                }
            }
            thread.name = "OfficeFonts.cloud"
            thread.qualityOfService = .utility
            thread.start()
        }
        var added = Set<String>()
        if let apps = roots.applications { added.formUnion(register(fontFiles(in: appDirectories(applications: apps, fs: fs), fs: fs))) }
        guard let read else { return added }
        _ = read.finished.wait(timeout: start + timeout)
        let files: [URL]? = read.state.withLock { state in
            if case .done(let files) = state { return files }
            state = .abandoned
            return nil
        }
        if let files { added.formUnion(register(files)) } else { cloudMissed() }
        return added
    }
}
