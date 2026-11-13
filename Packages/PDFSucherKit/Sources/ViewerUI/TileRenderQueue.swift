// TileRenderQueue.swift — 1.2.3 tile cache
import AppKit
import Foundation

/// A few dedicated threads that render tiles in parallel (spec 1.2.3).
///
/// - Visible tiles go before prefetched ones; within a priority the newest request goes first, so
///   after fast scrolling the tiles now on screen render first, not those scrolled past.
/// - A request whose task is cancelled (its tile scrolled away) leaves the queue before it starts.
///   A job already running finishes and fills the cache: the work is not wasted.
/// - Two requests for the same key share one job.
///
/// Dedicated threads, not the cooperative pool: page drawing blocks for up to a few hundred ms per
/// scanned page and must neither starve nor be starved by indexing and text recognition.
final class TileRenderQueue: @unchecked Sendable {
    enum Priority: Int, Comparable {
        case prefetch, visible
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// A job's identity: any Sendable key (wrapping it keeps the Sendable check of the closures).
    struct Key: Hashable, @unchecked Sendable {
        private let base: AnyHashable
        init(_ base: some Hashable & Sendable) { self.base = AnyHashable(base) }
    }

    private final class Job {
        let key: Key
        var priority: Priority
        var seq: UInt64
        let isPrefetch: Bool
        let work: @Sendable () -> NSImage?
        var waiters: [UInt64: CheckedContinuation<NSImage?, Never>] = [:]
        var started = false

        init(key: Key, priority: Priority, seq: UInt64, work: @escaping @Sendable () -> NSImage?) {
            self.key = key
            self.priority = priority
            self.seq = seq
            self.isPrefetch = priority == .prefetch
            self.work = work
        }
    }

    /// Shared by all caches, so tests that create many caches do not create many threads.
    static let shared = TileRenderQueue(workers: defaultWorkers)
    /// Half the cores, 2 to 6: enough to hide a slow page, and leaves room for indexing and the UI.
    static var defaultWorkers: Int { min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 6) }

    let workers: Int
    /// Waiting prefetch jobs at most; older ones are dropped (the user scrolled on).
    let maxPrefetch: Int
    private let condition = NSCondition()
    private var pending: [Job] = []
    private var jobs: [Key: Job] = [:]      // pending or running
    private var nextSeq: UInt64 = 0
    private var nextWaiter: UInt64 = 0
    private(set) var startedCount = 0

    init(workers: Int, maxPrefetch: Int = 64) {
        self.workers = max(workers, 1)
        self.maxPrefetch = max(maxPrefetch, 0)
    }

    private var threadsStarted = false

    /// Threads start with the first job (call with `condition` locked). They live as long as the app.
    private func startThreadsIfNeeded() {
        guard !threadsStarted else { return }
        threadsStarted = true
        for i in 0..<workers { Self.spawn(self, name: "local.pdfsucher.tiles.\(i)") }
    }

    private static func spawn(_ queue: TileRenderQueue, name: String) {
        let thread = Thread { queue.run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `work` on a render thread (or joins a job with the same key) and returns its result;
    /// nil when the calling task is cancelled before the result is there.
    func image(key: some Hashable & Sendable, priority: Priority, work: @escaping @Sendable () -> NSImage?) async -> NSImage? {
        let key = Key(key)
        let waiter = condition.withLock { () -> UInt64 in nextWaiter += 1; return nextWaiter }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                condition.lock()
                // The cancel handler may have run before the continuation was registered.
                if Task.isCancelled {
                    condition.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                let job = enqueue(key: key, priority: priority, work: work)
                job.waiters[waiter] = continuation
                condition.unlock()
            }
        } onCancel: {
            condition.lock()
            guard let job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else {
                condition.unlock()
                return
            }
            if job.waiters.isEmpty, !job.started {
                if job.isPrefetch {
                    job.priority = .prefetch
                } else {
                    pending.removeAll { $0 === job }
                    jobs.removeValue(forKey: key)
                }
            }
            condition.unlock()
            continuation.resume(returning: nil)
        }
    }

    /// Queues `work` at prefetch priority without waiting for it.
    func prefetch(key: some Hashable & Sendable, work: @escaping @Sendable () -> NSImage?) {
        condition.withLock { _ = enqueue(key: Key(key), priority: .prefetch, work: work) }
    }

    /// Number of jobs waiting (tests).
    var pendingCount: Int { condition.withLock { pending.count } }

    // MARK: - Private (call with `condition` locked)

    private func enqueue(key: Key, priority: Priority, work: @escaping @Sendable () -> NSImage?) -> Job {
        nextSeq += 1
        if let job = jobs[key] {
            if !job.started {
                job.priority = max(job.priority, priority)
                job.seq = nextSeq           // asked again: it is on screen now
            }
            return job
        }
        startThreadsIfNeeded()
        let job = Job(key: key, priority: priority, seq: nextSeq, work: work)
        pending.append(job)
        jobs[key] = job
        if priority == .prefetch { dropOldPrefetches() }
        condition.signal()
        return job
    }

    private func dropOldPrefetches() {
        let waiting = pending.filter { $0.priority == .prefetch && $0.waiters.isEmpty }
        guard waiting.count > maxPrefetch else { return }
        let drop = waiting.sorted { $0.seq < $1.seq }.prefix(waiting.count - maxPrefetch)
        let ids = Set(drop.map { ObjectIdentifier($0) })
        pending.removeAll { ids.contains(ObjectIdentifier($0)) }
        for job in drop { jobs.removeValue(forKey: job.key) }
    }

    private func run() {
        while true {
            condition.lock()
            while pending.isEmpty { condition.wait() }
            var best = 0
            for i in pending.indices.dropFirst() {
                let a = pending[i], b = pending[best]
                if a.priority > b.priority || (a.priority == b.priority && a.seq > b.seq) { best = i }
            }
            let job = pending.remove(at: best)
            job.started = true
            startedCount += 1
            condition.unlock()

            let image = autoreleasepool { job.work() }

            condition.lock()
            if jobs[job.key] === job { jobs.removeValue(forKey: job.key) }
            let waiters = job.waiters.values
            job.waiters = [:]
            condition.unlock()
            for waiter in waiters { waiter.resume(returning: image) }
        }
    }
}
