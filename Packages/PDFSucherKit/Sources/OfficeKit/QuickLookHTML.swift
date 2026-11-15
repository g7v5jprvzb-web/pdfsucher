// QuickLookHTML.swift — 1.3 Office Task 4: HTML preview from macOS's own Office Quick Look generator.
// There is no public API that hands out a generator's preview (see decisions.md), so this runs
// `/usr/bin/qlmanage -p -o <dir> <file>`, which writes `<dir>/<file name>.qlpreview/Preview.html` + attachments.
import Darwin
import Foundation
import Synchronization

public enum QuickLookError: Error, Equatable {
    /// The generator ran but wrote no HTML (unreadable or unsupported file).
    case noPreview(URL)
    /// The generator did not finish within the time limit; it was stopped.
    case timedOut(URL)
    /// `Office.qlgenerator` (or `qlmanage`) is not on this Mac.
    case generatorMissing
}

/// A generated preview: `html` lies inside `directory`, which belongs to the caller.
public struct QuickLookOutput: Sendable {
    public let directory: URL
    public let html: URL

    /// Deletes `directory` with everything in it.
    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public struct QuickLookHTML: Sendable {
    static let qlmanage = URL(fileURLWithPath: "/usr/bin/qlmanage")
    static let officeGenerator = "/System/Library/QuickLook/Office.qlgenerator"

    /// The program to run; `arguments` gets the output folder and the file.
    struct Command: Sendable {
        var executable: URL
        var arguments: @Sendable (_ directory: URL, _ file: URL) -> [String]

        static let qlmanage = Command(executable: QuickLookHTML.qlmanage) { ["-p", "-o", $0.path, $1.path] }
    }

    private let timeout: Duration
    private let generatorPath: String
    private let command: Command
    /// How long a stopped process gets to exit after SIGTERM before it is killed.
    private let killGrace: Duration
    private let onLaunch: (@Sendable (_ pid: Int32, _ directory: URL) -> Void)?

    public init(timeout: Duration = .seconds(60)) {
        self.init(timeout: timeout, generatorPath: Self.officeGenerator)
    }

    /// For tests: another generator path to check, another program to run instead of `qlmanage`, a shorter
    /// SIGTERM → SIGKILL grace, and a hook called right after the process started.
    init(timeout: Duration = .seconds(60), generatorPath: String = Self.officeGenerator,
         command: Command = .qlmanage, killGrace: Duration = .seconds(2),
         onLaunch: (@Sendable (_ pid: Int32, _ directory: URL) -> Void)? = nil) {
        self.timeout = timeout
        self.generatorPath = generatorPath
        self.command = command
        self.killGrace = killGrace
        self.onLaunch = onLaunch
    }

    /// Erzeugt die Quick-Look-HTML-Vorschau in einem neuen temporären Ordner und gibt die Startdatei zurück.
    /// Aufrufer löscht `directory` (siehe `QuickLookOutput.remove()`).
    ///
    /// Errors (the temporary folder is removed in every case):
    /// - `QuickLookError.generatorMissing`: `Office.qlgenerator` or `qlmanage` is not on this Mac.
    /// - `QuickLookError.noPreview(url)`: `qlmanage` ended without writing `Preview.html`.
    /// - `QuickLookError.timedOut(url)`: over the time limit; the process was stopped and has exited.
    /// - `CancellationError`: the task was cancelled; the process was stopped and has exited.
    /// - Any other error comes unchanged from `FileManager` (creating the temporary folder) or `Process.run()`
    ///   (process could not be started, e.g. process limit reached). They are not mapped to a `QuickLookError`
    ///   because they say nothing about the file; callers treat them as "try again later".
    public func generate(for url: URL) async throws -> QuickLookOutput {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: generatorPath),
              fileManager.isExecutableFile(atPath: command.executable.path) else { throw QuickLookError.generatorMissing }
        try Task.checkCancellation()

        let directory = Self.leftoverRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let removeDirectory = { try? fileManager.removeItem(at: directory) }

        let exit = ExitSignal()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments(directory, url)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exit.signal() }
        do {
            try process.run()
        } catch {
            removeDirectory()
            throw error
        }
        let pid = process.processIdentifier
        onLaunch?(pid, directory)

        let outcome = await waitForExit(of: pid, exit: exit)
        if outcome == .cancelled || Task.isCancelled {
            removeDirectory()
            throw CancellationError()
        }
        if outcome == .timedOut {
            removeDirectory()
            throw QuickLookError.timedOut(url)
        }
        guard let html = Self.previewHTML(in: directory) else {
            removeDirectory()
            throw QuickLookError.noPreview(url)
        }
        return QuickLookOutput(directory: directory, html: html)
    }

    /// `$TMPDIR/PDFSucher-QL`: every preview folder lies directly below it.
    public static var leftoverRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PDFSucher-QL", isDirectory: true)
    }

    /// Removes preview folders a crashed or killed run left behind: every entry below `root` last modified more
    /// than `age` ago (10 min: far beyond the 60 s generator limit and the 120 s layout limit, so a run that is still
    /// working — possibly in another process — is not touched). Returns the number of removed entries; errors are
    /// ignored (best effort). The app calls it once at start (1.3 Teil B).
    @discardableResult
    public static func sweepLeftovers(in root: URL = leftoverRoot, olderThan age: TimeInterval = 10 * 60) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: []) else { return 0 }
        let limit = Date().addingTimeInterval(-age)
        var removed = 0
        for entry in entries {
            guard let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < limit, (try? fileManager.removeItem(at: entry)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    private enum Outcome { case exited, timedOut, cancelled }

    /// Waits until the process exits, the time limit passes, or the task is cancelled; in the last two cases the
    /// process is stopped and this returns only after it has exited (no child process stays behind).
    private func waitForExit(of pid: Int32, exit: ExitSignal) async -> Outcome {
        let timeout = timeout
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await exit.wait(); return .exited }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .exited
            if first != .exited {
                let killTimer = stop(pid, exit: exit)
                await exit.wait()
                killTimer?.cancel() // no SIGKILL timer outlives the process
            }
            group.cancelAll()
            return first
        }
    }

    /// SIGTERM now, SIGKILL if the process is still running after `killGrace`. Returns the pending SIGKILL.
    private func stop(_ pid: Int32, exit: ExitSignal) -> DispatchWorkItem? {
        guard !exit.hasExited else { return nil }
        kill(pid, SIGTERM)
        let killTimer = DispatchWorkItem {
            if !exit.hasExited { kill(pid, SIGKILL) }
        }
        let grace = killGrace.components
        let nanoseconds = grace.seconds * 1_000_000_000 + grace.attoseconds / 1_000_000_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: killTimer)
        return killTimer
    }

    /// `qlmanage` names the folder after the file (`<name>.qlpreview`); it is looked up rather than rebuilt from
    /// the name, so differences in Unicode normalization (umlauts) do not matter.
    static func previewHTML(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".qlpreview") }
            .map { directory.appendingPathComponent($0, isDirectory: true).appendingPathComponent("Preview.html") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Process exit as something to `await` without blocking a thread (fed by `Process.terminationHandler`).
private final class ExitSignal: Sendable {
    private let state = Mutex<(exited: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var hasExited: Bool { state.withLock { $0.exited } }

    func signal() {
        let waiters = state.withLock { state in
            state.exited = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.exited { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
