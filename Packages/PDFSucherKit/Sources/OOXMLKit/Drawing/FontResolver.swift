// FontResolver.swift — Task 5 (OOXMLKit)
// Maps DrawingML typefaces (incl. theme shorthands) to installed CTFonts, with a documented
// substitution table for fonts a Mac does not have (rationale: docs/decisions.md).
import Foundation
import CoreText
import CoreGraphics
import Synchronization

public enum Script: Sendable { case latin, eastAsian, complexScript }

/// What `FontResolver` does with a typeface that is not installed (see docs/decisions.md, FontResolver).
public enum FontSubstitution: String, Sendable, CaseIterable {
    /// Like PowerPoint for Mac (measured against its PDF exports): a missing font is drawn in the Office
    /// default face Calibri (Arial if Calibri is not installed), regular, bold/italic from the run, no weight
    /// or width taken from the name. Fonts Office ships itself (Aptos, Lato, Cambria, Consolas, …) and CJK and
    /// symbol fonts keep the look-alike table, because PowerPoint draws those in their own face. Latin runs only
    /// (East Asian and complex-script runs keep the table). Default.
    case powerPoint
    /// The look-alike table: the closest-looking macOS font, weight/width words in the name applied.
    case similar
}

public final class FontResolver: Sendable {
    private let theme: Theme
    public let substitution: FontSubstitution

    private struct Key: Hashable {
        var family: String
        /// PostScript name of the exact face a name asked for ("Aptos Display"), nil = the family's face.
        var face: String?
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        var weight: CGFloat?
        var width: CGFloat?
    }

    // CTFont is an immutable, thread-safe CF object (Apple: "Core Text is thread-safe, font objects are
    // immutable"), but it is not annotated Sendable, so it is stored through this box.
    private struct FontBox: @unchecked Sendable { let font: CTFont }

    private let cache = Mutex<[Key: FontBox]>([:])
    private static let cacheLimit = 4096

    /// `theme` nil → Calibri Light / Calibri as theme fonts.
    public init(theme: Theme?, substitution: FontSubstitution = .powerPoint) {
        self.theme = theme ?? .fallback
        self.substitution = substitution
    }

    // MARK: off-pool execution

    static let fontQueue = DispatchQueue(label: "OOXMLKit.FontResolver", qos: .userInitiated)

    private final class ResultBox<T: Sendable>: @unchecked Sendable { var value: T? }

    /// Runs `work` on a dedicated dispatch thread and waits for it (cache misses only).
    ///
    /// Why: Core Text asks fontd over synchronous XPC. Calling that directly from many Swift-concurrency
    /// tasks at once hangs reproducibly (200-task TaskGroup, 16 cores: all 16 cooperative threads sit in
    /// `dispatch_mach_send_with_result_and_wait_for_reply`, one idle workqueue thread, no progress; same
    /// with creation serialized under a lock, so one in-flight request is not enough). Root cause not
    /// proven; evidence points at the XPC reply needing a thread that the saturated cooperative pool does
    /// not leave free. Running the call on a plain GCD queue avoids it (200-task test passes).
    /// `work` must never call back into `offPool` (it would deadlock on the serial queue).
    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(fontQueue))
        dispatchPrecondition(condition: .notOnQueue(provisionalQueue))
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        // A caller that does not wait for Office's registration (`withoutWaitingForRegistration`) must not queue
        // behind it on the font queue: its own queue, marked the same way for the work.
        if notWaiting {
            provisionalQueue.async {
                box.value = withoutWaitingForRegistration(work)
                done.signal()
            }
        } else {
            fontQueue.async {
                box.value = work()
                done.signal()
            }
        }
        done.wait()
        return box.value!  // set before signal; never nil here (not file data)
    }

    // MARK: installed families

    /// lowercase → real family name. Built on first use, after Office's own fonts were registered for this process
    /// (`OfficeFonts`, if Office is installed); rebuilt after `registerFonts(in:)`. Fonts installed system-wide while
    /// running are not tracked. `generation` keeps a map built before a registration from being stored after it.
    private struct InstalledState {
        var map: [String: String]?
        /// Families before the registration, for callers that do not wait for it (`withoutWaitingForRegistration`).
        var provisional: [String: String]?
        var generation = 0
        /// How often the list was built (tests).
        var builds = 0
    }
    private static let installedState = Mutex(InstalledState())

    private static var installed: [String: String] {
        if let cached = installedState.withLock({ $0.map }) { return cached }
        if notWaiting { return provisionalFamilies }
        return registeredFamilies
    }

    /// The list after Office's registration (which runs here once, on the font queue).
    private static var registeredFamilies: [String: String] {
        if let cached = installedState.withLock({ $0.map }) { return cached }
        // Built and stored on the serial font queue: concurrent first callers queue up behind the first and then
        // find its list instead of building their own.
        return offPool {
            OfficeFonts.registerDefaultOnce()
            let generation = installedState.withLock { $0.generation }
            if let cached = installedState.withLock({ $0.map }) { return cached }
            let map = availableFamilies()
            let hadProvisional = installedState.withLock { state -> Bool in
                state.builds += 1
                if state.generation == generation, state.map == nil { state.map = map }
                defer { state.provisional = nil }
                return state.provisional != nil
            }
            // Lookups of the time before are not kept (they were not stored), but be safe: start the memos over.
            if hadProvisional { memos.withLock { $0 = Memos(generation: $0.generation &+ 1) } }
            return map
        }
    }

    /// The families installed now, without Office's registration (substitutes until it is done); built once on the
    /// provisional queue and dropped when the registered list is built.
    private static var provisionalFamilies: [String: String] {
        if let cached = installedState.withLock({ $0.provisional }) { return cached }
        return offPool {
            if let cached = installedState.withLock({ $0.provisional }) { return cached }
            let map = availableFamilies()
            installedState.withLock { if $0.map == nil { $0.provisional = map } }
            return map
        }
    }

    // MARK: not waiting for the registration (office-speed)

    static let provisionalQueue = DispatchQueue(label: "OOXMLKit.FontResolver.provisional", qos: .userInitiated)
    private static let notWaitingKey = "OOXMLKit.FontResolver.notWaiting"

    /// Runs `body` on this thread so that font resolution does not wait for Office's font registration: until the
    /// registered list exists (`officeFontsReady`), fonts resolve against what is installed now (Office's fonts
    /// drawn with substitutes) and nothing is registered or remembered process-wide. For display paths (tiles, the
    /// preview) that are drawn again once the fonts are there; layout and output must wait (`prewarm()`).
    public static func withoutWaitingForRegistration<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[notWaitingKey]
        dictionary[notWaitingKey] = true
        defer { dictionary[notWaitingKey] = previous }
        return try body()
    }

    /// Whether this thread resolves without waiting and the registered list is not built yet.
    private static var notWaiting: Bool {
        Thread.current.threadDictionary[notWaitingKey] != nil && installedState.withLock { $0.map == nil }
    }

    /// Whether Office's registration has finished and the installed-family list after it is built (then no font
    /// resolution waits any more). Does not wait.
    public static var officeFontsReady: Bool { installedState.withLock { $0.map != nil } }

    /// Per-name lookups that depend on the installed fonts; emptied by `fontsChanged()`. `generation` keeps a
    /// lookup made before a registration (tests: `registerFonts(in:)`) from being stored after it.
    private struct Memos {
        var generation = 0
        /// lowercased requested name → exact face (nil = no face of that name).
        var face: [String: Face?] = [:]
        /// lowercased family → PostScript name of its regular-style face (nil = none), see `regularFace`.
        var regularFace: [String: String?] = [:]
    }
    private struct Face: Sendable { let family: String; let postScript: String }
    private static let memos = Mutex(Memos())

    /// The installed face whose full or PostScript name is `name` (case, spaces and hyphens ignored), e.g.
    /// "Aptos Display" → (Aptos, AptosDisplay). Memoized per name.
    private static func installedFace(_ name: String) -> Face? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        let (cached, generation) = memos.withLock { ($0.face[key], $0.generation) }
        if let known = cached { return known }
        let found: Face? = offPool {
            func norm(_ s: String) -> String { s.lowercased().filter { $0 != " " && $0 != "-" } }
            let font = CTFontCreateWithName(key as CFString, 12, nil)
            let full = CTFontCopyFullName(font) as String, ps = CTFontCopyPostScriptName(font) as String
            guard norm(full) == norm(key) || norm(ps) == norm(key) else { return nil }
            return Face(family: CTFontCopyFamilyName(font) as String, postScript: ps)
        }
        if !notWaiting { memos.withLock { if $0.generation == generation { $0.face[key] = .some(found) } } }
        return found
    }

    /// Font queue only.
    private static func availableFamilies() -> [String: String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        var map: [String: String] = [:]
        for n in names where !n.hasPrefix(".") { map[n.lowercased()] = map[n.lowercased()] ?? n }
        return map
    }

    /// Registers the font files in `directories` (and subfolders) for this process, like Office's own fonts
    /// (`OfficeFonts`: read in place, files whose fonts are all available already skipped), and makes them visible
    /// to every resolver from now on (fonts a resolver has already created stay cached in it). Returns the family
    /// names that became available. Office's folders are registered automatically; this is for other folders
    /// (and tests).
    /// Internal (tests): a registration at any other moment could run while TextKit lays out text on another thread.
    @discardableResult
    static func registerFonts(in directories: [URL]) -> Set<String> {
        let added = offPool {
            OfficeFonts.registerDefaultOnce()
            return OfficeFonts.register(OfficeFonts.fontFiles(in: directories))
        }
        fontsChanged()
        return added
    }

    /// Drops the installed-family list and the name lookups after fonts were registered (rebuilt on next use).
    static func fontsChanged() {
        installedState.withLock { state in
            state.map = nil
            state.provisional = nil
            state.generation += 1
        }
        memos.withLock { $0 = Memos(generation: $0.generation &+ 1) }
    }

    private static let roots = Mutex<OfficeFontRoots?>(nil)

    /// Where Office's own fonts are looked for: `.standard` (/Applications and the user's home), but `.none` in a
    /// test process (XCTest / Swift Testing) unless `PDFSUCHER_TEST_OFFICE_FONTS=1`, so tests never read the real
    /// Office folders or group container. Set it before the first font resolution (e.g. `.none` for UI-test runs of
    /// the app): the registration happens once, so a later change has no effect (asserted in debug builds).
    public static var officeFontRoots: OfficeFontRoots {
        get { roots.withLock { $0 } ?? OfficeFonts.defaultRoots }
        set {
            assert(!OfficeFonts.defaultRegistrationStarted, "officeFontRoots set after the Office fonts were registered")
            roots.withLock { $0 = newValue }
        }
    }

    /// Runs `OfficeFonts.registerDefault` on the font queue (tests: injected roots and a fake cloud reader).
    @discardableResult
    static func registerOfficeFonts(roots: OfficeFontRoots, use: OfficeFontUse = .all, timeout: TimeInterval,
                                    cloudFiles: (@Sendable () -> [URL])? = nil,
                                    cloudMissed: @escaping @Sendable () -> Void = {}) -> Set<String> {
        let added = offPool {
            OfficeFonts.registerDefault(roots: roots, use: use, timeout: timeout, cloudFiles: cloudFiles, cloudMissed: cloudMissed)
        }
        fontsChanged()
        return added
    }

    /// Tests: makes the once-per-process Office registration run again, inside the next build of the
    /// installed-family list, with `roots` and a fake cloud read (nil = real read of `roots.home`).
    /// Returns the previous override (nil = default roots) to restore it.
    @discardableResult
    static func resetOfficeFontsForTests(roots newRoots: OfficeFontRoots?, cloudFiles: (@Sendable () -> [URL])?) -> OfficeFontRoots? {
        let previous = roots.withLock { r -> OfficeFontRoots? in let old = r; r = newRoots; return old }
        OfficeFonts.testCloudReader.withLock { $0 = cloudFiles }
        OfficeFonts.resetDefaultRegistration()
        fontsChanged()
        return previous
    }

    /// Readers-writer lock between text layout and font registration (process-wide): TextKit raises „attempted
    /// layout while textStorage is editing“ when fonts are registered while it lays out on another thread.
    final class FontGate: @unchecked Sendable {
        private let lock: UnsafeMutablePointer<pthread_rwlock_t> = {
            let p = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
            p.initialize(to: pthread_rwlock_t())
            precondition(pthread_rwlock_init(p, nil) == 0, "FontGate: pthread_rwlock_init failed")
            return p
        }()
        func shared<T>(_ body: () throws -> T) rethrows -> T {
            // A failure (e.g. EDEADLK: the thread holds the write lock) must not go on to unlock a lock it lacks.
            precondition(pthread_rwlock_rdlock(lock) == 0, "FontGate: shared lock failed (nested inside a registration?)")
            defer { pthread_rwlock_unlock(lock) }
            return try body()
        }
        /// Font-change holds that ended at the time limit before all deliveries were seen (tests).
        private let timeouts = Mutex(0)
        var deliveryTimeouts: Int { timeouts.withLock { $0 } }

        /// Tests: called at the end of each font-change hold, just before it is released.
        let beforeRelease = Mutex<(@Sendable () -> Void)?>(nil)
        /// Default limit of the wait for deliveries (tests raise it while the main thread may be busy).
        static let defaultDeliveryTimeout = Mutex<TimeInterval>(0.5)

        /// An exclusive hold for a font change (registration or unregistration). `body` changes the fonts and returns
        /// how many files it registered or unregistered; the hold then lasts until AppKit has delivered that many
        /// `NSFontSetChangedNotification`s, at most `deliveryTimeout` (default `defaultDeliveryTimeout`). Why: AppKit
        /// posts one per file, later, on the main thread, and TextKit (`+[NSTextStorage _fontSetChanged:]`) then
        /// calls `-fontSetChanged` on every live text storage there, also on one a background thread is laying out
        /// inside `withStableFonts`; measured ~350 such overlaps per probe run, the rare „attempted layout while
        /// textStorage is editing“. Held until delivery, there are none. No wait when TextKit is not loaded (nobody
        /// listens), on the main thread (it delivers them), or for nothing changed. If the main thread is busy (e.g.
        /// blocked on the font queue, which waits for this registration) the limit ends the wait — up to the limit
        /// extra per pass — and that delivery may overlap layout as before. Every font change (unregistrations too)
        /// must go through here: a change without the hold posts notifications a later hold would count as its own.
        func exclusiveFontChange(deliveryTimeout: TimeInterval? = nil, _ body: () -> Int) {
            let waits = !Thread.isMainThread && NSClassFromString("NSTextStorage") != nil
            let limit = deliveryTimeout ?? Self.defaultDeliveryTimeout.withLock { $0 }
            let delivered = DispatchSemaphore(value: 0)
            exclusive {
                defer { beforeRelease.withLock { $0 }?() }
                // Observed from inside the hold, right before the change: posts of changes made while this waited
                // for the lock are not counted.
                let token = waits ? NotificationCenter.default.addObserver(
                    forName: Notification.Name("NSFontSetChangedNotification"), object: nil, queue: nil) { _ in
                        // One main-queue round later: every observer of this post (TextKit's too) has run.
                        DispatchQueue.main.async { delivered.signal() }
                    } : nil
                defer { token.map(NotificationCenter.default.removeObserver) }
                let changed = body()
                guard waits, changed > 0 else { return }
                let deadline = DispatchTime.now() + limit
                for _ in 0..<changed where delivered.wait(timeout: deadline) == .timedOut {
                    timeouts.withLock { $0 += 1 }
                    break
                }
            }
        }

        /// Exclusive acquisitions so far (tests: one per registration pass).
        private let exclusiveCount = Mutex(0)
        var exclusiveAcquisitions: Int { exclusiveCount.withLock { $0 } }

        func exclusive<T>(_ body: () throws -> T) rethrows -> T {
            precondition(pthread_rwlock_wrlock(lock) == 0, "FontGate: exclusive lock failed")
            exclusiveCount.withLock { $0 += 1 }
            defer { pthread_rwlock_unlock(lock) }
            return try body()
        }
    }
    static let fontGate = FontGate()

    /// Runs `body` while no font can be registered (font registrations wait until it returns; it waits for one in
    /// progress). For TextKit layout and drawing off the main thread (Word). Call `prewarm()` before, not inside;
    /// inside, call no FontResolver API (it may wait for a registration that waits for this) and do not nest.
    public static func withStableFonts<T>(_ body: () throws -> T) rethrows -> T {
        try fontGate.shared(body)
    }

    /// Registers Office's own fonts (`OfficeFonts`, per the `office.officeFonts` setting) and lists the installed
    /// families now instead of on the first font resolution (~250 ms with Office installed). A macOS access prompt
    /// for Office's font cache, if any, appears at this moment; the cloud read is waited for at most 2 s (then this
    /// process goes on without the cloud fonts, which come with the next launch), so no font work waits longer
    /// than about 2 s for the answer, plus up to 0.5 s per registration pass should the main thread be blocked
    /// meanwhile (`FontGate.exclusiveFontChange`). Meant for app start: call it once, off the main thread and off Swift's concurrency pool, because it
    /// blocks until done, e.g. `DispatchQueue.global(qos: .utility).async { FontResolver.prewarm() }`. Idempotent
    /// and thread-safe: once done it returns at once; concurrent first calls wait for the first one's list.
    /// Without it the same happens lazily on the first font resolution.
    public static func prewarm() {
        _ = registeredFamilies
    }

    /// Whether Office's fonts are only partly there in this process: the registration (`prewarm()`) gave up on
    /// Office's cloud font cache after its 2 s limit (a macOS access prompt not answered in time). False before the
    /// registration and when it read everything it looked for (also without Office). Does not wait.
    public static var officeFontsIncomplete: Bool { OfficeFonts.defaultMissedCloud.withLock { $0 } }

    /// Whether the installed-family list is built (tests).
    static var isPrewarmed: Bool { installedState.withLock { $0.map != nil } }
    /// How often the installed-family list was built in this process (tests).
    static var installedBuilds: Int { installedState.withLock { $0.builds } }


    public func isInstalled(_ name: String) -> Bool { Self.installedFamily(name) != nil }

    private static func installedFamily(_ name: String) -> String? {
        installed[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    // MARK: resolution

    private struct Resolution {
        var family: String
        var face: String?
        var weight: CGFloat?
        var width: CGFloat?
    }

    /// The family actually used for `typeface` (after theme shorthands, installed check, substitution).
    public func resolvedFamily(_ typeface: String?, script: Script = .latin) -> String {
        resolve(typeface, script: script).family
    }

    private func themeFont(_ shorthand: String, script: Script) -> String? {
        switch shorthand {
        case "+mj-lt": return theme.majorLatin
        case "+mn-lt": return theme.minorLatin
        case "+mj-ea": return theme.majorEA
        case "+mn-ea": return theme.minorEA
        case "+mj-cs", "+mn-cs": return "Arial"
        default: return nil
        }
    }

    private func resolve(_ typeface: String?, script: Script) -> Resolution {
        var name = (typeface ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            switch script {
            case .latin: name = theme.minorLatin
            case .eastAsian: name = theme.minorEA
            case .complexScript: name = "+mn-cs"
            }
        }
        // Theme shorthand (a theme font may itself not be a shorthand; one level only, no loops).
        if name.hasPrefix("+") {
            name = (themeFont(name.lowercased(), script: script) ?? "").trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty || name.hasPrefix("+") {
            name = script == .eastAsian ? "Hiragino Sans" : (script == .latin ? "Calibri" : "Arial")
        }
        return resolveName(name, script: script)
    }

    private func resolveName(_ name: String, script: Script) -> Resolution {
        if let f = Self.installedFamily(name) { return Resolution(family: f) }
        // A face's full or PostScript name ("Aptos Display" is family Aptos, style Display; "Avenir Book").
        if let face = Self.installedFace(name) { return Resolution(family: face.family, face: face.postScript) }
        let (base, weight, width) = Self.splitStyleWords(name)
        let mods = (weight, width)
        if base != name, !base.isEmpty, let f = Self.installedFamily(base) {
            return Resolution(family: f, weight: mods.0, width: mods.1)
        }
        // Regular-weight face words ("Avenir Book", "… Regular", "… Roman") name the installed family's plain
        // face. Only when that family is installed: otherwise "Book"/"Roman" still hint at a serif.
        for word in Self.regularWords where weight == nil && base.lowercased().hasSuffix(" " + word) {
            if let f = Self.installedFamily(String(base.dropLast(word.count + 1))) {
                return Resolution(family: f, weight: nil, width: width)
            }
        }
        let target = base.isEmpty ? name : base
        // The measured rule covers Latin runs; East Asian and complex-script runs keep the table.
        if substitution == .powerPoint, script == .latin, !Self.drawnByOffice(target) {
            let f = Self.installedFamily("Calibri") ?? Self.installedFamily("Arial") ?? "Arial"
            return Resolution(family: f)
        }
        for candidate in Self.candidates(for: target) {
            if let f = Self.installedFamily(candidate) {
                return Resolution(family: f, weight: mods.0, width: mods.1)
            }
        }
        return Resolution(family: Self.installedFamily("Helvetica Neue") ?? "Helvetica Neue",
                          weight: mods.0, width: mods.1)
    }

    // MARK: style words

    private static let weightWords: [(String, CGFloat)] = [
        ("extrablack", 0.7), ("ultrablack", 0.7), ("extra bold", 0.5), ("extrabold", 0.5),
        ("ultrabold", 0.5), ("extra light", -0.6), ("extralight", -0.6), ("ultralight", -0.8),
        ("ultra light", -0.8), ("semibold", 0.3), ("semi bold", 0.3), ("demibold", 0.3), ("demi bold", 0.3),
        ("black", 0.62), ("heavy", 0.56), ("medium", 0.23), ("light", -0.4), ("thin", -0.6),
    ]
    private static let regularWords = ["book", "regular", "roman"]
    private static let widthWords: [(String, CGFloat)] = [
        ("condensed", -0.3), ("narrow", -0.2),
    ]

    /// Strips weight/width words ("Black", "Light", "Medium", "Semibold", "Condensed", "Narrow", …)
    /// from the end of a name, e.g. "Lato Black" → ("Lato", 0.62, nil).
    private static func splitStyleWords(_ name: String) -> (base: String, weight: CGFloat?, width: CGFloat?) {
        var base = name
        var weight: CGFloat?
        var width: CGFloat?
        var changed = true
        while changed {
            changed = false
            let lower = base.lowercased()
            for (w, v) in widthWords where lower.hasSuffix(" " + w) && width == nil {
                base = String(base.dropLast(w.count + 1)); width = v; changed = true; break
            }
            if changed { continue }
            for (w, v) in weightWords where lower.hasSuffix(" " + w) && weight == nil {
                base = String(base.dropLast(w.count + 1)); weight = v; changed = true; break
            }
        }
        return (base.trimmingCharacters(in: .whitespaces), weight, width)
    }

    // MARK: substitution table

    private static let sansList = ["Helvetica Neue"]
    private static let serifList = ["Georgia", "Times New Roman"]
    private static let monoList = ["Menlo"]
    private static let cjkSansList = ["Hiragino Sans"]
    private static let cjkSerifList = ["Hiragino Mincho ProN", "Hiragino Sans"]

    /// Exact (lowercased, NFKC) names first, then prefixes, then pattern classes. See docs/decisions.md.
    private static let exact: [String: [String]] = [
        "lato": ["Lato", "Helvetica Neue"],
        "calibri": sansList, "aptos": sansList, "segoe ui": sansList, "open sans": sansList,
        "hp simplified": sansList, "verdana": sansList, "tahoma": sansList, "arial": sansList,
        "cambria": serifList, "constantia": serifList, "georgia": ["Times New Roman", "Georgia"],
        "consolas": monoList, "courier new": monoList, "lucida console": monoList,
        "wingdings": sansList, "wingdings 2": sansList, "wingdings 3": sansList, "symbol": sansList,
    ]
    private static let prefixes: [(String, [String])] = [
        ("telegrotesk", sansList), ("teleneo", sansList), ("tele-grotesk", sansList),
    ]

    /// Families PowerPoint draws in their own face: what Office for Mac ships (Microsoft PowerPoint.app/Contents/
    /// Resources/DFonts, read 2026-11-13), the Windows/Office standard faces, and Lato / Open Sans (measured: drawn in
    /// their own face). Lowercased, NFKC. `.powerPoint` keeps the look-alike table for these; every other missing
    /// Latin name → Calibri. Not listed on purpose: corporate faces of the table (HP Simplified, TeleGrotesk, TeleNeo),
    /// which PowerPoint draws in Calibri when they are missing (D1, D7).
    static let officeFonts: Set<String> = [
        // Office defaults and ClearType collection
        "calibri", "calibri light", "cambria", "cambria math", "candara", "consolas", "constantia", "corbel",
        "aptos", "aptos display", "aptos narrow", "aptos black", "aptos extrabold", "aptos semibold", "aptos light",
        "segoe ui", "segoe ui light", "segoe ui semibold", "segoe ui symbol", "segoe ui emoji", "segoe print",
        "segoe script", "lato", "open sans",
        // Windows core fonts
        "arial", "arial black", "arial narrow", "arial rounded mt bold", "times new roman", "courier new", "verdana",
        "tahoma", "trebuchet ms", "georgia", "comic sans ms", "impact", "lucida console", "lucida sans unicode",
        "symbol", "wingdings", "wingdings 2", "wingdings 3", "webdings", "marlett",
        // Office for Mac DFonts
        "abadi mt condensed extra bold", "abadi mt condensed light", "baskerville old face", "bauhaus 93", "bell mt",
        "bernard mt condensed", "book antiqua", "bookman old style", "bookshelf symbol 7", "braggadocio",
        "britannic bold", "calisto mt", "century", "century gothic", "century schoolbook", "colonna mt",
        "cooper black", "copperplate gothic bold", "curlz mt", "desdemona", "dubai", "edwardian script itc",
        "engravers mt", "eurostile", "footlight mt light", "franklin gothic book", "franklin gothic demi",
        "franklin gothic demi cond", "franklin gothic heavy", "franklin gothic medium", "franklin gothic medium cond",
        "gabriola", "garamond", "gill sans mt", "gill sans mt condensed", "gill sans mt ext condensed bold",
        "gill sans ultra bold", "gloucester mt extra condensed", "goudy old style", "haettenschweiler",
        "harrington", "imprint mt shadow", "kino mt", "lucida sans", "lucida bright", "lucida blackletter",
        "lucida calligraphy", "lucida fax", "lucida handwriting", "lucida sans typewriter", "matura mt script capitals",
        "mistral", "modern no. 20", "monotype corsiva", "monotype sorts", "ms reference sans serif",
        "ms reference specialty", "mt extra", "news gothic mt", "onyx", "palatino linotype", "perpetua",
        "perpetua titling mt", "rockwell", "rockwell condensed", "rockwell extra bold", "stencil", "tw cen mt",
        "tw cen mt condensed", "tw cen mt condensed extra bold", "wide latin",
        // complex-script faces Office ships (Latin runs naming them)
        "mangal", "latha", "tunga", "gautami", "kartika", "nyala", "microsoft himalaya", "mongolian baiti",
        "microsoft yi baiti", "microsoft tai le", "microsoft new tai lue", "myanmar text", "angsana new",
        "cordia new", "david", "th sarabun new",
    ]

    /// Names of East Asian fonts (Latin spelling or CJK characters). Plain "gothic" is not enough: Trade Gothic,
    /// News Gothic, Bell Gothic are Latin faces.
    private static let cjkSansWords = [
        "ゴシック", "ms gothic", "ms pgothic", "ms ui gothic", "yu gothic", "游ゴシック", "meiryo", "メイリオ",
        "hiragino", "malgun", "gulim", "dotum", "simhei", "yahei", "jhenghei", "dengxian", "osaka",
    ]
    private static let cjkSerifWords = ["明朝", "mincho", "simsun", "mingliu", "batang", "gungsuh", "fangsong", "kaiti"]

    private static func isCJK(_ key: String) -> Bool {
        classify(key) == cjkSansList || classify(key) == cjkSerifList
    }

    private static func drawnByOffice(_ name: String) -> Bool {
        let key = name.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespaces)
        return officeFonts.contains(key) || isCJK(key)
    }

    private static func candidates(for name: String) -> [String] {
        let key = name.precomposedStringWithCompatibilityMapping.lowercased()
            .trimmingCharacters(in: .whitespaces)
        if let c = exact[key] { return c }
        for (p, c) in prefixes where key.hasPrefix(p) { return c }
        return classify(key)
    }

    private static func classify(_ key: String) -> [String] {
        func has(_ words: [String]) -> Bool { words.contains { key.contains($0) } }
        // CJK names: ＭＳ Ｐゴシック → "ms pゴシック" after NFKC.
        if has(cjkSerifWords) { return cjkSerifList }
        if has(cjkSansWords) { return cjkSansList }
        if key.unicodeScalars.contains(where: { $0.value >= 0x3000 }) { return cjkSansList }
        if has(["mono", "courier", "consolas", "code", "menlo", "typewriter", "fixed", "terminal"]) { return monoList }
        if has(["sans", "grotesk", "grotesque", "arial", "helvetica", "gothic", "neo", "gotham", "roboto", "lato"]) {
            return sansList
        }
        if has(["times", "georgia", "garamond", "cambria", "serif", "roman", "book", "minion", "palatino",
                "baskerville", "bodoni", "didot", "caslon", "constantia", "antiqua", "bembo", "charter"]) {
            return serifList
        }
        return sansList
    }

    // MARK: font creation

    public func font(typeface: String?, size: CGFloat, bold: Bool, italic: Bool,
                     script: Script = .latin) -> CTFont {
        let res = resolve(typeface, script: script)
        let key = Key(family: res.family, face: res.face, size: size, bold: bold, italic: italic,
                      weight: res.weight, width: res.width)
        if let hit = cache.withLock({ $0[key] }) { return hit.font }
        // Created outside the lock (font creation talks to fontd over XPC); if two threads race on the
        // same key the first inserted object wins and both callers get that one.
        let created = Self.offPool { FontBox(font: Self.makeFont(key)) }
        return cache.withLock { cache in
            if let hit = cache[key] { return hit.font }
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = created
            return created.font
        }
    }

    private static let regularStyles: Set<String> = ["regular", "roman", "book", "normal", "plain"]

    /// Core Text's face for a bare family name is not always its regular one: Office's cloud "Aptos Display" is
    /// family "Aptos", style "Display", and was picked for body text. When `font`'s style is not a regular style,
    /// returns the family's face with a regular style name (upright, weight and width closest to 0); nil keeps
    /// `font` (also when the family has no such face). Font queue only.
    private static func regularFace(of font: CTFont, family: String, size: CGFloat) -> CTFont? {
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?)?.lowercased() ?? ""
        guard !regularStyles.contains(style) else { return nil }
        let memoKey = family.lowercased()
        let (cached, generation) = memos.withLock { ($0.regularFace[memoKey], $0.generation) }
        if let known = cached {
            return known.map { CTFontCreateWithName($0 as CFString, size, nil) }
        }
        let found = findRegularFace(family: family)
        if !notWaiting { memos.withLock { if $0.generation == generation { $0.regularFace[memoKey] = .some(found) } } }
        return found.map { CTFontCreateWithName($0 as CFString, size, nil) }
    }

    /// PostScript name of the family's regular-style face (see `regularFace`), nil if none. Font queue only.
    private static func findRegularFace(family: String) -> String? {
        let familyOnly = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute]) as CFSet
        guard let faces = CTFontDescriptorCreateMatchingFontDescriptors(familyOnly, mandatory) as? [CTFontDescriptor]
        else { return nil }
        func score(_ d: CTFontDescriptor) -> CGFloat? {
            guard let s = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String)?.lowercased(),
                  regularStyles.contains(s) else { return nil }
            let t = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let weight = (t[kCTFontWeightTrait] as? CGFloat) ?? 0, width = (t[kCTFontWidthTrait] as? CGFloat) ?? 0
            let symbolic = CTFontSymbolicTraits(rawValue: (t[kCTFontSymbolicTrait] as? UInt32) ?? 0)
            return abs(weight) + abs(width) + (symbolic.contains(.traitItalic) ? 1 : 0)
        }
        guard let best = faces.compactMap({ d in score(d).map { (d, $0) } }).min(by: { $0.1 < $1.1 })?.0 else { return nil }
        return CTFontDescriptorCopyAttribute(best, kCTFontNameAttribute) as? String
    }

    private static func makeFont(_ key: Key) -> CTFont {
        var attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: key.family]
        var traits: [CFString: Any] = [:]
        if let w = key.weight { traits[kCTFontWeightTrait] = w }
        if let w = key.width { traits[kCTFontWidthTrait] = w }
        if !traits.isEmpty { attrs[kCTFontTraitsAttribute] = traits }
        var font: CTFont
        if let face = key.face {
            font = CTFontCreateWithName(face as CFString, key.size, nil)
        } else {
            let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            font = CTFontCreateWithFontDescriptor(descriptor, key.size, nil)
            if traits.isEmpty, let regular = regularFace(of: font, family: key.family, size: key.size) { font = regular }
        }
        var want: CTFontSymbolicTraits = []
        if key.bold { want.insert(.traitBold) }
        if key.italic { want.insert(.traitItalic) }
        if !want.isEmpty {
            // nil when the family has no such face: keep the regular face, never synthesize.
            if let styled = CTFontCreateCopyWithSymbolicTraits(font, key.size, nil, want, want) {
                font = styled
            } else if key.bold && key.italic,
                      let boldOnly = CTFontCreateCopyWithSymbolicTraits(font, key.size, nil, .traitBold, .traitBold) {
                font = boldOnly
            } else if key.bold && key.italic,
                      let italicOnly = CTFontCreateCopyWithSymbolicTraits(font, key.size, nil, .traitItalic, .traitItalic) {
                font = italicOnly
            }
        }
        return font
    }
}

// MARK: - Symbol fonts

extension FontResolver {
    /// Maps text set in Wingdings / Wingdings 2 / Wingdings 3 / Symbol (codes 0x20–0xFF or the private-use
    /// range U+F020–U+F0FF) to Unicode. The returned typeface is nil when the text should be drawn in the
    /// normal font (Core Text's cascade picks a glyph source for ✓ ➢ ▪ …); if no character could be
    /// mapped the original symbol typeface is returned. Other typefaces: text unchanged, typeface nil.
    public static func mapSymbolText(_ text: String, typeface: String) -> (text: String, typeface: String?) {
        let table: [UInt32: UInt32]
        var passASCII = false
        switch typeface.trimmingCharacters(in: .whitespaces).lowercased() {
        case "wingdings": table = wingdings
        case "wingdings 2": table = wingdings2
        case "wingdings 3": table = wingdings3
        case "symbol": table = symbolFont; passASCII = true
        default: return (text, nil)
        }
        var out = String.UnicodeScalarView()
        var mappedAny = false
        for s in text.unicodeScalars {
            var code = s.value
            if (0xF020...0xF0FF).contains(code) { code -= 0xF000 }
            if let m = table[code], let u = Unicode.Scalar(m) {
                out.append(u); mappedAny = true
            } else if passASCII, (0x20...0x7E).contains(code), let u = Unicode.Scalar(code) {
                out.append(u); mappedAny = true
            } else {
                out.append(s)
            }
        }
        return (String(out), mappedAny ? nil : typeface)
    }

    // Wingdings: bullets/check marks that occur in real decks plus the common pictographs.
    private static let wingdings: [UInt32: UInt32] = [
        0x21: 0x270F, 0x22: 0x2702, 0x28: 0x260E, 0x2A: 0x2709, 0x46: 0x261E, 0x4A: 0x263A, 0x4C: 0x2639,
        0x6C: 0x25CF, 0x6D: 0x274D, 0x6E: 0x25A0, 0x6F: 0x25A1, 0x71: 0x2751, 0x72: 0x2752,
        0x75: 0x25C6, 0x76: 0x2756, 0x77: 0x2B27, 0x78: 0x2327,
        0x9E: 0x00B7, 0x9F: 0x2022, 0xA1: 0x25CB, 0xA4: 0x25C9, 0xA7: 0x25AA, 0xA8: 0x25FB,
        0xD8: 0x27A2, 0xDF: 0x2190, 0xE0: 0x2192, 0xE1: 0x2191, 0xE2: 0x2193, 0xE3: 0x2196, 0xE4: 0x2197,
        0xE5: 0x2199, 0xE6: 0x2198, 0xE8: 0x2794,
        0xEF: 0x21E6, 0xF0: 0x21E8, 0xF1: 0x21E7, 0xF2: 0x21E9, 0xF3: 0x2B04, 0xF4: 0x21F3,
        0xFB: 0x2717, 0xFC: 0x2713, 0xFD: 0x2612, 0xFE: 0x2611,
    ]
    // Wingdings 2 / 3: entries verified against the glyph names (post table) of the macOS fonts
    // (Wingdings 2 4F xmark, 50 check, 51 boxxmark, 52 boxcheck, 53 boxx, A3 box1;
    // Wingdings 3 70 triangleup, 71 triangledwn, 72/73 open up/down, 74 triangleleft, 75 trianglert,
    // 76/77 open left/right). Unverified codes are left out.
    private static let wingdings2: [UInt32: UInt32] = [
        0x4F: 0x2717, 0x50: 0x2713, 0x51: 0x2612, 0x52: 0x2611, 0x53: 0x2612, 0xA3: 0x25A1,
    ]
    private static let wingdings3: [UInt32: UInt32] = [
        0x70: 0x25B2, 0x71: 0x25BC, 0x72: 0x25B3, 0x73: 0x25BD,
        0x74: 0x25C4, 0x75: 0x25BA, 0x76: 0x25C1, 0x77: 0x25B7,
    ]
    private static let symbolFont: [UInt32: UInt32] = {
        var t: [UInt32: UInt32] = [
            0x22: 0x2200, 0x24: 0x2203, 0x27: 0x220B, 0x2A: 0x2217, 0x2D: 0x2212, 0x40: 0x2245,
            0xA3: 0x2264, 0xA5: 0x221E, 0xA7: 0x2663, 0xA8: 0x2666, 0xA9: 0x2665, 0xAA: 0x2660,
            0xAC: 0x2190, 0xAD: 0x2191, 0xAE: 0x2192, 0xAF: 0x2193, 0xB0: 0x00B0, 0xB1: 0x00B1,
            0xB3: 0x2265, 0xB4: 0x00D7, 0xB7: 0x2022, 0xB8: 0x00F7, 0xB9: 0x2260, 0xBB: 0x2248,
            0xD6: 0x221A, 0xDB: 0x21D4, 0xDE: 0x21D2,
        ]
        let upper = Array("ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ".unicodeScalars)
        let lower = Array("αβχδεφγηιϕκλμνοπθρστυϖωξψζ".unicodeScalars)
        for i in 0..<26 {
            t[0x41 + UInt32(i)] = upper[i].value
            t[0x61 + UInt32(i)] = lower[i].value
        }
        return t
    }()
}
