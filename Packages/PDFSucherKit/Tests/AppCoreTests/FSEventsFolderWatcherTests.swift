import CoreServices
import Foundation
import Testing
import TestSupport
@testable import AppCore

/// The real FSEvents stream (short latency) and its filter.
@MainActor @Suite("FSEvents folder watcher", .timeLimit(.minutes(1)))
struct FSEventsFolderWatcherTests {
    let base: URL

    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    /// Waits up to `seconds` for a report; nil when none came.
    func nextReport(_ watcher: FSEventsFolderWatcher, seconds: Double = 8, after change: () throws -> Void) async rethrows -> [String]? {
        var got: [String]?
        watcher.onChange = { roots, _, _ in got = roots }
        try change()
        let end = ContinuousClock.now + .seconds(seconds)
        while got == nil, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(50)) }
        return got
    }

    /// FSEvents may still deliver the creation of the fixture: let it settle before watching.
    func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func aFolderRenamedInTheFinderIsReported() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        let folder = root.appendingPathComponent("Projekt A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("r.pdf"), pages: ["Rechnung"])
        await settle()
        let watcher = FSEventsFolderWatcher(latency: 0.1)
        watcher.watch([root.standardizedFileURL.path], includeImages: true)
        try? await Task.sleep(for: .milliseconds(200))
        let report = try await nextReport(watcher) {
            try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Projekt A umbenannt"))
        }
        #expect(report == [root.standardizedFileURL.path])
    }

    @Test func aDeletedFolderIsReported() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        let folder = root.appendingPathComponent("Projekt B", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await settle()
        let watcher = FSEventsFolderWatcher(latency: 0.1)
        watcher.watch([root.standardizedFileURL.path], includeImages: true)
        try? await Task.sleep(for: .milliseconds(200))
        let report = try await nextReport(watcher) { try FileManager.default.removeItem(at: folder) }
        #expect(report == [root.standardizedFileURL.path])
    }

    @Test func otherFilesAndUnwatchedFoldersAreNotReported() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        let other = base.appendingPathComponent("Fremd", isDirectory: true)
        for dir in [root, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        await settle()
        let watcher = FSEventsFolderWatcher(latency: 0.1)
        watcher.watch([root.standardizedFileURL.path], includeImages: true)
        try? await Task.sleep(for: .milliseconds(200))
        let report = try await nextReport(watcher, seconds: 2) {
            try "x".write(to: root.appendingPathComponent("notiz.txt"), atomically: false, encoding: .utf8)
            try PDFFixtures.makePDF(at: other.appendingPathComponent("r.pdf"), pages: ["x"])
        }
        #expect(report == nil)
    }

    @Test func noReportsAfterTheRootsAreCleared() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await settle()
        let watcher = FSEventsFolderWatcher(latency: 0.1)
        watcher.watch([root.standardizedFileURL.path], includeImages: true)
        watcher.watch([], includeImages: true)
        let report = try await nextReport(watcher, seconds: 1.5) {
            try PDFFixtures.makePDF(at: root.appendingPathComponent("r.pdf"), pages: ["x"])
        }
        #expect(report == nil)
    }

    // MARK: Retry

    /// Fails the first `failures` creates (nil), then creates the real stream; records the attempts.
    final class FlakyCreate: @unchecked Sendable {
        var failures: Int
        var attempts: [[String]] = []
        init(failures: Int) { self.failures = failures }
        func create(_ callback: FSEventStreamCallback, _ context: UnsafeMutablePointer<FSEventStreamContext>, _ paths: [String],
                    _ latency: CFTimeInterval, _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef? {
            attempts.append(paths)
            if failures > 0 { failures -= 1; return nil }
            return FSEventStreamCreate(nil, callback, context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                       latency, flags)
        }
    }

    func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aFailedCreateIsRetriedWithBackoff() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        let folder = root.appendingPathComponent("Projekt A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await settle()
        let flaky = FlakyCreate(failures: 2)
        let watcher = FSEventsFolderWatcher(latency: 0.1, retryDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200)],
                                            createStream: flaky.create)
        var catchUp: [String]?
        watcher.onChange = { roots, _, _ in catchUp = roots }
        watcher.watch([root.standardizedFileURL.path], includeImages: true)
        #expect(!watcher.isWatching)
        await waitUntil(3) { watcher.isWatching && catchUp != nil }
        #expect(watcher.isWatching, "running after two failed creates")
        #expect(flaky.attempts.count == 3)
        #expect(catchUp == [root.standardizedFileURL.path], "review: changes while it was down are picked up by one report")
        try? await Task.sleep(for: .milliseconds(200))
        let report = try await nextReport(watcher) {
            try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Projekt A umbenannt"))
        }
        #expect(report == [root.standardizedFileURL.path], "the retried stream reports")
    }

    @Test func retriesAreLimited() async throws {
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let flaky = FlakyCreate(failures: 100)
        let watcher = FSEventsFolderWatcher(latency: 0.1, retryDelays: [.milliseconds(20), .milliseconds(40)], createStream: flaky.create)
        watcher.watch([root.path], includeImages: true)
        await waitUntil(5) { flaky.attempts.count >= 3 }
        try await Task.sleep(for: .milliseconds(300))                   // far beyond the last delay
        #expect(flaky.attempts.count == 3, "first try and two retries, then none")
        #expect(!watcher.isWatching)
        watcher.watch([root.path], includeImages: true)                  // the next source change starts over
        await waitUntil(5) { flaky.attempts.count >= 6 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(flaky.attempts.count == 6)
    }

    @Test func newRootsCancelTheRetryOfTheOldOnes() async throws {
        let a = base.appendingPathComponent("A", isDirectory: true), b = base.appendingPathComponent("B", isDirectory: true)
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let flaky = FlakyCreate(failures: 1)
        let watcher = FSEventsFolderWatcher(latency: 0.1, retryDelays: [.milliseconds(100)], createStream: flaky.create)
        watcher.watch([a.path], includeImages: true)                     // fails, retry in 100 ms
        watcher.watch([b.path], includeImages: true)                     // succeeds at once
        try await Task.sleep(for: .milliseconds(500))                   // the old retry would have run by now
        #expect(flaky.attempts.map { $0.map { URL(fileURLWithPath: $0).lastPathComponent } } == [["A"], ["B"]])
        #expect(watcher.isWatching)
    }

    @Test func theDefaultBackoffEndsAtAMinute() {
        let delays = FSEventsFolderWatcher.defaultRetryDelays
        #expect(delays.first == .seconds(1))
        #expect(delays.last == .seconds(60))
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 }, "growing")
    }

    // MARK: Filter

    let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
    let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)

    @Test func filterKeepsFoldersAndSupportedFiles() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q/Akten", "/q/Belege"], resolve: { $0 })
        #expect(filter.changedRoots([("/q/Akten/Verträge", dir)]) == ["/q/Akten"])
        #expect(filter.changedRoots([("/q/Belege/a/b.PDF", file)]) == ["/q/Belege"])
        #expect(filter.changedRoots([("/q/Belege/scan.heic", file)]) == ["/q/Belege"])
        #expect(filter.changedRoots([("/q/Akten/x.pdf", file), ("/q/Belege/y.pdf", file)]) == ["/q/Akten", "/q/Belege"])
    }

    /// 1.4.0 P3: the folders to scan again per root; a change directly in the root or lost events: the whole root.
    @Test func filterNamesTheChangedFolders() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q/Akten", "/q/Belege"], resolve: { $0 })
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(filter.changedScopes([("/q/Akten/2025/Mai/x.pdf", file), ("/q/Akten/2025/y.pdf", file),
                                      ("/q/Akten/Alt/Verträge", dir)]) == ["/q/Akten": ["2025", "Alt"]])
        #expect(filter.changedScopes([("/q/Akten/x.pdf", file)]) == [:], "directly in the root: full scan")
        #expect(filter.changedScopes([("/q/Belege/a/b.pdf", file), ("/q/Akten/a/c.pdf", file)]) == ["/q/Akten": ["a"], "/q/Belege": ["a"]])
        #expect(filter.changedScopes([("/q/Akten/a/b.pdf", file), ("/q/Akten/a", lost)]) == [:], "lost events: full scan")
        #expect(filter.changedScopes([("/q/Akten/a/notiz.txt", file)]) == [:], "nothing relevant")
    }

    @Test func filterDropsOtherFilesDotFoldersAndPrefixLookalikes() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q/Akten"], resolve: { $0 })
        #expect(filter.changedRoots([("/q/Akten/notiz.txt", file)]) == [])
        #expect(filter.changedRoots([("/q/Akten/.git/x.pdf", file)]) == [])
        #expect(filter.changedRoots([("/q/Akten/a/.DS_Store", file)]) == [])
        #expect(filter.changedRoots([("/q/Akten 2/x.pdf", file)]) == [], "another folder with the same start")
    }

    @Test func filterDropsChangesBelowHiddenFolders() {
        let filter = EventFilter(isHidden: { $0 == "/Users/u/Library" })
        filter.setRoots(["/Users/u"], resolve: { $0 })
        #expect(filter.changedRoots([("/Users/u/Library/Caches/x.pdf", file)]) == [])
        #expect(filter.changedRoots([("/Users/u/Library/Caches", dir)]) == [])
        #expect(filter.changedRoots([("/Users/u/Dokumente/x.pdf", file)]) == ["/Users/u"])
    }

    @Test func lostEventsAndRootChangesCount() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q/Akten"], resolve: { $0 })
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        #expect(filter.changedRoots([("/q/Akten/a", lost)]) == ["/q/Akten"])
        #expect(filter.changedRoots([("/q/Akten", rootChanged)]) == ["/q/Akten"])
        #expect(filter.changedRoots([("/q", lost)]) == ["/q/Akten"], "a lost event above the root covers it")
    }

    /// Review: the filter skips what the scanner skips, so a Home source does not index itself all the time.
    @Test func filterDropsChangesInsidePackages() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/Users/u"], resolve: { $0 })
        #expect(filter.changedRoots([("/Users/u/Pictures/Photos Library.photoslibrary/resources/a.jpeg", file)]) == [])
        #expect(filter.changedRoots([("/Users/u/Programme/Neu.app", dir)]) == [])
        #expect(filter.changedRoots([("/Users/u/Akten 2024.alt/x.pdf", file)]) == ["/Users/u"], "a dot in a plain folder name")
    }

    @Test func filterDropsPackagesFoundOnDisk() {
        let filter = EventFilter(isHidden: { _ in false }, isPackage: { $0 == "/q/Bundle.xyz" })
        filter.setRoots(["/q"], resolve: { $0 })
        #expect(filter.changedRoots([("/q/Bundle.xyz/inner/x.pdf", file)]) == [])
    }

    @Test func imagesCountOnlyWhenImagesAreIndexed() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q"], includeImages: false, resolve: { $0 })
        #expect(filter.changedRoots([("/q/bild.png", file)]) == [])
        #expect(filter.changedRoots([("/q/r.pdf", file)]) == ["/q"])
        filter.setIncludeImages(true)
        #expect(filter.changedRoots([("/q/bild.png", file)]) == ["/q"])
    }

    @Test func metadataOnlyChangesDoNotCount() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/q"], resolve: { $0 })
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        for meta in [kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemInodeMetaMod,
                     kFSEventStreamEventFlagItemFinderInfoMod, kFSEventStreamEventFlagItemChangeOwner] {
            #expect(filter.changedRoots([("/q/r.pdf", isFile | FSEventStreamEventFlags(meta))]) == [], "„In Vorschau öffnen“ writes an xattr")
        }
        for change in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved,
                       kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemModified] {
            #expect(filter.changedRoots([("/q/r.pdf", isFile | FSEventStreamEventFlags(change))]) == ["/q"])
        }
    }

    @Test func aRootOfSlashMatches() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/"], resolve: { $0 })
        #expect(filter.changedRoots([("/Akten/r.pdf", file)]) == ["/"])
    }

    @Test func rootsThatWentAwayOrCameBackAreUrgent() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/Volumes/Stick/Akten", "/q"], resolve: { $0 })
        let unmount = FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        #expect(filter.urgentRoots([("/Volumes/Stick", unmount)]) == ["/Volumes/Stick/Akten"])
        #expect(filter.urgentRoots([("/q", rootChanged)]) == ["/q"])
        #expect(filter.urgentRoots([("/q/r.pdf", file)]) == [])
    }

    @Test func filterMatchesTheResolvedPathAndReportsTheGivenOne() {
        let filter = EventFilter(isHidden: { _ in false })
        filter.setRoots(["/var/t/Akten"], resolve: { "/private" + $0 })
        #expect(filter.watchedPaths == ["/private/var/t/Akten"])
        #expect(filter.changedRoots([("/private/var/t/Akten/x.pdf", file)]) == ["/var/t/Akten"])
    }
}
