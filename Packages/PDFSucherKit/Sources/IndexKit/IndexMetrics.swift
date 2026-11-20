// IndexMetrics.swift — measurement log of the indexing (1.3.9)
import CryptoKit
import Foundation
import Synchronization

/// Writes one JSON object per line to `<directory>/<prefix>-<YYYY-MM-DD>.jsonl` (local date), off by default.
/// Two logs use it: the indexing (`shared`, `index-metrics-…`) and the result rows (`rows`, `ui-rows-…`, 1.4.2).
///
/// Privacy: no file content, no text, no plain path. Files and sources appear only as `hash` (first 12 hex digits of
/// SHA-256 of the absolute path) plus the extension.
/// Off: every `log` returns after one atomic load (fields are an autoclosure, never built).
/// On: the line is encoded on the caller's thread, then buffered and written on a private serial queue (flushed at
/// 32 KB or after 1 s), so no caller waits for the disk.
public final class IndexMetrics: Sendable {
    public static let shared = IndexMetrics(directory: defaultDirectory)
    /// `defaults write local.pdfsucher indexMetricsEnabled -bool NO` (read at launch).
    public static let defaultsKey = "indexMetricsEnabled"
    /// 1.4.3: on unless the user switched it off.
    public static func isEnabledSetting(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
    /// 1.4.2: diagnosis log of the result rows (`ui-rows-<date>.jsonl`, `RowDiagnostics`), off by default.
    public static let rows = IndexMetrics(directory: defaultDirectory, prefix: "ui-rows")
    /// `defaults write local.pdfsucher rowDiagnosticsEnabled -bool YES` (read at launch).
    public static let rowsDefaultsKey = "rowDiagnosticsEnabled"
    /// 1.4.3: the `sample` files of long hangs (`hang-<date>_<time>.txt`, `MainHangWatch`); only listed and deleted here.
    public static let hangs = IndexMetrics(directory: defaultDirectory, prefix: "hang")
    /// Every protocol of the app (export, deleting, cleanup at launch).
    public static let all = [shared, rows, hangs]
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PDFSucher", isDirectory: true)
    }

    /// The run (one AppModel queue step) the current task works for; 0 = none. Set with `$run.withValue`.
    @TaskLocal public static var run = 0

    public let directory: URL
    /// File name start: `index-metrics` or `ui-rows`.
    public let prefix: String
    private let enabled = Atomic(false)
    private let runs = Atomic(0)
    private let queue = DispatchQueue(label: "local.pdfsucher.index-metrics", qos: .utility)
    private struct Output {
        var buffer = Data()
        var day = ""
        var name = ""
        var handle: FileHandle?
        var flushScheduled = false
    }
    private let output = Mutex(Output())      // only touched on `queue`
    private let done = Mutex(Set<String>())

    public init(directory: URL, prefix: String = "index-metrics") {
        self.directory = directory
        self.prefix = prefix
    }

    public var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// Switching on writes `app_start` (`atLaunch`) or `logging_on` with version, build, cores and macOS version.
    public func setEnabled(_ on: Bool, atLaunch: Bool = false) {
        let was = enabled.exchange(on, ordering: .relaxed)
        if on, !was {
            let info = Bundle.main.infoDictionary ?? [:], process = ProcessInfo.processInfo
            log(atLaunch ? "app_start" : "logging_on",
                ["version": info["CFBundleShortVersionString"] as? String ?? "?", "build": info["CFBundleVersion"] as? String ?? "?",
                 "cores": process.processorCount, "active_cores": process.activeProcessorCount,
                 "memory_gb": Int(process.physicalMemory >> 30), "macos": process.operatingSystemVersionString])
        }
        if !on, was { flush() }
    }

    /// A new run id (1, 2, …) for `run_start` and `$run`.
    public func nextRun() -> Int { runs.wrappingAdd(1, ordering: .relaxed).newValue }

    public func log(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard isEnabled else { return }
        let now = Date()
        var line = fields()
        line["event"] = event
        let ts = now.formatted(Self.timestamp)
        line["ts"] = ts
        if line["run"] == nil { line["run"] = Self.run }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let day = String(ts.prefix(10))
        queue.async { [self] in append(data, day: day) }
    }

    /// Records that `phase` finished this file version (`key`: hash, size, date, page …) in this app session; a repeat
    /// writes `reindexed_file` with the time spent again.
    public func noteDone(phase: String, file: String, ext: String, key: String, ms: Double) {
        guard isEnabled else { return }
        let fresh = done.withLock { $0.insert("\(phase)|\(file)|\(key)").inserted }
        if !fresh { log("reindexed_file", ["phase": phase, "file": file, "ext": ext, "key": key, "ms": ms]) }
    }

    /// The protocol files in `directory` (`<prefix>-*.jsonl`, or `.txt` for samples), oldest first.
    public func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix + "-") && ($0.hasSuffix(".jsonl") || $0.hasSuffix(".txt")) }.sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Settings „Mess-Protokolle löschen“: writes what is buffered, closes the open file and deletes every protocol
    /// file. Logging stays as it is; the next line (if on) starts a new file. Other files in the folder stay.
    public func deleteLogs() {
        queue.sync {
            output.withLock { out in
                writeLocked(&out)
                try? out.handle?.close()
                out.handle = nil
                out.name = ""
            }
            for url in logFiles() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 1.4.3, at launch: deletes the protocol files whose date (in the name) is more than `days` days before `now`
    /// (local date), off the caller's thread.
    public func deleteLogs(olderThan days: Int, now: Date = Date()) {
        guard let limit = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let oldest = "\(prefix)-\(limit.formatted(Self.timestamp).prefix(10)).jsonl"
        queue.async { [self] in
            for url in logFiles() where url.lastPathComponent < oldest { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 1.4.3, Settings „Mess-Protokolle exportieren …“: writes what is buffered, then packs every protocol file of
    /// `logs` into the ZIP `zip` (a folder named like the ZIP inside; replaced if it exists).
    public static func export(_ logs: [IndexMetrics] = all, to zip: URL) throws {
        logs.forEach { $0.flush() }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = temp.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        for url in logs.flatMap({ $0.logFiles() }) { try fm.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes the buffer now and waits for it (tests, switching off).
    public func flush() { queue.sync { writeBuffer() } }

    // MARK: Helpers for callers

    /// First 12 hex digits of SHA-256 of the standardized absolute path.
    public static func hash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(path: String) -> String { hash(URL(fileURLWithPath: path)) }

    /// Milliseconds since `start`, to 0.1 ms.
    public static func ms(since start: ContinuousClock.Instant) -> Double { ms(ContinuousClock.now - start) }

    public static func ms(_ duration: Duration) -> Double {
        let (s, atto) = duration.components
        return (Double(s) * 1000 + Double(atto) / 1e15).rounded(toPlaces: 1)
    }

    /// Unix seconds of a modification date, as part of a file-version key.
    public static func stamp(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    // MARK: Writing (on `queue`)

    private func append(_ data: Data, day: String) {
        let flushNow = output.withLock { out -> Bool? in
            if out.day != day { writeLocked(&out); out.day = day }      // a new day: a new file
            out.buffer.append(data)
            if out.buffer.count >= 32 * 1024 { return true }
            if out.flushScheduled { return nil }
            out.flushScheduled = true
            return false
        }
        if flushNow == true { writeBuffer() }
        if flushNow == false { queue.asyncAfter(deadline: .now() + 1) { [self] in writeBuffer() } }
    }

    private func writeBuffer() { output.withLock { writeLocked(&$0) } }

    private func writeLocked(_ out: inout Output) {
        out.flushScheduled = false
        guard !out.buffer.isEmpty else { return }
        defer { out.buffer.removeAll(keepingCapacity: true) }         // cannot write: dropped, never blocks
        let name = "\(prefix)-\(out.day).jsonl"
        if out.handle == nil || out.name != name {
            try? out.handle?.close()
            out.handle = openFile(name)
            out.name = name
        }
        guard let handle = out.handle else { return }
        do { try handle.write(contentsOf: out.buffer) } catch { try? handle.close(); out.handle = nil }
    }

    private func openFile(_ name: String) -> FileHandle? {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
