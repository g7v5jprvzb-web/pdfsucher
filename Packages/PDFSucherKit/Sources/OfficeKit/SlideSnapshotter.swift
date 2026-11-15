// SlideSnapshotter.swift — 1.3 Office Task 6: one image, the text and the word rectangles per slide of Quick Look's
// PowerPoint HTML, via an invisible WKWebView.
import AppKit
import CoreGraphics
import Foundation
import os
import WebKit

enum SlideSnapshotterError: Error, Equatable {
    /// The HTML did not load (WebKit's description).
    case loadFailed(String)
    /// The HTML has another number of slides than the caller expects (`slideNumbers`).
    case slideCountMismatch(found: Int, expected: Int)
    /// WebKit returned no image or no usable slide rectangle.
    case snapshotFailed(slide: Int)
    /// One of our JavaScript calls failed (exception, WebContent process gone) or returned unusable data.
    case scriptFailed(String)
}

/// Renders the slides of a Quick Look PowerPoint preview (`Preview.html`, see `QuickLookHTML`).
///
/// Slides are the `div.slide` elements (`slideSelector`): the generator writes one per *visible* slide, with
/// absolutely positioned children, sized in CSS px = pt (720 × 540 or 960 × 540). Hidden slides are not in the HTML.
///
/// Everything runs on the main actor in short steps (one JavaScript call or one snapshot each) with `await` between
/// them, so the main thread is never blocked for long. Cancellation is checked between steps; the web view is torn
/// down on every exit.
@MainActor final class SlideSnapshotter {
    /// Text and geometry of one slide. The image is not part of it: it goes to the caller's image sink right after
    /// its snapshot, so no list of full-size images builds up (Task 10b: ~10–28 MB per slide otherwise).
    struct Slide: Sendable {
        /// Raw slide text (not normalized): the slide's text nodes in document order, `\n` between blocks.
        let text: String
        /// Whitespace-separated words of `text` (UTF-16 ranges) with their rectangle in slide points, origin top left.
        let wordRects: [(range: NSRange, rect: CGRect)]
        /// Slide size in points.
        let size: CGSize
    }

    /// Points where tests can step in (cancel, inject a failure, keep a weak reference to the view).
    enum Step: Equatable, Sendable { case beforeLoad, afterLoad, beforeImageWait, beforeWarmUp, beforeSlide(Int) }
    typealias Hook = @MainActor @Sendable (Step, SnapshotWebView) async throws -> Void
    /// Receives each slide image (index, image) right after its snapshot, in order. `@concurrent`: always runs on
    /// the global concurrent executor, never on the caller's (main) actor, also if nonisolated async functions
    /// should one day default to the caller's actor (NonisolatedNonsendingByDefault); so HEIC encoding there never
    /// blocks the main thread. An error ends `slides`.
    typealias ImageSink = @concurrent @Sendable (Int, CGImage) async throws -> Void

    /// How many snapshots had to be rescaled because WebKit's image was not the requested pixel size (for tests:
    /// stays 0 when the backing-scale guess is right, i.e. no blurry upscale).
    private(set) static var rescaleCount = 0
    fileprivate static func noteRescale() { rescaleCount += 1 }

    private let hook: Hook?

    init(hook: Hook? = nil) { self.hook = hook }

    /// One element per visible slide in Quick Look's HTML (spike `~/Developer/PDFSucher-spikes/macos-preview/`).
    static let slideSelector = "div.slide"
    /// How long to wait for `document.images` to complete.
    static let imageWait: Duration = .seconds(5)
    /// Extra settling time after loading: WebKit decodes `<img src="*.pdf">` (converted EMF/WMF) only when it first
    /// draws them; without this, parts were missing from the first snapshots in the spike.
    static let settle: Duration = .seconds(1)

    /// - Parameter slideNumbers: PowerPoint number of each slide in the HTML, in order. Slide-number fields
    ///   (`‹#›`, as the generator writes them, or `<#>`) are replaced by it in the page before the snapshot and the
    ///   text. A different slide count throws `SlideSnapshotterError.slideCountMismatch` before any snapshot.
    /// - Parameter maxPixel: long side of each image in pixels.
    /// - Parameter image: gets every slide image once, in slide order, before the next slide is rendered.
    func slides(fromHTML html: URL, readAccess dir: URL, maxPixel: Int, slideNumbers: [Int],
                image sink: ImageSink) async throws -> [Slide] {
        let view = SnapshotWebView()
        defer { view.tearDown() }
        try await hook?(.beforeLoad, view)
        try await view.load(html, readAccess: dir)
        try await hook?(.afterLoad, view)

        let count = try await view.int("return document.querySelectorAll(selector).length")
        guard count == slideNumbers.count else {
            throw SlideSnapshotterError.slideCountMismatch(found: count, expected: slideNumbers.count)
        }
        guard count > 0 else { return [] }
        _ = try await view.call(Self.replaceSlideNumbers, ["numbers": slideNumbers])

        let first = try await view.decode(SlideRect.self, "return JSON.stringify(slideRect(0))", preamble: true)
        guard first.width > 0, first.height > 0 else { throw SlideSnapshotterError.snapshotFailed(slide: 0) }
        // Viewport a bit larger than one slide, so a slide scrolled to the top is completely inside it.
        view.resize(to: CGSize(width: first.x * 2 + first.width + 40, height: first.height + 40))

        try await hook?(.beforeImageWait, view)
        try await waitForImages(view)
        try await hook?(.beforeWarmUp, view)
        try await warmUp(view, count: count)

        var slides: [Slide] = []
        slides.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            try await hook?(.beforeSlide(index), view)
            let (slide, image) = try await slide(index, in: view, maxPixel: maxPixel)
            try await sink(index, image)
            slides.append(slide)
        }
        return slides
    }

    // MARK: Steps

    private func waitForImages(_ view: SnapshotWebView) async throws {
        let deadline = ContinuousClock.now + Self.imageWait
        while ContinuousClock.now < deadline {
            let done = try await view.bool("return Array.from(document.images).every(i => i.complete)")
            if done { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Scrolls every slide into view once (~50 ms each, as in the spike), so WebKit decodes lazily loaded images
    /// (PDF from EMF/WMF and others), then waits `settle`.
    private func warmUp(_ view: SnapshotWebView, count: Int) async throws {
        for index in 0..<count {
            _ = try await view.call("document.querySelectorAll(selector)[\(index)].scrollIntoView({block: 'start'})")
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: Self.settle)
    }

    private func slide(_ index: Int, in view: SnapshotWebView, maxPixel: Int) async throws -> (Slide, CGImage) {
        let content = try await view.decode(SlideContent.self, "return JSON.stringify(slideContent(\(index)))", preamble: true)
        guard content.width > 0, content.height > 0 else { throw SlideSnapshotterError.snapshotFailed(slide: index) }
        let words = Self.wordRanges(in: content.text)
        var wordRects: [(range: NSRange, rect: CGRect)] = []
        if !words.isEmpty {
            let rects = try await view.decode([[Double]?].self, "return JSON.stringify(wordRects(\(index), ranges))",
                                              preamble: true, arguments: ["ranges": words.map { [$0.location, $0.length] }])
            for (range, rect) in zip(words, rects) {
                guard let rect, rect.count == 4, rect[2] > 0, rect[3] > 0 else { continue }
                wordRects.append((range, CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])))
            }
        }
        let size = CGSize(width: content.width, height: content.height)
        let image = try await view.snapshot(CGRect(x: content.x, y: content.y, width: content.width, height: content.height),
                                            pixelSize: Self.pixelSize(of: size, longSide: maxPixel), slide: index)
        return (Slide(text: content.text, wordRects: wordRects, size: size), image)
    }

    static func pixelSize(of size: CGSize, longSide: Int) -> (width: Int, height: Int) {
        let scale = Double(longSide) / Double(max(size.width, size.height))
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// Words as `TextNormalizer` splits them: runs between whitespace, control and private-use characters.
    nonisolated static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !isSeparator(text[index]) else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !isSeparator(text[end]) { end = text.index(after: end) }
            ranges.append(NSRange(index..<end, in: text))
            index = end
        }
        return ranges
    }

    nonisolated private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .privateUse
        }
    }

    // MARK: JavaScript

    private struct SlideRect: Decodable { let x, y, width, height: Double }
    private struct SlideContent: Decodable { let text: String; let x, y, width, height: Double }

    private static let replaceSlideNumbers = """
        const slides = document.querySelectorAll(selector);
        slides.forEach((slide, i) => {
            const walker = document.createTreeWalker(slide, NodeFilter.SHOW_TEXT);
            for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                if (n.data.includes('\u{2039}#\u{203A}') || n.data.includes('<#>')) {
                    n.data = n.data.split('\u{2039}#\u{203A}').join(String(numbers[i])).split('<#>').join(String(numbers[i]));
                }
            }
        });
        return true
        """

    /// Helpers prepended to calls with `preamble: true`. `slideContent` stores the text-node map of the slide it
    /// read in `window.__pdfsucherSegments`; `wordRects` uses it, so both see the same text.
    fileprivate static let preamble = """
        function slideRect(i) {
            const s = document.querySelectorAll(selector)[i];
            s.scrollIntoView({block: 'start'});
            const r = s.getBoundingClientRect();
            return {x: r.left, y: r.top, width: r.width, height: r.height};
        }
        function charRect(node, i) {
            if (i < 0 || i >= node.data.length) return null;
            const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 1);
            const rs = r.getClientRects(); return rs.length ? rs[0] : null;
        }
        function slideContent(i) {
            const slide = document.querySelectorAll(selector)[i];
            const box = slideRect(i);
            const blockOf = (node) => {
                for (let e = node.parentElement; e && e !== slide; e = e.parentElement) {
                    const cs = getComputedStyle(e);
                    if (cs.position === 'absolute' || cs.position === 'fixed' || !cs.display.startsWith('inline')) return e;
                }
                return slide;
            };
            const space = /\\s/;
            let text = '', prevNode = null, prevBlock = null;
            const segments = [];
            const walker = document.createTreeWalker(slide, NodeFilter.SHOW_TEXT);
            for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                if (!n.data.length || !n.parentElement || n.parentElement.closest('style,script')) continue;
                const all = document.createRange(); all.selectNodeContents(n);
                if (!all.getClientRects().length) continue; // not rendered
                const block = blockOf(n);
                if (prevNode) {
                    if (block !== prevBlock) {
                        text += '\\n';
                    } else if (!space.test(text[text.length - 1]) && !space.test(n.data[0])) {
                        // Visibly apart (e.g. a bullet span with padding) → separate words.
                        const a = charRect(prevNode, prevNode.data.length - 1), b = charRect(n, 0);
                        if (a && b && a.top < b.bottom && b.top < a.bottom &&
                            b.left - a.right > 0.15 * Math.min(a.height, b.height)) text += ' ';
                    }
                }
                segments.push({node: n, start: text.length});
                text += n.data;
                prevNode = n; prevBlock = block;
            }
            window.__pdfsucherSegments = segments;
            return {text: text, x: box.x, y: box.y, width: box.width, height: box.height};
        }
        // Text node and offset of a UTF-16 offset in the slide text: a word's first character (start) or the position
        // just after its last character (end); null inside an inserted separator.
        function position(offset, isEnd) {
            const segs = window.__pdfsucherSegments;
            let lo = 0, hi = segs.length - 1, found = -1;
            while (lo <= hi) {
                const mid = (lo + hi) >> 1, s = segs[mid].start;
                if (isEnd ? s < offset : s <= offset) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
            }
            if (found < 0) return null;
            const seg = segs[found], local = offset - seg.start;
            if (isEnd ? local > seg.node.data.length : local >= seg.node.data.length) return null;
            return {node: seg.node, offset: local};
        }
        function wordRects(i, ranges) {
            const slide = document.querySelectorAll(selector)[i];
            const origin = slide.getBoundingClientRect();
            return ranges.map(([start, length]) => {
                const a = position(start, false), b = position(start + length, true);
                if (!a || !b) return null;
                const r = document.createRange();
                try { r.setStart(a.node, a.offset); r.setEnd(b.node, b.offset); } catch (e) { return null; }
                let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
                for (const c of r.getClientRects()) {
                    if (c.width <= 0 || c.height <= 0) continue;
                    left = Math.min(left, c.left); top = Math.min(top, c.top);
                    right = Math.max(right, c.right); bottom = Math.max(bottom, c.bottom);
                }
                if (!(right > left && bottom > top)) return null;
                return [left - origin.left, top - origin.top, right - left, bottom - top];
            });
        }
        """
}

/// The invisible web view and its load/snapshot plumbing. Every WebKit or decoding error becomes a
/// `SlideSnapshotterError` (the file cannot be previewed); cancellation stays `CancellationError`, and a network block
/// list that cannot be compiled is `NetworkBlockUnavailable` (try again later). Nothing non-local is ever loaded.
@MainActor final class SnapshotWebView: NSObject, WKNavigationDelegate {
    private static let log = Logger(subsystem: "local.pdfsucher", category: "SlideSnapshotter")
    /// The web view; nil after `tearDown`.
    private(set) var view: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false // our calls still run
        configuration.suppressesIncrementalRendering = true
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600), configuration: configuration)
        super.init()
        view?.navigationDelegate = self
    }

    /// Blocks every request that is not local (`file:`, plus `data:`/`blob:`/`about:`, which never touch the
    /// network): Quick Look's HTML of a foreign deck may reference http(s) images, styles or frames, and loading
    /// them would leak that the file is being looked at. The navigation policy below additionally allows only
    /// local navigations. Compiled once per process and reused.
    static let networkBlockRules = """
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}]
        """
    private static var networkBlocker: Task<WKContentRuleList, Error>?

    /// The compiled rule list; a failed compile is retried on the next call.
    private static func networkBlockList() async throws -> WKContentRuleList {
        let task = networkBlocker ?? Task { @MainActor in
            guard let store = WKContentRuleListStore.default() else { throw NetworkBlockUnavailable() }
            guard let list = try await store.compileContentRuleList(forIdentifier: "PDFSucherBlockNetwork",
                                                                    encodedContentRuleList: networkBlockRules) else {
                throw NetworkBlockUnavailable()
            }
            return list
        }
        networkBlocker = task
        do {
            return try await task.value
        } catch {
            if networkBlocker == task { networkBlocker = nil }
            log.error("Could not compile the network block list: \(String(describing: error), privacy: .public)")
            throw NetworkBlockUnavailable()
        }
    }

    /// The network block list could not be compiled: nothing is loaded. Deliberately not a
    /// `SlideSnapshotterError` (that would mark the deck unreadable for good); the Indexer retries next run.
    struct NetworkBlockUnavailable: Error {}

    static func isLocal(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["file", "about", "data", "blob"].contains(scheme)
    }

    func load(_ html: URL, readAccess dir: URL) async throws {
        guard view != nil else { throw CancellationError() }
        let blocker = try await Self.networkBlockList()
        try Task.checkCancellation()
        guard let view else { throw CancellationError() }
        view.configuration.userContentController.removeAllContentRuleLists()
        view.configuration.userContentController.add(blocker)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                loading = continuation
                view.loadFileURL(html, allowingReadAccessTo: dir)
            }
        } onCancel: {
            Task { @MainActor in self.finishLoading(CancellationError()) }
        }
    }

    func resize(to size: CGSize) {
        view?.frame = CGRect(origin: .zero, size: size)
    }

    /// Runs `body` as an async JavaScript function in our own content world, with `selector` and `arguments` bound.
    func call(_ body: String, _ arguments: [String: Any] = [:], preamble: Bool = false) async throws -> Any? {
        guard let view else { throw CancellationError() }
        try Task.checkCancellation()
        var all = arguments
        all["selector"] = SlideSnapshotter.slideSelector
        let source = preamble ? SlideSnapshotter.preamble + "\n" + body : body
        do {
            return try await view.callAsyncJavaScript(source, arguments: all, in: nil, contentWorld: .defaultClient)
        } catch {
            throw Self.mapped(error) { SlideSnapshotterError.scriptFailed(String(describing: $0)) }
        }
    }

    /// Cancellation (or a call that failed because the task was cancelled) → `CancellationError`, else `other`.
    private static func mapped(_ error: Error, _ other: (Error) -> SlideSnapshotterError) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is SlideSnapshotterError { return error }
        return other(error)
    }

    func int(_ body: String) async throws -> Int { (try await call(body) as? NSNumber)?.intValue ?? 0 }
    func bool(_ body: String) async throws -> Bool { (try await call(body) as? NSNumber)?.boolValue ?? false }

    func decode<T: Decodable>(_ type: T.Type, _ body: String, preamble: Bool = false,
                              arguments: [String: Any] = [:]) async throws -> T {
        guard let json = try await call(body, arguments, preamble: preamble) as? String else {
            throw SlideSnapshotterError.scriptFailed("JavaScript lieferte keinen JSON-Text")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw SlideSnapshotterError.scriptFailed(String(describing: error))
        }
    }

    /// Snapshot of `rect` (view points) as a CGImage of exactly `pixelSize`.
    func snapshot(_ rect: CGRect, pixelSize: (width: Int, height: Int), slide: Int) async throws -> CGImage {
        guard let view else { throw CancellationError() }
        try Task.checkCancellation()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        configuration.snapshotWidth = NSNumber(value: Double(pixelSize.width) / Double(scale))
        let image: NSImage
        do {
            image = try await view.takeSnapshot(configuration: configuration)
        } catch {
            throw Self.mapped(error) { _ in SlideSnapshotterError.snapshotFailed(slide: slide) }
        }
        // Own pool: AppKit may autorelease a decoded copy; drain it per slide, not per run loop turn.
        guard let cgImage = autoreleasepool(invoking: { image.cgImage(forProposedRect: nil, context: nil, hints: nil) }) else {
            throw SlideSnapshotterError.snapshotFailed(slide: slide)
        }
        if cgImage.width == pixelSize.width, cgImage.height == pixelSize.height { return cgImage }
        Self.log.debug("Rescaling slide \(slide) snapshot \(cgImage.width)×\(cgImage.height) → \(pixelSize.width)×\(pixelSize.height)")
        SlideSnapshotter.noteRescale()
        return try Self.redraw(cgImage, to: pixelSize, slide: slide)
    }

    /// Scales to exactly `size` (WebKit's own scale can differ by a pixel, or the backing scale was a guess).
    private static func redraw(_ image: CGImage, to size: (width: Int, height: Int), slide: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SlideSnapshotterError.snapshotFailed(slide: slide) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = ctx.makeImage() else { throw SlideSnapshotterError.snapshotFailed(slide: slide) }
        return scaled
    }

    func tearDown() {
        finishLoading(CancellationError())
        view?.stopLoading()
        view?.navigationDelegate = nil
        view = nil
    }

    private func finishLoading(_ error: Error?) {
        guard let continuation = loading else { return }
        loading = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let local = Self.isLocal(navigationAction.request.url)
        if !local { Self.log.notice("Blocked a non-local navigation in a slide preview") }
        decisionHandler(local ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(SlideSnapshotterError.loadFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(SlideSnapshotterError.loadFailed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(SlideSnapshotterError.loadFailed("WebContent-Prozess beendet"))
    }
}
