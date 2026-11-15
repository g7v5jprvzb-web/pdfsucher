// GraphicFrames.swift — Task 12b (SlideKit)
// Graphic frames other than tables, turned into ordinary slide elements while the slide model is built:
//
// - SmartArt (`…/diagram`): the drawing PowerPoint stores with the diagram (`dsp:drawing`, a diagramDrawing part)
//   becomes a group placed at the frame; its shapes and text are built like slide shapes (same model builders,
//   slide colors), so drawing, text layout, slideText and wordBoxes need nothing extra. A shape's `dsp:txXfrm`
//   (its own text rectangle) becomes an invisible text-only shape right after it. No drawing part → empty frame.
// - Charts (`…/chart`): parsed into a `ChartModel` (ChartModel.swift), laid out and drawn by ChartRenderer.swift.
// - OLE objects (`…/ole`): the still image, drawn as a picture at the frame: `p:oleObj/p:pic` (also the one of an
//   `mc:Fallback`, which SlideLayer prefers over VML choices), else the legacy VML shape's `v:imagedata`.
//   No image → empty frame.
// - Anything else: an empty frame (`.graphicFrame` without table or chart).
//
// Video/audio are `p:pic` elements (Task 9) whose blip is the poster frame; nothing to do here.
import CoreGraphics
import Foundation
import OOXMLKit

enum GraphicFrames {
    static let diagramURI = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let oleURI = "http://schemas.openxmlformats.org/presentationml/2006/ole"
    static let diagramDrawingType = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"
    static let officeNS = "urn:schemas-microsoft-com:office:office"

    /// Nesting limit for `dsp:grpSp` (the XML parser already stops at depth 256).
    static let maxDiagramDepth = 64

    // MARK: SmartArt

    /// The diagram's drawing part (docs/decisions.md): the data part's `dsp:dataModelExt relId` decides when
    /// present (unresolvable → none, so a SmartArt without a stored drawing never borrows another one's); else the
    /// slide's only diagramDrawing relationship; else the diagramDrawing relationship (or any relationship) whose
    /// target is `drawingN.xml` with the data part's N; else the first diagramDrawing relationship.
    static func diagramDrawingPath(relIds: OOXMLNode?, part: PartContext) -> String? {
        let rels = part.relationships.values.filter { !$0.external }.sorted { $0.id < $1.id }
        let drawings = rels.filter { $0.type == diagramDrawingType }.compactMap { part.targetPart($0.id) }
        let dataPath = relIds?.attr("dm", ns: NS.r).flatMap(part.targetPart)
        if let dataPath, let data = try? part.package.xml(dataPath),
           let ext = data.child("extLst")?.children("ext").lazy.compactMap({ $0.child("dataModelExt") }).first,
           let relId = ext.attr("relId") {
            return part.targetPart(relId)
        }
        if drawings.count == 1 { return drawings[0] }
        if let n = dataPath.flatMap({ number($0, prefix: "data") }) {
            let numbered = { (path: String) in number(path, prefix: "drawing") == n && path.contains("diagrams/") }
            if let hit = drawings.first(where: numbered) { return hit }
            if let hit = rels.compactMap({ part.targetPart($0.id) }).first(where: numbered) { return hit }
        }
        return drawings.first
    }

    /// N of ".../<prefix>N.xml", nil if the file name has another form.
    static func number(_ path: String, prefix: String) -> Int? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard name.hasPrefix(prefix), name.lowercased().hasSuffix(".xml") else { return nil }
        return Int(name.dropFirst(prefix.count).dropLast(4))
    }

    // MARK: OLE

    /// The still image of `p:oleObj` as a picture at `transform`, nil if there is none.
    static func olePicture(_ data: OOXMLNode, transform: Transform2D, layer: SlideLayer,
                           colors: ColorContext) -> PictureModel? {
        guard let ole = data.child("oleObj") else { return nil }
        if let pic = ole.child("pic"), let blipFill = pic.child("blipFill") {
            var model = PictureModel(blipFill: blipFill, spPr: pic.child("spPr"), style: pic.child("style"),
                                     colors: colors, part: layer.part)
            model.transform = transform
            return model.image == nil ? nil : model
        }
        guard let image = vmlImage(spid: ole.attr("spid"), part: layer.part) else { return nil }
        return PictureModel(transform: transform, image: image)
    }

    /// `v:imagedata` of the legacy VML shape `spid` in the part's vmlDrawing.
    static func vmlImage(spid: String?, part: PartContext) -> ImageRef? {
        guard let spid, !spid.isEmpty, let vmlPath = DeckStore.related("vmlDrawing", in: part),
              let vml = try? part.package.xml(vmlPath),
              let shape = first(in: vml, depth: 0, where: { $0.attr("id") == spid || $0.attr("spid", ns: officeNS) == spid }),
              let imagedata = shape.child("imagedata"),
              let rId = imagedata.attr("relid", ns: officeNS) ?? imagedata.attr("id", ns: NS.r) else { return nil }
        let vmlPart = PartContext(package: part.package, part: vmlPath)
        return vmlPart.targetPart(rId).map { ImageRef(part: $0) }
    }

    /// Depth-first search (pre-order).
    private static func first(in node: OOXMLNode, depth: Int, where pred: (OOXMLNode) -> Bool) -> OOXMLNode? {
        if pred(node) { return node }
        guard depth < 256 else { return nil }
        for c in node.children {
            if let hit = first(in: c, depth: depth + 1, where: pred) { return hit }
        }
        return nil
    }
}

extension ElementBuilder {
    /// The element for a non-table graphic frame, nil for an empty frame or an unknown kind.
    mutating func graphicFrame(_ data: OOXMLNode, transform: Transform2D, layer: SlideLayer, tag: Int?) -> SlideElement? {
        switch data.attr("uri") {
        case GraphicFrames.diagramURI:
            return smartArt(data, transform: transform, layer: layer)
        case GraphicFrames.oleURI:
            return GraphicFrames.olePicture(data, transform: transform, layer: layer, colors: colors).map(SlideElement.picture)
        case GraphicFrames.chartURI:
            guard let rId = data.child("chart")?.attr("id", ns: NS.r), let path = layer.part.targetPart(rId),
                  let xml = try? layer.part.package.xml(path),
                  let chart = ChartModel(chartSpace: xml, id: chartCount, colors: colors) else { return nil }
            chartCount += 1
            return .graphicFrame(GraphicFrameModel(transform: transform, graphicData: data, part: layer.part, tag: tag,
                                                   chart: chart))
        default:
            return nil
        }
    }

    /// The diagram's stored drawing as a group at the frame (child space = frame space, 1:1).
    private mutating func smartArt(_ data: OOXMLNode, transform: Transform2D, layer: SlideLayer) -> SlideElement? {
        guard let path = GraphicFrames.diagramDrawingPath(relIds: data.child("relIds"), part: layer.part),
              let drawing = try? layer.part.package.xml(path), let spTree = drawing.child("spTree") else { return nil }
        let part = PartContext(package: layer.part.package, part: path)
        var frame = transform
        frame.childOffset = .zero
        frame.childExtent = transform.extent
        let inner = GroupModel(grpSpPr: spTree.child("grpSpPr"), colors: colors, part: part, children: [])
        let children = diagramChildren(spTree, layer: layer, part: part, depth: 0)
        return .group(GroupModel(transform: frame, children: []), [.group(inner, children)])
    }

    private mutating func diagramChildren(_ tree: OOXMLNode, layer: SlideLayer, part: PartContext, depth: Int) -> [SlideElement] {
        var out: [SlideElement] = []
        for n in tree.children where !Self.isHidden(n) {
            switch n.name {
            case "sp":
                let style = n.child("style")
                var shape = ShapeModel(spPr: n.child("spPr"), style: style, colors: colors, part: part)
                let txBody = n.child("txBody")
                let hasText = txBody.map { !TextBodyLayout.isEmptyText($0) } ?? false
                if hasText, let txXfrm = n.child("txXfrm") {
                    out.append(.shape(shape))
                    let tag = addText(txBody, layer: layer, placeholder: nil, chain: [], style: style, part: part)
                    out.append(.shape(ShapeModel(transform: Transform2D(xfrm: txXfrm), tag: tag)))
                } else {
                    if hasText { shape.tag = addText(txBody, layer: layer, placeholder: nil, chain: [], style: style, part: part) }
                    out.append(.shape(shape))
                }
            case "grpSp" where depth < GraphicFrames.maxDiagramDepth:
                let group = GroupModel(grpSpPr: n.child("grpSpPr"), colors: colors, part: part, children: [])
                out.append(.group(group, diagramChildren(n, layer: layer, part: part, depth: depth + 1)))
            default:
                continue
            }
        }
        return out
    }
}
