// TextKitWordDocument.swift — 1.3 Office Task 7: interim Word layout with NSAttributedString + TextKit 1.
import AppKit
import Foundation
import OOXMLKit
import IndexKit
import OSLog
import Synchronization

/// A Word document (`.docx`/`.docm`/`.dotx` via `.officeOpenXML`, `.doc` via `.docFormat`) imported by AppKit and
/// broken into pages by TextKit 1: one `NSTextContainer` per page (page size minus margins, no line fragment padding)
/// until all text is set. Hard page breaks arrive from the importer as U+000C and are container breaks in TextKit.
/// The importer drops images and styles; tables keep their grid (spike C). One page size for the whole document
/// (`WordPageSetup`). A trailing page that holds only whitespace (e.g. the paragraph mark after a final page break) is
/// left out; an empty document has one empty page. When pagination stops early (nothing fits on an empty page, or
/// `maxPages`), the text not laid out is appended to the last page's text (without word boxes), so it stays searchable.
/// The importer drops headers, footers and footnotes; text boxes arrive as ordinary paragraphs (decisions.md).
///
/// Immutable after `init`. All TextKit work of Word documents (not TextKit in general) – import and layout in `init`, `page(_:)`,
/// `draw(page:in:)` (and `thumbnail`, which draws) – runs one at a time, process-wide, under `textKit`, so the instance
/// can be shared between threads. Runs on the calling thread, never the main thread (decisions.md).
///
/// Order, always: `FontRegistrationGate.pass` (may wait up to 3 s) → `textKit` → `FontResolver.withStableFonts` (font
/// gate, shared). Never the other way round, never nested (`thumbnail` → `draw` takes `textKit` once, `page` and
/// `draw` do not call each other). Font registrations take only the font gate (exclusive), never `textKit`.
public final class TextKitWordDocument: @unchecked Sendable {
    static let unreadableReason = "Word-Dokument nicht lesbar"
    /// Upper bound against runaway pagination; the Indexer's 120 s timeout bounds it as well.
    static let maxPages = 10_000
    /// office-speed: 16 (was 4; a raster of 8 Word files imported them again and again). `cacheMaxPages` is the bound
    /// that matters for memory.
    static let cacheCapacity = 16
    /// Spec §8 „Obergrenze nach Speicher“: at most this many pages across the cached documents (≈ 0.3 MB per page
    /// measured, so ≈ 600 MB); the most recently used document always stays.
    static let cacheMaxPages = 2_000

    private static let log = Logger(subsystem: "PDFSucher", category: "TextKitWord")

    /// The one lock for all Word TextKit work in this process (see above). A rare „attempted layout while textStorage
    /// is editing“ in the test suite remained with the font gate alone (1 in 20 OfficeKit runs); TextKit 1 off the main
    /// thread is not documented as safe for parallel use, so Word layouts no longer run beside each other.
    static let textKit = NSLock()
    /// Display paths (tiles, preview, output) waiting for or about to take `textKit` (office-speed).
    private static let displaysWaiting = Atomic<Int>(0)

    /// Who takes `textKit`: display paths go first; layout work steps aside while one waits.
    enum Turn {
        /// Tiles, preview, output, page counts.
        case display
        /// The index layout: waits while a display path waits, and paginates in chunks (`yieldsToDisplay`).
        case layout
    }

    /// `body` under `textKit` (and nothing else). `.layout` first waits until no display path is waiting; a display
    /// path that comes during `body` waits for it (one import, one chunk of pages or one page), not for the whole
    /// layout. Same lock order as before: gate → `textKit` → `withStableFonts`.
    static func withTextKit<T>(_ turn: Turn, _ body: () throws -> T) rethrows -> T {
        let asked = ContinuousClock.now
        switch turn {
        case .display:
            displaysWaiting.add(1, ordering: .sequentiallyConsistent)
            textKit.lock()
            displaysWaiting.subtract(1, ordering: .sequentiallyConsistent)
        case .layout:
            while true {
                while yieldsToDisplay { usleep(200) }
                textKit.lock()
                // A display path that came meanwhile goes first (it may already sit at `lock()`).
                guard yieldsToDisplay else { break }
                textKit.unlock()
            }
        }
        // 1.5.0: wait and hold time per turn, summed every 5 s in the measurement log (`textkit_lock`).
        let acquired = ContinuousClock.now
        defer {
            textKit.unlock()
            MetricsTally.shared.add("textkit_lock", key: ["turn": turn == .display ? "display" : "layout"],
                                    ms: ["wait": IndexMetrics.ms(acquired - asked), "hold": IndexMetrics.ms(since: acquired)])
        }
        return try body()
    }

    /// Whether a display path waits for `textKit` (layout work holding it should let go soon).
    static var yieldsToDisplay: Bool { displaysWaiting.load(ordering: .sequentiallyConsistent) > 0 }
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let containers: [NSTextContainer]
    private let setup: WordPageSetup
    /// Start of the text that did not fit (pagination stopped early), appended to the last page; nil normally.
    private let overflowLocation: Int?
    /// Whether Office's fonts were complete (`FontRegistrationGate.isComplete`) when this document was laid out;
    /// false = substitute fonts (deadline passed, or a display path that only joined). `TextKitWordSource` stores it
    /// in the renderer name, so the index lays such a document out again once the fonts are there (1.3.2).
    public let laidOutWithOfficeFonts: Bool

    public convenience init(url: URL) throws {
        try self.init(url: url, maxPages: Self.maxPages)
    }

    /// Throws `LayoutSourceError.unreadable` when the importer rejects the file (not a Word document, damaged,
    /// encrypted); a missing or unreadable file (no permission) throws the original Cocoa error. Checks Task
    /// cancellation between pages (`CancellationError`). `fontGate`: Office's font registration (tests pass their own);
    /// `fonts`: `.start` for layout, `.join` for display paths (never start the registration).
    init(url: URL, maxPages: Int, fontGate: FontRegistrationGate = .shared, fonts: FontRegistrationGate.Mode = .join) throws {
        // Office's fonts are registered for the whole process once (OOXMLKit, for SlideKit). A registration while a
        // text storage is laid out on another thread makes TextKit raise „attempted layout while textStorage is
        // editing“ (seen in the test suite). So Word layout starts only after it: blocks once, then returns at once.
        // At most 3 s in all – a denied or unanswered macOS prompt (Office's font cache) must not hold the layout; after
        // the timeout Word is laid out with substitute fonts. Display paths only join a running registration.
        // Outside the font gate below, never inside: the registration takes that gate exclusively for each font file.
        fontGate.pass(fonts)
        laidOutWithOfficeFonts = fontGate.isComplete
        // Import and layout inside the font gate: no font registration (one still running after the 3 s above, one
        // started after a display path joined none, tests) can run meanwhile. No FontResolver call inside it (it
        // would wait for a registration waiting for this gate).
        // One Word TextKit job at a time in the process (`textKit`), font gate inside it.
        // Office-speed: the layout (`fonts: .start`) yields `textKit` to display paths between chunks of pages; the
        // import itself is one step.
        let turn: Turn = fonts == .start ? .layout : .display
        let (storage, layoutManager, setup) = try Self.withTextKit(turn) { try FontResolver.withStableFonts {
            () throws -> (NSTextStorage, NSLayoutManager, WordPageSetup) in
            // A layout cancelled or timed out while it waited for `textKit` runs no import.
            if Task.isCancelled { throw CancellationError() }
            let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
            var attributes: NSDictionary?
            let string: NSAttributedString
            do {
                string = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attributes)
            } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission].contains(error.code) {
                throw error
            } catch {
                throw LayoutSourceError.unreadable(url, reason: Self.unreadableReason)
            }
            // docx: the package's last `w:sectPr`; without one the importer only reports its own Letter default, so A4.
            let setup = (type == .officeOpenXML
                ? WordPageSetup(package: url)
                : (attributes as? [NSAttributedString.DocumentAttributeKey: Any]).flatMap(WordPageSetup.init(documentAttributes:))) ?? .a4

            let storage = NSTextStorage(attributedString: string)
            let layoutManager = NSLayoutManager()
            layoutManager.backgroundLayoutEnabled = false
            layoutManager.allowsNonContiguousLayout = false
            storage.addLayoutManager(layoutManager)
            return (storage, layoutManager, setup)
        } }
        var containers: [NSTextContainer] = []
        var paginated = false
        while !paginated {
            // One chunk of pages; a layout lets go when a display path waits (its objects are its own, so another
            // document's TextKit work in between is as safe as before: still one at a time).
            try Self.withTextKit(turn) { try FontResolver.withStableFonts {
                repeat {
                    if Task.isCancelled { throw CancellationError() }
                    let container = NSTextContainer(size: setup.contentSize)
                    container.lineFragmentPadding = 0
                    layoutManager.addTextContainer(container)
                    containers.append(container)
                    let glyphs = layoutManager.glyphRange(for: container)
                    if NSMaxRange(glyphs) >= layoutManager.numberOfGlyphs { paginated = true; break }
                    if glyphs.length == 0 || containers.count >= maxPages {
                        // Nothing fits on an empty page (or far too many pages): stop instead of looping; the rest is lost.
                        Self.log.error("TextKit-Umbruch abgebrochen nach \(containers.count) Seiten")
                        if glyphs.length == 0, containers.count > 1 {
                            layoutManager.removeTextContainer(at: containers.count - 1)
                            containers.removeLast()
                        }
                        paginated = true
                        break
                    }
                } while !(turn == .layout && Self.yieldsToDisplay)
            } }
        }
        let overflowLocation = Self.withTextKit(turn) { FontResolver.withStableFonts { () -> Int? in
            let laidOut = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: containers[containers.count - 1]),
                                                       actualGlyphRange: nil)
            let overflowLocation = NSMaxRange(laidOut) < storage.length ? NSMaxRange(laidOut) : nil
            if overflowLocation == nil, containers.count > 1, let last = containers.last {
                let characters = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: last), actualGlyphRange: nil)
                let text = (storage.string as NSString).substring(with: characters)
                if text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control }) {
                    layoutManager.removeTextContainer(at: containers.count - 1)
                    containers.removeLast()
                }
            }
            return overflowLocation
        } }
        self.storage = storage
        self.layoutManager = layoutManager
        self.containers = containers
        self.setup = setup
        self.overflowLocation = overflowLocation
    }

    public var pageCount: Int { containers.count }

    /// Page size in points (the same for every page).
    public func pageSize(_ i: Int) -> CGSize {
        checkIndex(i)
        return setup.size
    }

    private func checkIndex(_ i: Int) {
        precondition(containers.indices.contains(i), "TextKitWordDocument: Seite \(i) gibt es nicht (\(containers.count) Seiten)")
    }

    /// Normalized page text and its word boxes (0…1, origin top left), split like `SlideSnapshotter`/OCR; words that
    /// vanish through normalization are dropped.
    /// `turn`: `.layout` for the index (steps aside for tiles and the preview), `.display` otherwise.
    public func page(_ i: Int) -> LaidOutPage { page(i, turn: .display) }

    func page(_ i: Int, turn: Turn) -> LaidOutPage {
        checkIndex(i)
        return Self.withTextKit(turn) { FontResolver.withStableFonts {
            let container = containers[i]
            let characters = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: container),
                                                          actualGlyphRange: nil)
            let string = storage.string as NSString
            let raw = string.substring(with: characters)
            var full = raw
            if i == containers.count - 1, let overflowLocation {
                full += string.substring(from: overflowLocation)
            }
            let mapped = TextNormalizer.normalizeMapped(full)
            let size = setup.size
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            var words: [OCRWord] = []
            for local in SlideSnapshotter.wordRanges(in: raw) {
                let range = mapped.normalizedRange(forOriginal: local)
                guard range.length > 0 else { continue }
                let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: characters.location + local.location,
                                                                                 length: local.length),
                                                      actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                let box = CGRect(x: (rect.minX + setup.margins.left) / size.width, y: (rect.minY + setup.margins.top) / size.height,
                                 width: rect.width / size.width, height: rect.height / size.height).intersection(unit)
                guard !box.isNull, !box.isEmpty else { continue }
                words.append(OCRWord(range: range, box: box.standardized))
            }
            return LaidOutPage(text: mapped.text, words: words, size: size)
        } }
    }

    /// Draws page `i` into `ctx`, whose user space has its origin bottom left and measures the page in points.
    /// Draws no background.
    public func draw(page i: Int, in ctx: CGContext) {
        checkIndex(i)
        Self.withTextKit(.display) { FontResolver.withStableFonts {
            let glyphs = layoutManager.glyphRange(for: containers[i])
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.translateBy(x: 0, y: setup.size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let origin = NSPoint(x: setup.margins.left, y: setup.margins.top)
            // Dynamic colors from the importer resolve as on paper, not as the app's dark mode.
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
        } }
    }

    /// Page `i` on white, the longer side `maxPixel` pixels.
    public func thumbnail(_ i: Int, maxPixel: Int) -> CGImage? {
        checkIndex(i)
        let size = setup.size
        let scale = CGFloat(max(1, maxPixel)) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        draw(page: i, in: ctx)
        return ctx.makeImage()
    }

    // MARK: Cache

    struct CacheKey: Equatable, Sendable {
        let path: String
        let size: Int
        let modifiedAt: Date
        /// Whether Office's font registration was done when the document was laid out. One laid out before (a
        /// display path that only joined, substitute fonts) is laid out again once it is done.
        var fontsDone = false
    }

    private static let shared = DocumentLRU<CacheKey, TextKitWordDocument>(capacity: cacheCapacity,
                                                                            maxWeight: cacheMaxPages) { $0.pageCount }

    /// The document for `url`, from a thread-safe LRU of at most `cacheCapacity` documents and `cacheMaxPages` pages in all keyed by the standardized path and the
    /// size and modification date of the resolved file (a changed file is imported anew). Errors as `init`.
    /// `fonts`: `.join` (default) for display paths – tiles, preview, output, page counts never start Office's font
    /// registration; `.start` for layout (`TextKitWordSource`).
    public static func cached(url: URL, fonts: FontRegistrationGate.Mode = .join) throws -> TextKitWordDocument {
        try cached(url: url, in: shared, fonts: fonts)
    }

    /// `cached(url:fonts:)` through another gate (the shared LRU; `TextKitWordSource(fontGate:)` in tests).
    static func cached(url: URL, fontGate: FontRegistrationGate, fonts: FontRegistrationGate.Mode) throws -> TextKitWordDocument {
        try cached(url: url, in: shared, fontGate: fontGate, fonts: fonts)
    }

    /// For tests: `cached` with its own LRU and gate.
    static func cached(url: URL, in cache: DocumentLRU<CacheKey, TextKitWordDocument>,
                       fontGate: FontRegistrationGate = .shared,
                       fonts: FontRegistrationGate.Mode = .join) throws -> TextKitWordDocument {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        // Pass the gate before the lookup (as `init` would; at once when done or past its deadline), so the key
        // tells whether the fonts are there: a document laid out with substitute fonts is not reused after them.
        fontGate.pass(fonts)
        let key = CacheKey(path: url.standardizedFileURL.path, size: values.fileSize ?? 0,
                           modifiedAt: values.contentModificationDate ?? .distantPast, fontsDone: fontGate.isComplete)
        return try cache.value(for: key, replacing: { $0.path == key.path }) {
            try TextKitWordDocument(url: url, maxPages: maxPages, fontGate: fontGate, fonts: fonts)
        }
    }
}

/// A thread-safe least-recently-used cache of at most `capacity` values and at most `maxWeight` in summed `weight`
/// (the most recently used value always stays, also when it alone is heavier).
final class DocumentLRU<Key: Equatable & Sendable, Value: Sendable>: Sendable {
    let capacity: Int
    let maxWeight: Int
    private let weight: @Sendable (Value) -> Int

    /// A value being made: its result, set once, then `done` is left.
    private final class Making: Sendable {
        let key: Key
        let done = DispatchGroup()
        let result = Mutex<Result<Value, any Error>?>(nil)
        init(_ key: Key) { self.key = key; done.enter() }
    }

    private struct State {
        var entries: [(key: Key, value: Value, weight: Int)] = []
        var making: [Making] = []
    }
    private let state = Mutex(State())

    init(capacity: Int, maxWeight: Int = .max, weight: @escaping @Sendable (Value) -> Int = { _ in 0 }) {
        precondition(capacity > 0, "DocumentLRU: Kapazität muss positiv sein")
        self.capacity = capacity
        self.maxWeight = maxWeight
        self.weight = weight
    }

    private enum Lookup {
        case hit(Value)
        case wait(Making)
        case make(Making)
    }

    /// The value for `key` (now the most recently used), or `make()`'s result, stored after removing the entries
    /// `replacing` matches (an older version of the same file) and then the least recently used ones while more
    /// than `capacity` entries or more than `maxWeight` remain (never the new one).
    /// `make` runs outside the lock, once per key at a time (office-speed): simultaneous misses wait for the first
    /// one's value or error; an error is not kept.
    func value(for key: Key, replacing: (Key) -> Bool = { _ in false }, make: () throws -> Value) throws -> Value {
        let lookup = state.withLock { state -> Lookup in
            if let index = state.entries.firstIndex(where: { $0.key == key }) {
                let entry = state.entries.remove(at: index)
                state.entries.append(entry)
                return .hit(entry.value)
            }
            if let making = state.making.first(where: { $0.key == key }) { return .wait(making) }
            let making = Making(key)
            state.making.append(making)
            return .make(making)
        }
        let making: Making
        switch lookup {
        case .hit(let value): return value
        case .wait(let other):
            other.done.wait()
            return try other.result.withLock { $0! }.get()
        case .make(let mine): making = mine
        }
        let result = Result { try make() }
        if case .success(let value) = result {
            let valueWeight = weight(value)
            state.withLock { state in
                state.entries.removeAll { $0.key == key || replacing($0.key) }
                state.entries.append((key, value, valueWeight))
                var total = state.entries.reduce(0) { $0 + $1.weight }
                while state.entries.count > 1, state.entries.count > capacity || total > maxWeight {
                    total -= state.entries.removeFirst().weight
                }
            }
        }
        state.withLock { $0.making.removeAll { $0 === making } }
        making.result.withLock { $0 = result }
        making.done.leave()
        return try result.get()
    }

    /// `value(for:replacing:make:)` for a `make` that cannot fail.
    func value(for key: Key, replacing: (Key) -> Bool = { _ in false }, make: () -> Value) -> Value {
        // Never throws: the only error source is `make`.
        try! value(for: key, replacing: replacing, make: { () throws -> Value in make() })
    }

    var keys: [Key] { state.withLock { $0.entries.map(\.key) } }
    var totalWeight: Int { state.withLock { $0.entries.reduce(0) { $0 + $1.weight } } }
}

/// Page size and margins in points.
struct WordPageSetup {
    let size: CGSize
    let margins: NSEdgeInsets

    /// A4 with 2.5 cm margins: the fallback when neither the package nor the importer gives a usable page.
    static let a4 = WordPageSetup(size: CGSize(width: 595.28, height: 841.89),
                                  margins: NSEdgeInsets(top: 70.87, left: 70.87, bottom: 70.87, right: 70.87))

    init(size: CGSize, margins: NSEdgeInsets) {
        self.size = size
        self.margins = margins
    }

    var contentSize: CGSize {
        CGSize(width: size.width - margins.left - margins.right, height: size.height - margins.top - margins.bottom)
    }

    /// At least 1 inch of content each way and no page beyond 200 inches (Word allows 22).
    private var isUsable: Bool {
        size.width.isFinite && size.height.isFinite && size.width <= 14_400 && size.height <= 14_400
            && contentSize.width >= 72 && contentSize.height >= 72
            && [margins.top, margins.left, margins.bottom, margins.right].allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// From `w:pgSz`/`w:pgMar` (twips, 1/20 pt) of the last `w:sectPr` in the main document part (the body's own
    /// section, the last section of the document). Negative top/bottom margins count by their amount; the gutter is
    /// added to the left margin. Without `w:pgMar`, 2.5 cm. Nil without a usable `w:pgSz`.
    init?(documentXML data: Data) {
        var pageSize: [String: String]?
        var pageMargins: [String: String]?
        XMLScan.elements(in: data) { name, attributes in
            switch name {
            case "sectPr": pageSize = nil; pageMargins = nil
            case "pgSz": pageSize = Self.local(attributes)
            case "pgMar": pageMargins = Self.local(attributes)
            default: break
            }
            return true
        }
        func points(_ map: [String: String]?, _ key: String) -> CGFloat? {
            map?[key].flatMap(Double.init).map { abs(CGFloat($0)) / 20 }
        }
        guard let width = points(pageSize, "w"), let height = points(pageSize, "h") else { return nil }
        let margins = pageMargins == nil ? Self.a4.margins
            : NSEdgeInsets(top: points(pageMargins, "top") ?? 0, left: (points(pageMargins, "left") ?? 0) + (points(pageMargins, "gutter") ?? 0),
                           bottom: points(pageMargins, "bottom") ?? 0, right: points(pageMargins, "right") ?? 0)
        self.init(size: CGSize(width: width, height: height), margins: margins)
        guard isUsable else { return nil }
    }

    /// From the package of a `.docx`/`.docm`/`.dotx`: the main document part named in `_rels/.rels`
    /// (default `word/document.xml`). Nil when the package or part can't be read or has no usable page size.
    init?(package url: URL) {
        guard let archive = try? ZipArchive(officePackage: url) else { return nil }
        var part = "word/document.xml"
        if let rels = archive.data(at: "_rels/.rels") {
            XMLScan.elements(in: rels) { name, attributes in
                guard name == "Relationship", attributes["Type"]?.hasSuffix("/officeDocument") ?? false,
                      let target = attributes["Target"] else { return true }
                part = PresentationSlides.resolve(target, base: "")
                return false
            }
        }
        guard let xml = archive.data(at: part) else { return nil }
        self.init(documentXML: xml)
    }

    /// From the importer's `.paperSize` and margins (missing margins: 2.5 cm). Nil without a usable paper size.
    init?(documentAttributes attributes: [NSAttributedString.DocumentAttributeKey: Any]) {
        guard let paper = (attributes[.paperSize] as? NSValue)?.sizeValue else { return nil }
        func margin(_ key: NSAttributedString.DocumentAttributeKey, _ fallback: CGFloat) -> CGFloat {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
        }
        let a4 = Self.a4.margins
        self.init(size: paper, margins: NSEdgeInsets(top: margin(.topMargin, a4.top), left: margin(.leftMargin, a4.left),
                                                     bottom: margin(.bottomMargin, a4.bottom), right: margin(.rightMargin, a4.right)))
        guard isUsable else { return nil }
    }

    /// Attribute names without namespace prefix (`w:w` → `w`).
    private static func local(_ attributes: [String: String]) -> [String: String] {
        Dictionary(attributes.map { (String($0.key.split(separator: ":").last ?? Substring($0.key)), $0.value) },
                   uniquingKeysWith: { first, _ in first })
    }
}
