// MainHangWatch.swift — blocked main thread and launch phases in the measurement log (1.4.3)
import Darwin
import Foundation
import Synchronization

/// While the measurement log is on, a timer on a utility queue sends one ping at a time to the main queue every
/// `interval`; a ping answered later than `threshold` writes `main_hang`. A hang still running after `sampleAfter`
/// starts `/usr/bin/sample` on this process once (at most `maxSamples` per session, never two at once), written to
/// `hang-<date>_<time>.txt` in the log folder and named in `main_hang` as `sample`. It also writes `launch_phase` and
/// remembers the last one and the running indexing phase for `main_hang`.
public final class MainHangWatch: Sendable {
    public static let shared = MainHangWatch()

    /// Start of this process (from the kernel), so the time before `main` counts too.
    public static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }()

    /// Milliseconds since the process started, to 0.1 ms.
    public static func msSinceLaunch(_ now: Date = Date()) -> Double {
        (now.timeIntervalSince(processStart) * 10_000).rounded() / 10
    }

    private let metrics: IndexMetrics
    private let threshold: Duration
    private let interval: Duration
    private let sampleAfter: Duration
    private let sampleSeconds: Int
    private let maxSamples: Int
    private let queue = DispatchQueue(label: "local.pdfsucher.hang-watch", qos: .utility)
    private struct State {
        var timer: DispatchSourceTimer?
        var waiting = false
        var sent = ContinuousClock.now
        var sample: String?          // started during the waiting ping
        var sampling = false
        var samples = 0
        var phase = "none"
        var lastLaunchPhase = ""
    }
    private let state = Mutex(State())

    public init(metrics: IndexMetrics = .shared, threshold: Duration = .milliseconds(250), interval: Duration = .milliseconds(100),
                sampleAfter: Duration = .seconds(1), sampleSeconds: Int = 3, maxSamples: Int = 3) {
        self.metrics = metrics
        self.threshold = threshold
        self.interval = interval
        self.sampleAfter = sampleAfter
        self.sampleSeconds = sampleSeconds
        self.maxSamples = maxSamples
    }

    /// The indexing phase running now (`text`, `ocr`, `layout`, `wordparts` or `none`).
    public func setPhase(_ phase: String) { state.withLock { $0.phase = phase } }

    /// `launch_phase` with `ms` since the process started.
    public func launchPhase(_ name: String, _ fields: [String: Any] = [:]) {
        state.withLock { $0.lastLaunchPhase = name }
        metrics.log("launch_phase", fields.merging(["name": name, "ms": Self.msSinceLaunch()]) { a, _ in a })
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let step = Int(IndexMetrics.ms(interval))
        timer.schedule(deadline: .now(), repeating: .milliseconds(step), leeway: .milliseconds(step / 2))
        timer.setEventHandler { [self] in tick() }
        state.withLock { $0.timer?.cancel(); $0.timer = timer }
        timer.resume()
    }

    public func stop() { state.withLock { $0.timer?.cancel(); $0.timer = nil } }

    private func tick() {
        guard metrics.isEnabled else { return }
        let now = ContinuousClock.now
        let (free, sample) = state.withLock { s -> (Bool, String?) in
            guard s.waiting else {
                s.waiting = true
                s.sent = now
                return (true, nil)
            }
            // The last ping still waits: one at a time; a long hang is sampled while it lasts.
            guard s.sample == nil, !s.sampling, s.samples < maxSamples, now - s.sent > sampleAfter else { return (false, nil) }
            let name = "hang-\(Date().formatted(Self.sampleStamp)).txt"
            s.sample = name
            s.sampling = true
            s.samples += 1
            return (false, name)
        }
        if let sample { startSample(sample) }
        guard free else { return }
        let sinceLaunch = Self.msSinceLaunch()
        DispatchQueue.main.async { [self] in
            let late = ContinuousClock.now - now
            let (phase, last, sample) = state.withLock { s in
                s.waiting = false
                defer { s.sample = nil }
                return (s.phase, s.lastLaunchPhase, s.sample)
            }
            guard late > threshold else { return }
            var fields: [String: Any] = ["ms": IndexMetrics.ms(late), "since_launch_ms": sinceLaunch, "phase": phase,
                                         "last_launch_phase": last]
            if let sample { fields["sample"] = sample }
            metrics.log("main_hang", fields)
        }
    }

    /// `sample <pid> <seconds> -file <log folder>/<name>` in the background.
    private func startSample(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        try? FileManager.default.createDirectory(at: metrics.directory, withIntermediateDirectories: true)
        process.arguments = [String(getpid()), String(sampleSeconds), "-file", metrics.directory.appendingPathComponent(name).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] _ in state.withLock { $0.sampling = false } }
        do { try process.run() } catch { state.withLock { $0.sampling = false } }
    }

    /// Local time in the sample's file name, e.g. `2026-11-20_123456`.
    private static let sampleStamp = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian))
}
