// PreviewTiming.swift — 1.3.4 Vorschau-Puffer (measurement only)
import AppKit
import Foundation
import os
import OutputKit
import SearchKit

/// Times of a page change in the large preview, for measuring (spec 1.3.4, like `TileTiming`):
/// `log stream --level debug --predicate 'subsystem == "local.pdfsucher" && category == "PreviewTiming"'`.
/// Only the measuring run (`-uiTestAutoNextDocMS`) marks page changes; without one nothing is logged.
@MainActor enum PreviewTiming {
    static let log = Logger(subsystem: "local.pdfsucher", category: "PreviewTiming")
    private static var switched: (ref: PageRef, at: ContinuousClock.Instant)?
    private static var reported: Set<String> = []

    /// The measuring run is about to show `ref`.
    static func switched(to ref: PageRef) {
        switched = (ref, .now)
        reported = []
        log.debug("switch \(name(ref), privacy: .public)")
    }

    /// `event` happened for `ref` (logged once per page change, in ms since it), e.g. `standin.prepared`, `draw`, `sharp`.
    static func event(_ event: String, _ ref: PageRef?) {
        guard let switched, let ref, switched.ref == ref, reported.insert(event).inserted else { return }
        let elapsed = ContinuousClock.now - switched.at
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        log.debug("\(event, privacy: .public) \(String(format: "%.1f", ms), privacy: .public) \(name(ref), privacy: .public)")
    }

    private static func name(_ ref: PageRef) -> String { "\(ref.url.lastPathComponent)#\(ref.pageIndex)" }

    /// `-uiTestAutoNextDocMS <ms>`: once the result has settled (and `-uiTestWaitS` more seconds), moves the focus
    /// like ↓ every `ms` milliseconds (`-uiTestSteps` times, default 40), then quits. Meanwhile logs every main
    /// thread stall over 50 ms (`stall`).
    static func runAutoNext(_ model: any ViewerModel) async {
        let defaults = UserDefaults.standard
        let step = defaults.integer(forKey: "uiTestAutoNextDocMS")
        guard step > 0 else { return }
        var stable = 0, last = -1
        while stable < 15 {
            try? await Task.sleep(for: .milliseconds(200))
            let count = model.hits.count
            stable = count == last && count > 0 ? stable + 1 : 0
            last = count
        }
        try? await Task.sleep(for: .seconds(defaults.integer(forKey: "uiTestWaitS")))
        let watchdog = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let gap = ContinuousClock.now - previous
                let ms = Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15
                if ms > 50 { log.debug("stall \(String(format: "%.0f", ms), privacy: .public)") }
                previous = .now
            }
        }
        let steps = defaults.integer(forKey: "uiTestSteps")
        log.debug("auto.start \(model.hits.count)")
        for _ in 0..<(steps > 0 ? steps : 40) {
            guard let next = FocusNavigator.next(from: model.focusedPage, direction: .down, hits: model.hits,
                                                 showAllPages: model.settings.showAllPages),
                  next != model.focusedPage else { break }
            switched(to: next)
            model.focusedPage = next
            try? await Task.sleep(for: .milliseconds(step))
        }
        log.debug("auto.stop")
        watchdog.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }
}
