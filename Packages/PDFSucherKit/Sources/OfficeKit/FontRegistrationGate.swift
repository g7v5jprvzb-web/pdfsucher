// FontRegistrationGate.swift — OfficeKit: waits for Office's font registration, but not for ever.
import Dispatch
import Foundation
import OOXMLKit
import Synchronization

/// Lets Word layout wait for the process-wide registration of Office's fonts (`FontResolver.prewarm()`), at most
/// `timeout` in all. The registration may wait for the macOS prompt „PDFSucher möchte auf Daten anderer Apps
/// zugreifen“ (Office's font cache); when the user denies it or does not answer, layout goes on with substitute
/// fonts after the timeout and never waits again.
///
/// Only the layout phase starts it (`start()`/`wait()`: `TextKitWordSource`, the AppModel prewarm); display paths
/// (tiles, preview, output, page counts) only `join()`: they wait for a registration already running, up to the same
/// deadline, and otherwise go on at once with the fonts registered so far – so a display never brings up the prompt.
///
/// The first `start()` runs the registration once on a thread of its own at the caller's QoS and sets the deadline;
/// waiting callers wait until it is done or the deadline has passed, whichever comes first. After the deadline every
/// wait returns at once. Safe from any thread.
///
/// A thread of its own, not GCD's global queues nor Swift's pool: those are width-limited, and the waiters themselves
/// fill them. With every cooperative thread blocked in `wait()` (Word layouts in tasks), the kernel admits no new
/// thread for `DispatchQueue.global` work at that QoS, so a registration queued there did not start before some
/// waiter's deadline had passed – up to 4.9 s in test runs, every layout then ran with substitute fonts (1.3.2).
public final class FontRegistrationGate: Sendable {
    /// How a caller treats the registration.
    public enum Mode: Sendable {
        /// Start it if needed, then wait (layout).
        case start
        /// Wait only for one already started (display).
        case join
        /// Do not wait at all (tiles, office-speed): drawn again once the fonts are there (`+fonts` in the tile key).
        case skip
    }

    /// How long callers wait for the registration in all: more than OOXMLKit's 2 s limit for the cloud font cache
    /// plus the DFonts registration.
    static let sharedTimeout = DispatchTimeInterval.seconds(3)
    /// The gate Word documents use: `FontResolver.prewarm()`, `sharedTimeout`.
    /// Complete only with Office's cloud fonts read in time (`FontResolver.officeFontsIncomplete`).
    public static let shared = FontRegistrationGate(timeout: sharedTimeout, register: { FontResolver.prewarm() },
                                                    complete: { !FontResolver.officeFontsIncomplete })

    private let timeout: DispatchTimeInterval
    private let register: @Sendable () -> Void
    private let complete: @Sendable () -> Bool
    private let done = DispatchGroup()
    private let deadline = Mutex<DispatchTime?>(nil)

    /// - Parameter complete: asked once the registration is done: whether it got every font it looked for (the
    ///   shared gate: Office's cloud fonts not given up). Default yes.
    public init(timeout: DispatchTimeInterval, register: @escaping @Sendable () -> Void,
                complete: @escaping @Sendable () -> Bool = { true }) {
        self.timeout = timeout
        self.register = register
        self.complete = complete
    }

    /// Starts the registration unless it has started; does not wait. Returns the deadline.
    @discardableResult
    public func start() -> DispatchTime {
        let (until, first) = deadline.withLock { deadline -> (DispatchTime, Bool) in
            if let deadline { return (deadline, false) }
            let until = DispatchTime.now() + timeout
            deadline = until
            done.enter()
            return (until, true)
        }
        if first {
            let register = self.register, done = self.done
            let thread = Thread {
                register()
                done.leave()
            }
            // At the first caller's QoS (it waits for this; a lower one could be starved while the CPUs are busy).
            thread.qualityOfService = Self.threadQoS(qos_class_self())
            thread.name = "OfficeKit.FontRegistrationGate"
            thread.start()
        }
        return until
    }

    /// The caller's QoS class as a `Thread` QoS (unspecified/default → `.default`).
    static func threadQoS(_ qos: qos_class_t) -> QualityOfService {
        switch qos {
        case QOS_CLASS_USER_INTERACTIVE: .userInteractive
        case QOS_CLASS_USER_INITIATED: .userInitiated
        case QOS_CLASS_UTILITY: .utility
        case QOS_CLASS_BACKGROUND: .background
        default: .default
        }
    }

    /// Starts the registration if needed and blocks until it is done or the deadline has passed. True when done.
    @discardableResult
    public func wait() -> Bool {
        done.wait(timeout: start()) == .success
    }

    /// Blocks only for a registration already started, until it is done or the deadline has passed; returns at once
    /// when none has started. True when it is done.
    @discardableResult
    public func join() -> Bool {
        guard let until = deadline.withLock({ $0 }) else { return false }
        return done.wait(timeout: until) == .success
    }

    /// Whether the registration has started and finished (not merely passed its deadline). Does not wait.
    public var isDone: Bool {
        deadline.withLock { $0 } != nil && done.wait(timeout: .now()) == .success
    }

    /// The one predicate for „Office's fonts are there“ (1.3.2): done (`isDone`) and complete – not when the
    /// registration gave up on the cloud fonts. Decides the font state everywhere: Word documents
    /// (`laidOutWithOfficeFonts`, the document cache key), `TextKitWordSource.staleRenderers`, Word tile keys
    /// (`OfficePages.contentVersion`). In a process that missed the cloud fonts it stays false for good, so nothing
    /// is laid out again and again. Does not wait.
    public var isComplete: Bool { isDone && complete() }

    /// Runs `body` (on a utility queue) once the registration has finished – also when that comes after every
    /// waiter's deadline. Nothing when it has not been started.
    public func notifyWhenDone(_ body: @escaping @Sendable () -> Void) {
        guard deadline.withLock({ $0 }) != nil else { return }
        done.notify(queue: .global(qos: .utility), execute: body)
    }

    /// `wait()` or `join()`.
    @discardableResult
    public func pass(_ mode: Mode) -> Bool {
        switch mode {
        case .start: wait()
        case .join: join()
        case .skip: isDone
        }
    }
}
