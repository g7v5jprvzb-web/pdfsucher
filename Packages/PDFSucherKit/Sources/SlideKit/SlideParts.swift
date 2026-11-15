// SlideParts.swift — Task 9 (SlideKit)
// Part loading and the master → layout → slide chain: a thread-safe per-deck store that parses slide, layout,
// master and theme parts lazily and caches them (and the resolved slide models) by part path.
//
// Design (docs/decisions.md): `SlideDeck` stays an immutable struct; it holds one `DeckStore` (a final class)
// that all copies share. The store's caches sit behind one `Mutex`; parsing happens outside the lock and the
// first insert wins, so two threads may parse the same part once each but always see the same value. Every
// cached value is immutable and Sendable. Missing or broken parts are cached as nil and skipped, never thrown.
import CoreGraphics
import Foundation
import OOXMLKit
import Synchronization

// MARK: - Layers

/// One parsed slide, layout or master part.
struct SlideLayer: Sendable {
    enum Kind: Sendable { case master, layout, slide }

    let kind: Kind
    let part: PartContext
    /// `p:sld` / `p:sldLayout` / `p:sldMaster`.
    let root: OOXMLNode
    let spTree: OOXMLNode?
    /// `p:cSld/p:bg`.
    let background: OOXMLNode?
    /// Top-level placeholders of the shape tree, in document order.
    let placeholders: [Placeholder]

    var path: String { part.part }

    /// `showMasterSp` on the root: anything but "0"/"false" (also missing) shows the parent's shapes.
    var showMasterSp: Bool {
        let v = root.attr("showMasterSp")
        return v != "0" && v != "false"
    }

    /// `p:clrMap` of a master, `p:clrMapOvr` of a layout or slide.
    var colorMapElement: OOXMLNode? { root.child(kind == .master ? "clrMap" : "clrMapOvr") }

    /// VML `mc:Choice`s lose against their Fallback: a legacy OLE object's Choice has no image, the Fallback has
    /// its `p:pic` (docs/decisions.md).
    init?(package: OPCPackage, path: String, kind: Kind) {
        guard let data = try? package.data(path),
              let root = try? OOXMLNode.parse(data, preferringFallbackOver: [NS.v]) else { return nil }
        self.kind = kind
        self.root = root
        part = PartContext(package: package, part: path)
        let cSld = root.child("cSld")
        spTree = cSld?.child("spTree")
        background = cSld?.child("bg")
        placeholders = (spTree?.children ?? []).compactMap(Placeholder.init(element:))
    }

    /// Target part of the first internal relationship (lowest Id) whose type ends in "/<typeSuffix>".
    func related(_ typeSuffix: String) -> String? {
        DeckStore.related(typeSuffix, in: part)
    }
}

// MARK: - Placeholders

/// `p:nvPr/p:ph` of a shape, picture or graphic frame.
///
/// Type normalisation: missing → "obj" (ECMA-376 §19.7.10, ST_PlaceholderType default), ctrTitle → title,
/// subTitle → body. Matching (`match`): first an equal explicit idx whose type is compatible, then an equal
/// type, then obj ↔ body. Compatible = equal, or one side is "obj" and the other a content type (obj is the
/// generic content placeholder that can hold text, a picture, a table, a chart …). The type check on the idx
/// step keeps a layout's content placeholder idx 2 from matching the master's date placeholder idx 2.
struct Placeholder: Sendable {
    let type: String
    /// Explicit `idx` only (nil when the attribute is missing).
    let idx: Int?
    /// The `p:sp` / `p:pic` / `p:graphicFrame` / `p:cxnSp` element.
    let node: OOXMLNode

    static let contentTypes: Set<String> = ["obj", "body", "chart", "tbl", "dgm", "pic", "media", "clipArt"]

    init(type: String, idx: Int?, node: OOXMLNode) {
        self.type = type; self.idx = idx; self.node = node
    }

    init?(element: OOXMLNode) {
        guard let ph = Self.phElement(element) else { return nil }
        self.init(type: Self.normalize(ph.attr("type")), idx: ph.attr("idx").flatMap { Int($0) }, node: element)
    }

    static func phElement(_ element: OOXMLNode) -> OOXMLNode? {
        element.children.first { $0.name.hasPrefix("nv") }?.child("nvPr")?.child("ph")
    }

    static func normalize(_ raw: String?) -> String {
        switch raw {
        case nil, "": return "obj"
        case "ctrTitle": return "title"
        case "subTitle": return "body"
        case let v?: return v
        }
    }

    func compatible(with other: Placeholder) -> Bool {
        if type == other.type { return true }
        let content = Self.contentTypes
        return (type == "obj" && content.contains(other.type)) || (other.type == "obj" && content.contains(type))
    }

    /// Types a slide has at most one of; their slide placeholders match by type even when the idx differs.
    static let singletonTypes: Set<String> = ["title", "dt", "ftr", "sldNum", "hdr"]

    /// The candidate this placeholder inherits from, nil if none matches.
    ///
    /// `slideToLayout`: a slide placeholder with an explicit idx that the layout lacks matches by type (or
    /// obj ↔ body) only if its type is a singleton or the candidate has no idx itself, so a slide body idx 14
    /// never takes the layout's body idx 13. Layout → master stays lenient.
    func match(in candidates: [Placeholder], slideToLayout: Bool = false) -> Placeholder? {
        if let idx, let m = candidates.first(where: { $0.idx == idx && compatible(with: $0) }) { return m }
        let strict = slideToLayout && idx != nil && !Self.singletonTypes.contains(type)
        let allowed = { (c: Placeholder) in !strict || c.idx == nil }
        if let m = candidates.first(where: { $0.type == type && allowed($0) }) { return m }
        if type == "obj" || type == "body" {
            return candidates.first { ($0.type == "obj" || $0.type == "body") && allowed($0) }
        }
        return nil
    }
}

// MARK: - Store

/// Per-deck shared state: package, image decoder, font resolver and the part caches. Thread-safe.
final class DeckStore: Sendable {
    let package: OPCPackage
    let presentationPart: String
    let images: ImageDecoder
    /// Created without a theme: masters may have different themes, so Task 10 replaces the theme font
    /// shorthands (+mj-lt, +mn-lt, …) with the slide's `Theme` before asking the resolver.
    let fonts: FontResolver
    let renderer: DrawingRenderer

    private struct Cache {
        var layers: [String: SlideLayer?] = [:]
        var themes: [String: Theme] = [:]
        var slides: [String: SlideModel] = [:]
        var texts: [String: SlideTextLayout] = [:]
        var slideTexts: [String: SlideTextResult] = [:]
        var fallbackMaster: String??
        var defaultTextStyle: OOXMLNode??
        var tableStyles: TableStyleList?
    }

    private let cache = Mutex<Cache>(Cache())

    init(package: OPCPackage, presentationPart: String, fontSubstitution: FontSubstitution) {
        self.package = package
        self.presentationPart = presentationPart
        images = ImageDecoder(package: package)
        fonts = FontResolver(theme: nil, substitution: fontSubstitution)
        renderer = DrawingRenderer(images: images, fonts: fonts)
    }

    /// Looks `key` up in one cache dictionary, else makes the value outside the lock; the first insert wins.
    private func memo<V: Sendable>(_ key: String, _ field: WritableKeyPath<Cache, [String: V]>,
                                   _ make: () -> V) -> V {
        if let hit = cache.withLock({ $0[keyPath: field][key] }) { return hit }
        let made = make()
        return cache.withLock { c in
            if let hit = c[keyPath: field][key] { return hit }
            c[keyPath: field][key] = made
            return made
        }
    }

    func layer(_ path: String, kind: SlideLayer.Kind) -> SlideLayer? {
        memo(path, \.layers) { SlideLayer(package: package, path: path, kind: kind) }
    }

    /// Missing or unreadable theme part → `Theme.fallback`.
    func theme(_ path: String) -> Theme {
        memo(path, \.themes) { (try? package.xml(path)).map(Theme.init(xml:)) ?? .fallback }
    }

    /// The presentation's first slide master (lowest relationship Id), used when a slide has no layout.
    func fallbackMaster() -> String? {
        if let hit = cache.withLock({ $0.fallbackMaster }) { return hit }
        let found = Self.related("slideMaster", in: PartContext(package: package, part: presentationPart))
        cache.withLock { if $0.fallbackMaster == nil { $0.fallbackMaster = .some(found) } }
        return found
    }

    /// The resolved model of a slide part (cached).
    func slideModel(_ path: String) -> SlideModel {
        memo(path, \.slides) { SlideModel.build(slidePath: path, store: self) }
    }

    /// The laid-out text of a slide (cached by part path; the slide number comes with the ref).
    func textLayout(_ ref: SlideRef) -> SlideTextLayout {
        memo(ref.partPath, \.texts) {
            TextBodyLayout.build(model: slideModel(ref.partPath), slideNumber: ref.powerPointNumber, store: self)
        }
    }

    /// Normalized text and word boxes of a slide (cached by part path; Task 11).
    func slideText(_ ref: SlideRef, slideSize: CGSize) -> SlideTextResult {
        memo(ref.partPath, \.slideTexts) {
            SlideTextBuilder.build(model: slideModel(ref.partPath), layout: textLayout(ref), slideSize: slideSize)
        }
    }

    /// `p:presentation/p:defaultTextStyle` (read once), nil if missing.
    func defaultTextStyle() -> OOXMLNode? {
        if let hit = cache.withLock({ $0.defaultTextStyle }) { return hit }
        let found = (try? package.xml(presentationPart))?.child("defaultTextStyle")
        cache.withLock { if $0.defaultTextStyle == nil { $0.defaultTextStyle = .some(found) } }
        return found
    }

    /// The deck's table styles (`ppt/tableStyles.xml` through the presentation's …/tableStyles relationship,
    /// read once); missing or unreadable → none.
    func tableStyles() -> TableStyleList {
        if let hit = cache.withLock({ $0.tableStyles }) { return hit }
        let path = Self.related("tableStyles", in: PartContext(package: package, part: presentationPart))
        let found = TableStyleList(xml: path.flatMap { try? package.xml($0) })
        return cache.withLock { c in
            if let hit = c.tableStyles { return hit }
            c.tableStyles = found
            return found
        }
    }

    static func related(_ typeSuffix: String, in part: PartContext) -> String? {
        let rels = part.relationships.values
            .filter { !$0.external && $0.type.hasSuffix("/" + typeSuffix) }
            .sorted { $0.id < $1.id }
        for rel in rels {
            if let target = part.targetPart(rel.id) { return target }
        }
        return nil
    }
}
