// ImageDecoder.swift — Task 6 (OOXMLKit)
// Decodes image parts of an OPC package (PNG, JPEG, GIF, TIFF, BMP via ImageIO; EMF/WMF/EMZ/WMZ via the
// metafile players) and caches them by part path.
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// A crop / inset rectangle in fractions of the width/height: `a:srcRect` and `a:fillRect` (l, t, r, b in
/// 100000ths in the file). Positive values move the edge inwards, negative ones outwards (padding).
public struct SrcRect: Sendable, Hashable {
    public var l: Double
    public var t: Double
    public var r: Double
    public var b: Double
    public init(l: Double = 0, t: Double = 0, r: Double = 0, b: Double = 0) {
        self.l = l; self.t = t; self.r = r; self.b = b
    }

    /// Reads l/t/r/b attributes; nil if the element is missing or all four are 0.
    init?(xml: OOXMLNode?) {
        guard let xml else { return nil }
        func v(_ k: String) -> Double {
            guard let p = Units.parsePercentage(xml.attr(k)), p.isFinite else { return 0 }
            return min(max(p, -1000), 1000)
        }
        self.init(l: v("l"), t: v("t"), r: v("r"), b: v("b"))
        if l == 0 && t == 0 && r == 0 && b == 0 { return nil }
    }

    /// The rectangle that results from applying these insets to `rect` (may be empty or inverted).
    func inset(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + rect.width * l, y: rect.minY + rect.height * t,
               width: rect.width * (1 - l - r), height: rect.height * (1 - t - b))
    }
}

/// A reference to an image part plus the per-use blip settings.
public struct ImageRef: Sendable, Hashable {
    /// Resolved package part path (no leading slash), e.g. `ppt/media/image1.png`.
    public var part: String
    /// `a:srcRect` crop (fractions, may be negative = padding); nil = uncropped.
    public var srcRect: SrcRect?
    /// `a:alphaModFix amt` as a fraction 0…1; nil = opaque.
    public var alphaModFix: Double?
    /// Recolour effects of the blip (duotone, grayscl, clrChange, biLevel, lum), in document order.
    public var effects: [BlipEffect]

    public init(part: String, srcRect: SrcRect? = nil, alphaModFix: Double? = nil, effects: [BlipEffect] = []) {
        self.part = part; self.srcRect = srcRect; self.alphaModFix = alphaModFix; self.effects = effects
    }

    /// Builds a reference from a `p:blipFill` / `pic:blipFill` / `a:blipFill`: `a:blip r:embed` resolved through
    /// the part's relationships, its `a:alphaModFix`, and the sibling `a:srcRect`. Only `r:embed` is used
    /// (`r:link`, external targets and unknown ids → nil). An `asvg:svgBlip` extension is ignored: the
    /// blip's own `r:embed` is the PNG fallback.
    /// `colors`: resolves the colours of recolour effects; nil = effects ignored.
    public init?(blipFill: OOXMLNode, in context: PartContext, colors: ColorContext? = nil) {
        guard let blip = blipFill.child("blip"),
              let rId = blip.attr("embed", ns: NS.r), let part = context.targetPart(rId) else { return nil }
        var alpha: Double?
        if let amt = Units.parsePercentage(blip.child("alphaModFix")?.attr("amt") ?? "100000"), amt < 1 {
            alpha = min(max(amt, 0), 1)
        }
        self.init(part: part, srcRect: SrcRect(xml: blipFill.child("srcRect")), alphaModFix: alpha,
                  effects: colors.map { BlipEffect.parse(blip: blip, colors: $0) } ?? [])
    }
}

/// The package part that drawing XML comes from; needed to resolve `r:embed` ids.
public struct PartContext: Sendable {
    public let package: OPCPackage
    /// Part path of the XML that holds the drawing (slide, layout, document.xml, header…).
    public let part: String
    public let relationships: [String: Relationship]

    public init(package: OPCPackage, part: String) {
        self.package = package
        self.part = part
        self.relationships = package.relationships(of: part)
    }

    /// Resolved part path of an internal relationship, nil if unknown or external.
    public func targetPart(_ rId: String) -> String? {
        guard let rel = relationships[rId], !rel.external, !rel.target.isEmpty else { return nil }
        let path = package.resolve(rel.target, from: part)
        return path.isEmpty ? nil : path
    }
}

public enum DecodedImage: Sendable {
    case bitmap(CGImage)
    /// EMF/WMF (also gzip-compressed EMZ/WMZ), drawn as vectors.
    case vector(Metafile)
}

/// Decodes and caches image parts. Thread-safe; decoding happens outside the lock (two threads may decode the
/// same part at once; the first result stored wins). Failures are cached too.
///
/// Size-aware decoding: `image(_:maxPixel:)` decodes a bitmap only as large as needed — the long side rounded up to
/// a power of two (64…8192, "bucket"), downsampled by ImageIO while decoding — so a 4000 px photo on a 256 px
/// thumbnail costs a 256 px decode and draw. A request at or above the native size gets the full image (the same
/// object as `image(_:)`). The cache holds every decoded size under its own key and evicts the least recently used
/// entries when the decoded bytes would exceed `cacheLimit` (an entry larger than the limit is returned, not kept).
public final class ImageDecoder: Sendable {
    public let package: OPCPackage
    private let cache = Mutex<Cache>(Cache())
    private let cacheLimit: Int

    private struct Key: Hashable {
        let part: String
        /// 0 = full resolution (up to `maxPixelSize`).
        let bucket: Int
        /// Recolour effects applied to the decoded bitmap (bucket = that bitmap's long side).
        var effects: [BlipEffect] = []
    }

    private struct Entry {
        let image: DecodedImage?
        let cost: Int
        var lastUse: UInt64
    }

    private struct Cache {
        /// Native size per part (0 × 0 = not a bitmap); a few bytes per image part, never evicted.
        struct Native {
            let width: Int
            let height: Int
        }

        var entries: [Key: Entry] = [:]
        var native: [String: Native] = [:]
        var bytes = 0
        var clock: UInt64 = 0

        mutating func hit(_ key: Key) -> DecodedImage?? {
            guard var e = entries[key] else { return nil }
            clock &+= 1
            e.lastUse = clock
            entries[key] = e
            return .some(e.image)
        }

        /// Stores `image` (unless another thread was first) and returns what is cached under `key`.
        mutating func insert(_ image: DecodedImage?, cost: Int, key: Key, limit: Int) -> DecodedImage? {
            if let hit = hit(key) { return hit }
            guard cost <= limit else { return image }
            while bytes + cost > limit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                bytes -= oldest.value.cost
                entries[oldest.key] = nil
            }
            clock &+= 1
            entries[key] = Entry(image: image, cost: cost, lastUse: clock)
            bytes += cost
            return image
        }
    }

    /// Longest side of a decoded bitmap; larger images are downsampled by ImageIO (bounds memory, defuses
    /// decompression bombs). 8192 px is well above what a slide at 4× zoom needs.
    static let maxPixelSize = 8192
    /// Smallest size bucket of size-aware decoding.
    static let minBucket = 64
    /// Total decoded bytes kept by default; least recently used entries are evicted beyond it.
    public static let maxCacheBytes = 512 * 1024 * 1024

    /// Extensions never decoded: HD Photo / JPEG XR (Office stores them next to a PNG fallback), SVG (a PNG
    /// fallback is always present).
    static let skippedExtensions: Set<String> = ["wdp", "jxr", "hdp", "svg", "svgz"]

    public init(package: OPCPackage) {
        self.package = package
        self.cacheLimit = Self.maxCacheBytes
    }

    /// `cacheLimit`: decoded bytes kept (tests use small limits).
    init(package: OPCPackage, cacheLimit: Int) {
        self.package = package
        self.cacheLimit = max(cacheLimit, 0)
    }

    /// The decoded image for `ref.part` at full resolution (crop and alpha are applied by the renderer). nil if the
    /// part is missing, unreadable, of a skipped kind or not decodable.
    public func image(_ ref: ImageRef) -> DecodedImage? {
        recolored(image(part: ref.part), ref)
    }

    /// `decoded` with `ref.effects` applied (bitmaps only; cached per part, decoded size and effects).
    private func recolored(_ decoded: DecodedImage?, _ ref: ImageRef) -> DecodedImage? {
        guard !ref.effects.isEmpty, case .bitmap(let img)? = decoded else { return decoded }
        let key = Key(part: Self.normalized(ref.part), bucket: max(img.width, img.height), effects: ref.effects)
        if let hit = cache.withLock({ $0.hit(key) }) { return hit }
        guard let out = BlipEffect.apply(ref.effects, to: img) else { return decoded }
        return cache.withLock { $0.insert(.bitmap(out), cost: out.bytesPerRow * out.height, key: key, limit: cacheLimit) }
    }

    /// Like `image(_:)`, but a bitmap is decoded only as large as `maxPixel` (long side, in pixels) needs: the
    /// next power of two ≥ maxPixel (at least 64), or the full image if that is not smaller. Metafiles and
    /// failures are the same as without a size.
    public func image(_ ref: ImageRef, maxPixel: Int) -> DecodedImage? {
        recolored(image(part: ref.part, maxPixel: maxPixel), ref)
    }

    /// Like `image(_:maxPixel:)`, but for a bitmap drawn at `pixelSize` (width × height in device pixels, the
    /// whole — crop-extended — image): the long side is chosen so that both axes get enough pixels, i.e.
    /// max(pixelSize.w / w, pixelSize.h / h) · max(w, h) for a native w × h, then bucketed. An image stretched to
    /// another aspect ratio is thus not decoded for its long side only. Non-positive or non-finite sizes give the
    /// full image; metafiles and failures are the same as without a size.
    public func image(_ ref: ImageRef, pixelSize: CGSize) -> DecodedImage? {
        recolored(image(part: ref.part, pixelSize: pixelSize), ref)
    }

    public func image(part: String, pixelSize: CGSize) -> DecodedImage? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0 || pixelSize.height > 0,
              let native = nativeSize(Self.normalized(part))
        else { return image(part: part) }
        let w = CGFloat(native.width), h = CGFloat(native.height)
        let needed = (max(max(pixelSize.width, 0) / w, max(pixelSize.height, 0) / h) * max(w, h)).rounded(.up)
        guard needed.isFinite, needed > 0, needed < CGFloat(Self.maxPixelSize) else { return image(part: part) }
        return image(part: part, maxPixel: Int(needed))
    }

    public func image(part: String) -> DecodedImage? {
        let key = Key(part: Self.normalized(part), bucket: 0)
        if let hit = cache.withLock({ $0.hit(key) }) { return hit }
        let decoded = decode(key.part)
        return cache.withLock { $0.insert(decoded, cost: decoded.map(Self.cost) ?? 0, key: key, limit: cacheLimit) }
    }

    public func image(part: String, maxPixel: Int) -> DecodedImage? {
        let bucket = Self.bucket(maxPixel)
        guard bucket < Self.maxPixelSize else { return image(part: part) }
        let key = Key(part: Self.normalized(part), bucket: bucket)
        if let hit = cache.withLock({ $0.hit(key) }) { return hit }
        // Full image already decoded and not larger than the bucket: use it.
        let fullKey = Key(part: key.part, bucket: 0)
        if let full = cache.withLock({ $0.hit(fullKey) }) {
            guard case .bitmap(let img)? = full, max(img.width, img.height) > bucket else { return full }
        }
        guard let small = decodeDownsampled(key.part, bucket: bucket) else { return image(part: part) }
        return cache.withLock { $0.insert(.bitmap(small), cost: small.bytesPerRow * small.height, key: key, limit: cacheLimit) }
    }

    /// Decoded bytes currently cached.
    var cachedBytes: Int { cache.withLock { $0.bytes } }

    /// Long sides of the bitmaps cached for `part` (all sizes), ascending; for tests.
    func cachedLongSides(part: String) -> [Int] {
        let p = Self.normalized(part)
        return cache.withLock { c in
            c.entries.compactMap { k, e -> Int? in
                guard k.part == p, case .bitmap(let img)? = e.image else { return nil }
                return max(img.width, img.height)
            }.sorted()
        }
    }

    static func normalized(_ part: String) -> String {
        part.hasPrefix("/") ? String(part.dropFirst()) : part
    }

    /// Next power of two ≥ n, clamped to minBucket…maxPixelSize.
    static func bucket(_ n: Int) -> Int {
        var b = minBucket
        while b < n && b < maxPixelSize { b *= 2 }
        return b
    }

    /// The image source of a bitmap part with its native pixel size; nil for skipped kinds, metafiles, missing or
    /// undecodable parts and images without a positive size.
    private func bitmapSource(_ part: String) -> (src: CGImageSource, width: Int, height: Int)? {
        guard !part.isEmpty else { return nil }
        let ext = (part as NSString).pathExtension.lowercased()
        if Self.skippedExtensions.contains(ext) { return nil }
        guard let data = try? package.data(part), !data.isEmpty, !Self.isHDPhoto(data), !Metafile.isGzip(data),
              !EMFDocument.looksLikeEMF(data), !WMFDocument.looksLikeWMF(data),
              let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        return (src, w, h)
    }

    /// Native pixel size of a bitmap part (header only, cached per part, failures too); nil if not a bitmap.
    private func nativeSize(_ part: String) -> (width: Int, height: Int)? {
        let cached = cache.withLock { $0.native[part] }
        let size: Cache.Native
        if let cached {
            size = cached
        } else {
            let s = bitmapSource(part)
            size = Cache.Native(width: s?.width ?? 0, height: s?.height ?? 0)
            cache.withLock { $0.native[part] = size }
        }
        return size.width > 0 && size.height > 0 ? (size.width, size.height) : nil
    }

    /// A bitmap part downsampled to `bucket` on its long side; nil if it is not a bitmap or not larger than
    /// the bucket (then the full image is used).
    private func decodeDownsampled(_ part: String, bucket: Int) -> CGImage? {
        guard let (src, w, h) = bitmapSource(part), max(w, h) > bucket else { return nil }
        return Self.thumbnail(src, maxPixel: bucket)
    }

    static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func cost(_ d: DecodedImage) -> Int {
        switch d {
        case .bitmap(let img): return img.bytesPerRow * img.height
        case .vector(let m): return m.cost
        }
    }

    private func decode(_ part: String) -> DecodedImage? {
        guard !part.isEmpty else { return nil }
        let ext = (part as NSString).pathExtension.lowercased()
        if Self.skippedExtensions.contains(ext) { return nil }
        guard let data = try? package.data(part), !data.isEmpty, !Self.isHDPhoto(data) else { return nil }
        // Metafiles are recognised by content (signature / gzip magic), whatever the extension.
        if let m = Metafile.decode(data) { return .vector(m) }
        return Self.decodeBitmap(data).map(DecodedImage.bitmap)
    }

    /// JPEG XR / HD Photo signature "II" 0xBC 0x01 (macOS ImageIO may decode it, Office never needs it).
    static func isHDPhoto(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x49, 0x49, 0xBC, 0x01])
    }

    static func decodeBitmap(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        var w = 0, h = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
        if max(w, h) > maxPixelSize { return thumbnail(src, maxPixel: maxPixelSize) }
        let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }
}
