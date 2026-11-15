// SlideModel.swift — Task 9 (SlideKit)
// The immutable, resolved model of one slide: background, the drawable elements of master, layout and slide in
// draw order, and the text sources of its shapes (laid out by TextBodyLayout). Built once per slide by `DeckStore`.
import CoreGraphics
import Foundation
import OOXMLKit

// MARK: - Element model

/// A drawable element of a shape tree. Mirrors OOXMLKit's `DrawingElement` plus graphic frames, so groups
/// can hold tables, charts and diagrams too.
indirect enum SlideElement: Sendable {
    /// `p:sp` and `p:cxnSp`. `tag` (if set) indexes `SlideModel.texts`.
    case shape(ShapeModel)
    case picture(PictureModel)
    /// `p:grpSp`: the group's transform and fill (its `children` are empty) and the child elements.
    case group(GroupModel, [SlideElement])
    /// `p:graphicFrame` with a table or a chart (SmartArt becomes a `.group`, an OLE object a `.picture`;
    /// GraphicFrames.swift). Other graphic frames draw nothing.
    case graphicFrame(GraphicFrameModel)
}

struct GraphicFrameModel: Sendable {
    /// `p:xfrm`, inherited from the placeholder chain when the frame has none.
    var transform: Transform2D
    /// `a:graphic/a:graphicData`; its `uri` names the kind (table, chart, diagram, OLE).
    var graphicData: OOXMLNode?
    /// The part the frame belongs to (resolves r:id of charts, diagrams, OLE images).
    var part: PartContext
    /// Index into `SlideModel.texts` if the frame is a placeholder.
    var tag: Int?
    /// The table, when `graphicData` holds an `a:tbl` (TableRenderer.swift).
    var table: TableModel?
    /// The chart, when `graphicData` refers to a supported `c:chartSpace` (ChartModel.swift).
    var chart: ChartModel?
}

/// Text source of a shape, laid out by TextBodyLayout.
struct ShapeText: Sendable {
    /// The layer the shape belongs to (master/layout shapes that are drawn are never placeholders).
    let layer: SlideLayer.Kind
    /// The shape's own placeholder (type normalised, explicit idx), nil for ordinary shapes.
    let placeholder: Placeholder?
    /// The shape's own `p:txBody` (text is never inherited: layout/master placeholder text is prompt text).
    let txBody: OOXMLNode?
    /// `p:txBody` of the placeholders it inherits from, nearest first (layout, then master). Their `a:bodyPr`
    /// and `a:lstStyle` complete the shape's own, level by level.
    let inheritedTxBodies: [OOXMLNode]
    /// The part of the shape (hyperlinks, picture bullets).
    let part: PartContext
    /// The shape's `p:style` (own, else inherited from its placeholders): `a:fontRef` gives the default text
    /// color and typeface.
    let style: OOXMLNode?
}

struct SlideModel: Sendable {
    /// Resolved background (`.none` = plain white).
    let background: Fill
    /// Master shapes (if shown), layout shapes (if shown), then slide shapes. Master and layout
    /// placeholders are not part of this list.
    let elements: [SlideElement]
    /// Text sources; `ShapeModel.tag` / `GraphicFrameModel.tag` index this array.
    let texts: [ShapeText]
    /// Theme and effective color map of the slide (applied to every layer).
    let colors: ColorContext
    /// The parts of the chain; nil when missing. Task 10 reads `master.root`'s `p:txStyles`.
    let master: SlideLayer?
    let layout: SlideLayer?
    let slide: SlideLayer?

    static let empty = SlideModel(background: .none, elements: [], texts: [], colors: ColorContext(theme: .fallback),
                                  master: nil, layout: nil, slide: nil)

    /// Relationships: slide → slideLayout → slideMaster → theme. Without a layout the slide's own master
    /// relationship or the presentation's first master is used; without a master there are no inherited
    /// shapes, the theme is `Theme.fallback` and the color map the default one.
    static func build(slidePath: String, store: DeckStore) -> SlideModel {
        let slide = store.layer(slidePath, kind: .slide)
        // Relationships come from the .rels part, so they are followed even when the slide XML is broken.
        let slidePart = slide?.part ?? PartContext(package: store.package, part: slidePath)
        let layout = DeckStore.related("slideLayout", in: slidePart).flatMap { store.layer($0, kind: .layout) }
        let masterPath = layout?.related("slideMaster") ?? DeckStore.related("slideMaster", in: slidePart)
            ?? store.fallbackMaster()
        let master = masterPath.flatMap { store.layer($0, kind: .master) }
        let themePath = master?.related("theme")
        let theme = themePath.map(store.theme) ?? .fallback

        let masterMap = ColorMap(xml: master?.colorMapElement)
        let map = slide?.colorMapElement.flatMap(ColorMap.init(override:))
            ?? layout?.colorMapElement.flatMap(ColorMap.init(override:))
            ?? masterMap
        let colors = ColorContext(theme: theme, map: map)

        let background = [slide, layout, master].lazy.compactMap { $0 }
            .first { $0.background != nil }
            .map { layer in
                Self.backgroundFill(layer.background, part: layer.part, colors: colors,
                                    themePart: themePath.map { PartContext(package: store.package, part: $0) })
            } ?? .none

        var builder = ElementBuilder(colors: colors, background: background, tableStyles: store.tableStyles())
        var elements: [SlideElement] = []
        let showSlide = slide?.showMasterSp ?? true
        if let master, showSlide, layout?.showMasterSp ?? true {
            elements += builder.elements(of: master, inherit: nil)
        }
        if let layout, showSlide {
            elements += builder.elements(of: layout, inherit: nil)
        }
        if let slide {
            elements += builder.elements(of: slide) { ph in
                var chain: [(Placeholder, PartContext)] = []
                let fromLayout = layout.flatMap { ph.match(in: $0.placeholders, slideToLayout: true) }
                if let fromLayout, let layout { chain.append((fromLayout, layout.part)) }
                if let master, let m = (fromLayout ?? ph).match(in: master.placeholders) {
                    chain.append((m, master.part))
                }
                return chain
            }
        }
        return SlideModel(background: background, elements: elements, texts: builder.texts, colors: colors,
                          master: master, layout: layout, slide: slide)
    }

    /// `p:bg`: `p:bgPr` holds a fill; `p:bgRef idx` picks theme bgFillStyleLst[idx − 1001] (or fillStyleLst
    /// [idx − 1] for 1…999) with phClr = the reference's color. Theme blip fills resolve against the theme part.
    static func backgroundFill(_ bg: OOXMLNode?, part: PartContext, colors: ColorContext,
                               themePart: PartContext?) -> Fill {
        guard let bg else { return .none }
        if let bgPr = bg.child("bgPr") {
            return FillResolver.explicitFill(bgPr, colors: colors, part: part) ?? .none
        }
        guard let ref = bg.child("bgRef"), let idx = ref.attr("idx").flatMap({ Int($0) }), idx > 0 else { return .none }
        let list = idx >= 1001 ? colors.theme.bgFillStyles : colors.theme.fillStyles
        let i = idx >= 1001 ? idx - 1001 : idx - 1
        guard list.indices.contains(i) else { return .none }
        var ctx = colors
        if let c = ColorResolver.resolve(ref, in: colors) { ctx.placeholderColor = c }
        return FillResolver.fill(element: list[i], colors: ctx, part: themePart)
    }
}

// MARK: - Builder

/// Turns shape trees into `SlideElement`s, collecting text sources on the way.
struct ElementBuilder {
    /// Placeholders a slide placeholder inherits from (nearest first), with their parts.
    typealias Inheritance = (Placeholder) -> [(Placeholder, PartContext)]

    let colors: ColorContext
    /// For `useBgFill="1"` shapes.
    let background: Fill
    /// The deck's table styles.
    let tableStyles: TableStyleList
    private(set) var texts: [ShapeText] = []
    private var tableCount = 0
    /// Ids of `ChartModel`s, unique per slide model.
    var chartCount = 0

    init(colors: ColorContext, background: Fill, tableStyles: TableStyleList = .empty) {
        self.colors = colors
        self.background = background
        self.tableStyles = tableStyles
    }

    /// Top-level elements of a layer. `inherit` nil = master/layout: their placeholders are skipped.
    mutating func elements(of layer: SlideLayer, inherit: Inheritance?) -> [SlideElement] {
        var out: [SlideElement] = []
        for child in layer.spTree?.children ?? [] {
            let ph = Placeholder(element: child)
            var chain: [(Placeholder, PartContext)] = []
            if let ph {
                guard let inherit else { continue }
                chain = inherit(ph)
            }
            if let e = element(child, layer: layer, placeholder: ph, chain: chain) { out.append(e) }
        }
        return out
    }

    private mutating func element(_ n: OOXMLNode, layer: SlideLayer, placeholder: Placeholder?,
                                  chain: [(Placeholder, PartContext)]) -> SlideElement? {
        if Self.isHidden(n) { return nil }
        switch n.name {
        case "sp", "cxnSp":
            // Empty slide placeholders are not drawn in slide show or print, inherited fill and line included,
            // unless the slide gives the shape a fill or line of its own (docs/decisions.md).
            if layer.kind == .slide, placeholder != nil, TextBodyLayout.isEmptyText(n.child("txBody")),
               !Self.hasOwnVisual(n.child("spPr")) { return nil }
            return .shape(shape(n, layer: layer, placeholder: placeholder, chain: chain))
        case "pic":
            // An empty picture placeholder (no image) draws nothing either.
            if layer.kind == .slide, placeholder != nil,
               n.child("blipFill")?.child("blip")?.attr("embed", ns: NS.r) == nil { return nil }
            return .picture(picture(n, layer: layer, chain: chain))
        case "grpSp":
            let group = GroupModel(grpSpPr: n.child("grpSpPr"), colors: colors, part: layer.part, children: [])
            let children = n.children.compactMap { element($0, layer: layer, placeholder: nil, chain: []) }
            return .group(group, children)
        case "graphicFrame":
            let xfrm = n.child("xfrm") ?? Self.first(chain.map { $0.0.node.child("spPr")?.child("xfrm") })
            let tag = placeholder.map { addText(nil, layer: layer, placeholder: $0, chain: chain, style: nil) }
            let data = n.child("graphic")?.child("graphicData")
            let transform = Transform2D(xfrm: xfrm)
            var table: TableModel?
            if data?.attr("uri") == SlideTextBuilder.tableURI, let tbl = data?.child("tbl") {
                table = TableModel(tbl: tbl, id: tableCount, transform: transform, styles: tableStyles, colors: colors,
                                   layer: layer.kind, part: layer.part)
                tableCount += 1
            } else if let data, let other = graphicFrame(data, transform: transform, layer: layer, tag: tag) {
                return other
            }
            return .graphicFrame(GraphicFrameModel(transform: transform, graphicData: data, part: layer.part, tag: tag,
                                                   table: table))
        default:
            return nil // p:contentPart, nvGrpSpPr, grpSpPr, extLst, unknown elements
        }
    }

    // MARK: shapes and pictures

    /// The shape's own spPr first, then those of the placeholders it inherits from, each with its part.
    private func spPrChain(_ n: OOXMLNode, layer: SlideLayer,
                           chain: [(Placeholder, PartContext)]) -> [(OOXMLNode, PartContext)] {
        var out: [(OOXMLNode, PartContext)] = []
        if let s = n.child("spPr") { out.append((s, layer.part)) }
        for (ph, part) in chain { if let s = ph.node.child("spPr") { out.append((s, part)) } }
        return out
    }

    private mutating func shape(_ n: OOXMLNode, layer: SlideLayer, placeholder: Placeholder?,
                                chain: [(Placeholder, PartContext)]) -> ShapeModel {
        let sp = spPrChain(n, layer: layer, chain: chain)
        let style = n.child("style") ?? Self.first(chain.map { $0.0.node.child("style") })
        let colors = self.colors
        let fill: Fill
        if Transform2D.isTrue(n.attr("useBgFill")) {
            fill = background
        } else if let f = sp.lazy.compactMap({ FillResolver.explicitFill($0.0, colors: colors, part: $0.1) }).first {
            fill = f
        } else {
            fill = FillResolver.fill(nil, style: style, colors: colors)
        }
        var model = ShapeModel(transform: Transform2D(xfrm: Self.xfrm(sp)),
                               geometry: Self.geometry(sp),
                               fill: fill,
                               line: LineResolver.line(sp.first { $0.0.child("ln") != nil }?.0, style: style, colors: colors),
                               shadow: EffectResolver.shadow(Self.effectHolder(sp), style: style, colors: colors))
        if n.child("txBody") != nil || placeholder != nil {
            model.tag = addText(n.child("txBody"), layer: layer, placeholder: placeholder, chain: chain, style: style)
        }
        return model
    }

    private func picture(_ n: OOXMLNode, layer: SlideLayer, chain: [(Placeholder, PartContext)]) -> PictureModel {
        let sp = spPrChain(n, layer: layer, chain: chain)
        let style = n.child("style") ?? Self.first(chain.map { $0.0.node.child("style") })
        var model = PictureModel(blipFill: n.child("blipFill"), spPr: n.child("spPr"), style: style,
                                 colors: colors, part: layer.part)
        model.transform = Transform2D(xfrm: Self.xfrm(sp))
        model.geometry = Self.geometry(sp)
        model.line = LineResolver.line(sp.first { $0.0.child("ln") != nil }?.0, style: style, colors: colors)
        model.shadow = EffectResolver.shadow(Self.effectHolder(sp), style: style, colors: colors)
        return model
    }

    /// `part`: the part the text body comes from (default: the layer's; a SmartArt drawing part for its shapes).
    mutating func addText(_ txBody: OOXMLNode?, layer: SlideLayer, placeholder: Placeholder?,
                          chain: [(Placeholder, PartContext)], style: OOXMLNode?, part: PartContext? = nil) -> Int {
        texts.append(ShapeText(layer: layer.kind, placeholder: placeholder, txBody: txBody,
                               inheritedTxBodies: chain.compactMap { $0.0.node.child("txBody") }, part: part ?? layer.part,
                               style: style))
        return texts.count - 1
    }

    // MARK: helpers

    static func isHidden(_ n: OOXMLNode) -> Bool {
        Transform2D.isTrue(n.children.first { $0.name.hasPrefix("nv") }?.child("cNvPr")?.attr("hidden"))
    }

    /// The shape's own `p:spPr` has a fill, or a line with a fill (not `a:noFill`).
    static func hasOwnVisual(_ spPr: OOXMLNode?) -> Bool {
        guard let spPr else { return false }
        let fills: Set<String> = ["solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]
        if spPr.children.contains(where: { fills.contains($0.name) }) { return true }
        return spPr.child("ln")?.children.contains { fills.contains($0.name) } ?? false
    }

    static func first(_ nodes: [OOXMLNode?]) -> OOXMLNode? {
        for n in nodes { if let n { return n } }
        return nil
    }

    /// The first `a:xfrm` with an offset or extent.
    static func xfrm(_ sp: [(OOXMLNode, PartContext)]) -> OOXMLNode? {
        sp.lazy.compactMap { $0.0.child("xfrm") }.first { $0.child("off") != nil || $0.child("ext") != nil }
    }

    static func geometry(_ sp: [(OOXMLNode, PartContext)]) -> Geometry? {
        sp.lazy.compactMap { GeometryBuilder.geometry(from: $0.0) }.first
    }

    /// The first spPr that says anything about effects (an empty effectLst means "no shadow").
    static func effectHolder(_ sp: [(OOXMLNode, PartContext)]) -> OOXMLNode? {
        sp.first { $0.0.child("effectLst") != nil || $0.0.child("effectDag") != nil }?.0
    }
}

extension Transform2D {
    static func isTrue(_ s: String?) -> Bool { s == "1" || s == "true" }
}
