// FolderWatcher.swift — folder sources watched on disk (FSEvents), so the tree follows the Finder
import CoreServices
import Foundation
import IndexKit
import os
import UniformTypeIdentifiers

/// Watches the folder sources. `onChange` gets the watched roots below which something relevant changed;
/// the model indexes them again (incrementally) and rebuilds the tree. `urgent`: the roots themselves went
/// away or came back (volume ejected or mounted, folder moved), which the model does not hold back.
/// `scopes` (1.4.0 P3): for a root, the folders (relative, no trailing "/") below which the batch changed something;
/// a root without an entry needs a full scan (lost events, the root itself changed, a change directly in it).
@MainActor public protocol FolderWatching: AnyObject {
    var onChange: (@MainActor (_ roots: [String], _ urgent: Bool, _ scopes: [String: [String]]) -> Void)? { get set }
    /// The roots to watch from now on (replaces the earlier set); whether image files count.
    func watch(_ roots: [String], includeImages: Bool)
}

/// One FSEvents stream over all folder sources (decisions.md, „Ordner beobachten“).
///
/// - Coalesced by FSEvents (`latency`), so a Finder move of 1,000 files is one report.
/// - File-level events, filtered like `FolderScanner`: only directories and supported files count, and
///   nothing below a dot or hidden folder (`~/Library` in a watched home folder changes all the time).
/// - Lost events (`MustScanSubDirs`, dropped by the kernel or the daemon) and a changed root count as a change.
/// - A stream that cannot be created is tried again after 1, 2, 4 … 60 s, then not until the next `watch`
///   call (sources or the images setting changed); once it runs after a failure, one report covers the gap.
@MainActor public final class FSEventsFolderWatcher: FolderWatching {
    public var onChange: (@MainActor (_ roots: [String], _ urgent: Bool, _ scopes: [String: [String]]) -> Void)?
    private var stream: FSEventStreamRef?
    private var sink: Unmanaged<Sink>?
    /// The roots asked for (also while the stream is retried).
    private var roots: [String] = []
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "local.pdfsucher.folderwatch", qos: .utility)
    private let filter = EventFilter()
    private let retryDelays: [Duration]
    private let createStream: StreamCreate
    private var retryTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "local.pdfsucher", category: "FolderWatcher")

    /// `FSEventStreamCreate` with the event id „since now“ (tests make it fail).
    typealias StreamCreate = (FSEventStreamCallback, UnsafeMutablePointer<FSEventStreamContext>, [String], CFTimeInterval,
                              FSEventStreamCreateFlags) -> FSEventStreamRef?

    public static let defaultRetryDelays: [Duration] = [1, 2, 4, 8, 16, 32, 60].map { .seconds($0) }

    public convenience init(latency: TimeInterval = 1.5) {
        self.init(latency: latency, retryDelays: Self.defaultRetryDelays) { callback, context, paths, latency, flags in
            FSEventStreamCreate(nil, callback, context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                latency, flags)
        }
    }

    init(latency: TimeInterval, retryDelays: [Duration], createStream: @escaping StreamCreate) {
        self.latency = latency
        self.retryDelays = retryDelays
        self.createStream = createStream
    }

    isolated deinit {
        retryTask?.cancel()
        stop()
    }

    /// The stream runs (tests).
    var isWatching: Bool { stream != nil }

    public func watch(_ roots: [String], includeImages: Bool) {
        let roots = roots.sorted()
        filter.setIncludeImages(includeImages)
        guard roots != self.roots else { return }
        retryTask?.cancel()
        retryTask = nil
        stop()
        self.roots = roots
        filter.setRoots(roots, includeImages: includeImages)
        guard !roots.isEmpty else { return }
        start(attempt: 0)
    }

    /// Creates and starts the stream; on failure tries again after the next delay, up to the last one.
    private func start(attempt: Int) {
        // The stream holds the sink, not the watcher: a callback still running after `stop` finds the
        // watcher gone and does nothing.
        let sink = Unmanaged.passRetained(Sink(filter: filter) { [weak self] changed, urgent, scopes in
            Task { @MainActor [weak self] in self?.onChange?(changed, urgent, scopes) }
        })
        var context = FSEventStreamContext(version: 0, info: sink.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = createStream(Self.callback, &context, filter.watchedPaths, latency, flags) else {
            sink.release()
            guard attempt < retryDelays.count else {
                Self.log.error("Cannot watch \(self.roots.count) folders; trying again with the next watch call")
                roots = []                                  // the next `watch`, even with the same roots, starts over
                return
            }
            let delay = retryDelays[attempt]
            Self.log.error("Cannot watch \(self.roots.count) folders; trying again in \(delay, privacy: .public)")
            let wanted = roots
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.roots == wanted else { return }
                self.retryTask = nil
                self.start(attempt: attempt + 1)
            }
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        self.sink = sink
        // Changes while there was no stream were not reported: one report lets the sources be checked (review).
        if attempt > 0 { onChange?(roots, false, [:]) }
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        if let sink {
            let held = sink
            queue.async { held.release() }              // after any callback already queued
        }
        sink = nil
    }

    /// What the stream's callback needs, off the main actor.
    private final class Sink: Sendable {
        let filter: EventFilter
        let deliver: @Sendable ([String], Bool, [String: [String]]) -> Void
        init(filter: EventFilter, deliver: @escaping @Sendable ([String], Bool, [String: [String]]) -> Void) {
            self.filter = filter
            self.deliver = deliver
        }
    }

    /// On the stream's queue: the filter runs there (it may look at the disk), the report on the main actor.
    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let events = (0..<min(count, list.count)).map { (path: list[$0], flags: flags[$0]) }
        let urgent = sink.filter.urgentRoots(events)
        let changed = sink.filter.changedRoots(events).filter { !urgent.contains($0) }
        if !urgent.isEmpty { sink.deliver(urgent, true, [:]) }
        if !changed.isEmpty { sink.deliver(changed, false, sink.filter.changedScopes(events)) }
    }
}

/// Which watched roots an FSEvents batch touches (thread-safe; used on the stream's queue).
final class EventFilter: @unchecked Sendable {
    private let lock = NSLock()
    /// Each root as given (reported back) and as FSEvents names it (symbolic links resolved: `/var` is
    /// `/private/var`, a source may be reached through a link).
    private var roots: [(reported: String, real: String)] = []
    private var includeImages = true
    /// Folders found hidden or a package (true) or plain (false); cleared with the roots and after lost events.
    private var skipCache: [String: Bool] = [:]
    private let isHidden: @Sendable (String) -> Bool
    private let isPackage: @Sendable (String) -> Bool

    init(isHidden: @escaping @Sendable (String) -> Bool = EventFilter.diskIsHidden,
         isPackage: @escaping @Sendable (String) -> Bool = EventFilter.diskIsPackage) {
        self.isHidden = isHidden
        self.isPackage = isPackage
    }

    func setRoots(_ roots: [String], includeImages: Bool = true, resolve: (String) -> String = EventFilter.realPath) {
        let pairs = roots.map { (reported: $0, real: resolve($0)) }
        lock.withLock { self.roots = pairs; self.includeImages = includeImages; skipCache = [:] }
    }

    /// Images count only while the folders list them (OCR setting „Bilder einbeziehen“), like `FolderScanner`.
    func setIncludeImages(_ include: Bool) { lock.withLock { includeImages = include } }

    /// The paths to hand to FSEvents.
    var watchedPaths: [String] { lock.withLock { roots.map(\.real) } }

    /// realpath(3): Foundation's `resolvingSymlinksInPath` maps `/private/var` back to `/var`.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func changedRoots(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> [String] {
        lock.withLock {
            var found: [String] = []
            for (path, flags) in events {
                if flags & Self.lost != 0 { skipCache = [:] }       // folders may have been hidden or shown meanwhile
                for root in roots where !found.contains(root.reported) && isRelevant(path, flags: flags, root: root.real) {
                    found.append(root.reported)
                }
            }
            return found
        }
    }

    /// 1.4.0 P3: per root, the folders to scan again: the parent folder of every relevant changed item (a deleted or
    /// renamed folder is seen from its parent). A root is left out (full scan) for lost events, a change of the root
    /// itself or of an item directly in it. Relative paths, no trailing "/", nested ones dropped.
    func changedScopes(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> [String: [String]] {
        lock.withLock {
            var scopes: [String: Set<String>] = [:], full: Set<String> = []
            for (path, flags) in events {
                let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                for root in roots where isRelevant(path, flags: flags, root: root.real) {
                    let inside = Self.isInside(path, root.real)
                    guard flags & Self.lost == 0, inside, path != root.real else { full.insert(root.reported); continue }
                    let relative = String(path.dropFirst(root.real == "/" ? 1 : root.real.count + 1))
                    let parent = (relative as NSString).deletingLastPathComponent
                    if parent.isEmpty { full.insert(root.reported) } else { scopes[root.reported, default: []].insert(parent) }
                }
            }
            var result: [String: [String]] = [:]
            for (root, set) in scopes where !full.contains(root) {
                let sorted = set.sorted()
                result[root] = sorted.filter { scope in !sorted.contains { $0 != scope && scope.hasPrefix($0 + "/") } }
            }
            return result
        }
    }

    private static let rootMoved = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
                                                           | kFSEventStreamEventFlagMount)

    /// Roots that went away or came back: the root itself changed, or a volume was (un)mounted at or above it.
    func urgentRoots(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> [String] {
        lock.withLock {
            var found: [String] = []
            for (path, flags) in events where flags & Self.rootMoved != 0 {
                let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                for root in roots where !found.contains(root.reported) && Self.isInside(root.real, path) {
                    found.append(root.reported)
                }
            }
            return found
        }
    }

    private static let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                      | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
    /// What the index can see. Extended attributes, permissions, Finder info and owner are left out: opening
    /// a PDF in Preview writes `com.apple.lastuseddate#PS`, a download its quarantine flag.
    private static let content = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                         | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)

    /// `child` lies in `root` (a root of "/" included).
    private static func isInside(_ child: String, _ root: String) -> Bool {
        child == root || child.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// A change at `path` below `root` that the index could see. Called under the lock.
    private func isRelevant(_ path: String, flags: FSEventStreamEventFlags, root: String) -> Bool {
        let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if flags & Self.lost != 0 { return Self.isInside(path, root) || Self.isInside(root, path) }
        guard Self.isInside(path, root), flags & Self.content != 0 else { return false }
        if path == root { return true }
        let parts = path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
        guard parts.count <= FolderScannerLimits.maxDepth + 1, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        if !isDirectory, !SupportedSourceTypes.accepts(fileExtension: (path as NSString).pathExtension, includeImages: includeImages) {
            return false
        }
        // The scanner does not enter packages: by type for every folder on the way (also one just deleted) …
        let folders = isDirectory ? parts : Array(parts.dropLast())
        if folders.contains(where: Self.isPackageType) { return false }
        // … and by the disk for the existing ones, as for hidden folders (not the item itself: a deleted one
        // cannot be asked).
        var dir = root == "/" ? "" : root
        for part in parts.dropLast() {
            dir += "/" + part
            if let skip = skipCache[dir] { if skip { return false } else { continue } }
            let skip = isHidden(dir) || isPackage(dir)
            skipCache[dir] = skip
            if skip { return false }
        }
        return true
    }

    private static func isPackageType(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }

    @Sendable static func diskIsHidden(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }

    @Sendable static func diskIsPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

/// The scanner's default depth (`FolderScanner(maxDepth:)`), for the event filter.
enum FolderScannerLimits { static let maxDepth = 10 }
