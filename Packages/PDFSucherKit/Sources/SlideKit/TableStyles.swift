// TableStyles.swift — Task 12a (SlideKit)
// Table styles: `ppt/tableStyles.xml` (`a:tblStyleLst`, reached through the presentation's …/tableStyles
// relationship), the built-in styles PowerPoint does not write into decks, and how the parts of a style apply
// to one cell (fill, borders, text properties) — docs/decisions.md, "Table styles".
//
// Lookup (`TableStyleList.style(for:)`): no `a:tableStyleId` → no style; else the deck's style with that ID →
// a built-in style with that ID → built-in "Medium Style 2 – Accent 1" (not the deck's `def`: measured against
// PowerPoint, docs/decisions.md). The built-ins are XML literals that go through the same code as the deck's styles.
//
// Parts, lowest precedence first (each overrides what it specifies): wholeTbl → band1H/band2H (bandRow) →
// band1V/band2V (bandCol) → lastCol → firstCol → lastRow → firstRow → corner cells (nwCell/neCell/swCell/seCell,
// when both of their flags are on).
import CoreGraphics
import Foundation
import OOXMLKit

/// The `a:tblStyle` elements of a deck by normalised style ID.
struct TableStyleList: Sendable {
    let styles: [String: OOXMLNode]

    static let empty = TableStyleList(xml: nil)

    /// `xml`: an `a:tblStyleLst` (anything else → no styles).
    init(xml: OOXMLNode?) {
        var styles: [String: OOXMLNode] = [:]
        if let xml, xml.name == "tblStyleLst" {
            for s in xml.children("tblStyle") {
                guard let id = Self.normalize(s.attr("styleId")), styles[id] == nil else { continue }
                styles[id] = s
            }
        }
        // The list's `def` (default for new tables) is not read: PowerPoint does not use it for tables whose
        // style ID is unknown (docs/decisions.md, corpus table styles).
        self.styles = styles
    }

    /// GUIDs compare case-insensitively, surrounding whitespace ignored; empty → nil.
    static func normalize(_ id: String?) -> String? {
        guard let t = id?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !t.isEmpty else { return nil }
        return t
    }

    /// The style a table with `a:tableStyleId` `id` uses (see the file header); nil without an ID.
    func style(for id: String?) -> OOXMLNode? {
        guard let id = Self.normalize(id) else { return nil }
        let builtIn = Self.builtIn.styles
        if let s = styles[id] ?? builtIn[id] { return s }
        // An ID neither in the deck nor built in here is one of PowerPoint's other built-ins: the deck's def is
        // not what PowerPoint shows (D7), the default new-table style is the closer guess.
        return builtIn[Self.mediumStyle2Accent1]
    }

    static let mediumStyle2Accent1 = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"

    /// PowerPoint's built-in styles that SlideKit knows (decks only carry the styles they use, and not always).
    static let builtIn = TableStyleList(xml: try? OOXMLNode.parse(Data(builtInXML.utf8)))

    private static let tx1Font = "<a:tcTxStyle><a:fontRef idx=\"minor\"><a:scrgbClr r=\"0\" g=\"0\" b=\"0\"/></a:fontRef>"
        + "<a:schemeClr val=\"tx1\"/></a:tcTxStyle>"
    private static func borders(_ ln: String) -> String {
        "<a:tcBdr>" + ["left", "right", "top", "bottom", "insideH", "insideV"].map { "<a:\($0)>\(ln)</a:\($0)>" }.joined()
            + "</a:tcBdr>"
    }
    private static let lt1Line = "<a:ln w=\"12700\" cmpd=\"sng\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill></a:ln>"
    private static let accentText = "<a:tcTxStyle b=\"on\"><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef>"
        + "<a:schemeClr val=\"lt1\"/></a:tcTxStyle>"
    private static func accentFill(_ tint: Int?) -> String {
        "<a:fill><a:solidFill><a:schemeClr val=\"accent1\">" + (tint.map { "<a:tint val=\"\($0)\"/>" } ?? "")
            + "</a:schemeClr></a:solidFill></a:fill>"
    }

    /// "Light Style 2 – Accent 1" as PowerPoint writes it (copied verbatim from a deck's tableStyles.xml).
    static let lightStyle2Accent1XML = #"""
    <a:tblStyle styleId="{69012ECD-51FC-41F1-AA8D-1B2483CD663E}" styleName="Light Style 2 - Accent 1"><a:wholeTbl><a:tcTxStyle><a:fontRef idx="minor"><a:scrgbClr r="0" g="0" b="0"/></a:fontRef><a:schemeClr val="tx1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:left><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:left><a:right><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:right><a:top><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:top><a:bottom><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:bottom><a:insideH><a:ln><a:noFill/></a:ln></a:insideH><a:insideV><a:ln><a:noFill/></a:ln></a:insideV></a:tcBdr><a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl>
    <a:band1H><a:tcStyle><a:tcBdr><a:top><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:top><a:bottom><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:bottom></a:tcBdr></a:tcStyle></a:band1H>
    <a:band1V><a:tcStyle><a:tcBdr><a:left><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:left><a:right><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:right></a:tcBdr></a:tcStyle></a:band1V>
    <a:band2V><a:tcStyle><a:tcBdr><a:left><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:left><a:right><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:right></a:tcBdr></a:tcStyle></a:band2V>
    <a:lastCol><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr/></a:tcStyle></a:lastCol>
    <a:firstCol><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr/></a:tcStyle></a:firstCol>
    <a:lastRow><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr><a:top><a:ln w="50800" cmpd="dbl"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:ln></a:top></a:tcBdr></a:tcStyle></a:lastRow>
    <a:firstRow><a:tcTxStyle b="on"><a:fontRef idx="minor"><a:scrgbClr r="0" g="0" b="0"/></a:fontRef><a:schemeClr val="bg1"/></a:tcTxStyle><a:tcStyle><a:tcBdr/><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef></a:tcStyle></a:firstRow>
    </a:tblStyle>
    """#

    /// "Themed Style 2 – Accent 2" as PowerPoint writes it into decks (verbatim from a deck's tableStyles.xml; D2
    /// uses the ID without defining it, PowerPoint draws its lt1 text).
    static let themedStyle2Accent2XML = #"""
    <a:tblStyle styleId="{18603FDC-E32A-4AB5-989C-0864C3EAD2B8}" styleName="Themed Style 2 - Accent 2"><a:tblBg><a:fillRef idx="3"><a:schemeClr val="accent2"/></a:fillRef><a:effectRef idx="3"><a:schemeClr val="accent2"/></a:effectRef></a:tblBg><a:wholeTbl><a:tcTxStyle><a:fontRef idx="minor"><a:scrgbClr r="0" g="0" b="0"/></a:fontRef><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:left><a:lnRef idx="1"><a:schemeClr val="accent2"><a:tint val="50000"/></a:schemeClr></a:lnRef></a:left><a:right><a:lnRef idx="1"><a:schemeClr val="accent2"><a:tint val="50000"/></a:schemeClr></a:lnRef></a:right><a:top><a:lnRef idx="1"><a:schemeClr val="accent2"><a:tint val="50000"/></a:schemeClr></a:lnRef></a:top><a:bottom><a:lnRef idx="1"><a:schemeClr val="accent2"><a:tint val="50000"/></a:schemeClr></a:lnRef></a:bottom><a:insideH><a:ln><a:noFill/></a:ln></a:insideH><a:insideV><a:ln><a:noFill/></a:ln></a:insideV></a:tcBdr><a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl><a:band1H><a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:schemeClr val="lt1"><a:alpha val="20000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1H><a:band1V><a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:schemeClr val="lt1"><a:alpha val="20000"/></a:schemeClr></a:solidFill></a:fill></a:tcStyle></a:band1V><a:lastCol><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr><a:left><a:lnRef idx="2"><a:schemeClr val="lt1"/></a:lnRef></a:left></a:tcBdr></a:tcStyle></a:lastCol><a:firstCol><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr><a:right><a:lnRef idx="2"><a:schemeClr val="lt1"/></a:lnRef></a:right></a:tcBdr></a:tcStyle></a:firstCol><a:lastRow><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr><a:top><a:lnRef idx="2"><a:schemeClr val="lt1"/></a:lnRef></a:top></a:tcBdr><a:fill><a:noFill/></a:fill></a:tcStyle></a:lastRow><a:seCell><a:tcStyle><a:tcBdr><a:left><a:ln><a:noFill/></a:ln></a:left><a:top><a:ln><a:noFill/></a:ln></a:top></a:tcBdr></a:tcStyle></a:seCell><a:swCell><a:tcStyle><a:tcBdr><a:right><a:ln><a:noFill/></a:ln></a:right><a:top><a:ln><a:noFill/></a:ln></a:top></a:tcBdr></a:tcStyle></a:swCell><a:firstRow><a:tcTxStyle b="on"/><a:tcStyle><a:tcBdr><a:bottom><a:lnRef idx="3"><a:schemeClr val="lt1"/></a:lnRef></a:bottom></a:tcBdr><a:fill><a:noFill/></a:fill></a:tcStyle></a:firstRow><a:neCell><a:tcStyle><a:tcBdr><a:bottom><a:ln><a:noFill/></a:ln></a:bottom></a:tcBdr></a:tcStyle></a:neCell></a:tblStyle>
    """#

    /// "Light Style 2" (no accent): Light Style 2 – Accent 1 with tx1 in place of accent1 (PowerPoint derives the
    /// accent variants from one pattern; D7's PDF shows a tx1 header fill and tx1 lines for this ID).
    static let lightStyle2XML = lightStyle2Accent1XML
        .replacingOccurrences(of: "{69012ECD-51FC-41F1-AA8D-1B2483CD663E}", with: "{7E9639D4-E3E2-4D34-9284-5A2195B3D0D7}")
        .replacingOccurrences(of: "Light Style 2 - Accent 1", with: "Light Style 2")
        .replacingOccurrences(of: "<a:schemeClr val=\"accent1\"/>", with: "<a:schemeClr val=\"tx1\"/>")

    /// "Medium Style 2 – Accent 1" and "Light Style 2 – Accent 1" as PowerPoint writes them into decks; "No Style,
    /// No Grid" and "No Style, Table Grid" (IDs and content from memory — docs/decisions.md).
    static let builtInXML = "<a:tblStyleLst xmlns:a=\"\(NS.a)\">"
        + "<a:tblStyle styleId=\"\(mediumStyle2Accent1)\" styleName=\"Medium Style 2 - Accent 1\">"
        + "<a:wholeTbl><a:tcTxStyle><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef><a:schemeClr val=\"dk1\"/>"
        + "</a:tcTxStyle><a:tcStyle>\(borders(lt1Line))\(accentFill(20000))</a:tcStyle></a:wholeTbl>"
        + "<a:band1H><a:tcStyle><a:tcBdr/>\(accentFill(40000))</a:tcStyle></a:band1H>"
        + "<a:band2H><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2H>"
        + "<a:band1V><a:tcStyle><a:tcBdr/>\(accentFill(40000))</a:tcStyle></a:band1V>"
        + "<a:band2V><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2V>"
        + "<a:lastCol>\(accentText)<a:tcStyle><a:tcBdr/>\(accentFill(nil))</a:tcStyle></a:lastCol>"
        + "<a:firstCol>\(accentText)<a:tcStyle><a:tcBdr/>\(accentFill(nil))</a:tcStyle></a:firstCol>"
        + "<a:lastRow>\(accentText)<a:tcStyle><a:tcBdr><a:top><a:ln w=\"38100\" cmpd=\"sng\"><a:solidFill><a:schemeClr val=\"lt1\"/>"
        + "</a:solidFill></a:ln></a:top></a:tcBdr>\(accentFill(nil))</a:tcStyle></a:lastRow>"
        + "<a:firstRow>\(accentText)<a:tcStyle><a:tcBdr><a:bottom><a:ln w=\"38100\" cmpd=\"sng\"><a:solidFill><a:schemeClr val=\"lt1\"/>"
        + "</a:solidFill></a:ln></a:bottom></a:tcBdr>\(accentFill(nil))</a:tcStyle></a:firstRow>"
        + "</a:tblStyle>" + lightStyle2Accent1XML + lightStyle2XML + themedStyle2Accent2XML
        + "<a:tblStyle styleId=\"{2D5ABB26-0587-4C30-8999-92F81FD0307C}\" styleName=\"No Style, No Grid\"><a:wholeTbl>\(tx1Font)"
        + "<a:tcStyle>\(borders("<a:ln><a:noFill/></a:ln>"))<a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl></a:tblStyle>"
        + "<a:tblStyle styleId=\"{5940675A-B579-460E-94D1-54222C63F5DA}\" styleName=\"No Style, Table Grid\"><a:wholeTbl>\(tx1Font)"
        + "<a:tcStyle>\(borders("<a:ln w=\"12700\" cmpd=\"sng\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill></a:ln>"))"
        + "<a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl></a:tblStyle>"
        + "</a:tblStyleLst>"
}

// MARK: - Applying a style to a cell

/// The `a:tblPr` flags that switch style parts on.
struct TableFlags: Sendable {
    var firstRow = false, lastRow = false, firstCol = false, lastCol = false, bandRow = false, bandCol = false

    init(tblPr: OOXMLNode?) {
        func on(_ k: String) -> Bool { Transform2D.isTrue(tblPr?.attr(k)) }
        firstRow = on("firstRow"); lastRow = on("lastRow"); firstCol = on("firstCol"); lastCol = on("lastCol")
        bandRow = on("bandRow"); bandCol = on("bandCol")
    }
}

/// Cell edges. Diagonals: `diagonalDown` top-left → bottom-right, `diagonalUp` bottom-left → top-right.
enum CellEdge: Int, CaseIterable, Sendable {
    case left, right, top, bottom, diagonalDown, diagonalUp
}

/// A cell's area in the grid: rows `row..<rowEnd`, columns `col..<colEnd` of a `rows` × `cols` table.
struct CellSpan: Sendable, Equatable {
    var row: Int, col: Int, rowEnd: Int, colEnd: Int
}

/// What the table style gives one cell. `nil` entries: the style says nothing (no fill / no line).
struct CellStyle: Sendable {
    var fill: Fill?
    /// Indexed by `CellEdge.rawValue`; `.some(nil)` = the style removes the line.
    var edges = [Line??](repeating: nil, count: CellEdge.allCases.count)
    /// List-style-like text sources from the parts' `a:tcTxStyle`, lowest precedence first.
    var textSources: [OOXMLNode] = []

    /// The parts of `style` that apply to the cell at `span` in a `rows` × `cols` table, merged in order.
    init(style: OOXMLNode?, flags: TableFlags, span s: CellSpan, rows: Int, cols: Int, colors: ColorContext) {
        guard let style else { return }
        for (name, kind) in Self.parts(flags: flags, span: s, rows: rows, cols: cols) {
            guard let part = style.child(name) else { continue }
            apply(part, kind: kind, span: s, rows: rows, cols: cols, colors: colors)
        }
    }

    enum PartKind { case whole, row, column, corner }

    /// Applicable part names in precedence order (lowest first).
    static func parts(flags f: TableFlags, span s: CellSpan, rows: Int, cols: Int) -> [(String, PartKind)] {
        let top = s.row == 0, bottom = s.rowEnd >= rows, left = s.col == 0, right = s.colEnd >= cols
        var out: [(String, PartKind)] = [("wholeTbl", .whole)]
        let headerRow = f.firstRow && top, footerRow = f.lastRow && bottom
        if f.bandRow, !headerRow, !footerRow {
            out.append(((s.row - (f.firstRow ? 1 : 0)) % 2 == 0 ? "band1H" : "band2H", .row))
        }
        let headerCol = f.firstCol && left, footerCol = f.lastCol && right
        if f.bandCol, !headerCol, !footerCol {
            out.append(((s.col - (f.firstCol ? 1 : 0)) % 2 == 0 ? "band1V" : "band2V", .column))
        }
        if footerCol { out.append(("lastCol", .column)) }
        if headerCol { out.append(("firstCol", .column)) }
        if footerRow { out.append(("lastRow", .row)) }
        if headerRow { out.append(("firstRow", .row)) }
        if headerRow, headerCol { out.append(("nwCell", .corner)) }
        if headerRow, footerCol { out.append(("neCell", .corner)) }
        if footerRow, headerCol { out.append(("swCell", .corner)) }
        if footerRow, footerCol { out.append(("seCell", .corner)) }
        return out
    }

    private mutating func apply(_ part: OOXMLNode, kind: PartKind, span s: CellSpan, rows: Int, cols: Int,
                                colors: ColorContext) {
        if let tx = Self.textSource(part.child("tcTxStyle")) { textSources.append(tx) }
        guard let tc = part.child("tcStyle") else { return }
        if let f = tc.child("fill") {
            if let fill = FillResolver.explicitFill(f, colors: colors) { self.fill = fill }
        } else if tc.child("fillRef") != nil {
            fill = FillResolver.fill(nil, style: tc, colors: colors)
        }
        guard let bdr = tc.child("tcBdr") else { return }
        // Edges inside the table use insideH/insideV, except the part's own edges: a row part (header, footer,
        // band) owns its top and bottom, a column part its left and right, a corner cell all four.
        let ownRow = kind == .row || kind == .corner, ownCol = kind == .column || kind == .corner
        let names: [(CellEdge, String)] = [
            (.left, s.col == 0 || ownCol ? "left" : "insideV"),
            (.right, s.colEnd >= cols || ownCol ? "right" : "insideV"),
            (.top, s.row == 0 || ownRow ? "top" : "insideH"),
            (.bottom, s.rowEnd >= rows || ownRow ? "bottom" : "insideH"),
            (.diagonalDown, "tl2br"), (.diagonalUp, "tr2bl"),
        ]
        for (edge, name) in names {
            guard let e = bdr.child(name), e.child("ln") != nil || e.child("lnRef") != nil else { continue }
            edges[edge.rawValue] = .some(Self.border(LineResolver.line(e, style: e, colors: colors)))
        }
    }

    /// Borders never get arrowheads.
    static func border(_ line: Line?) -> Line? {
        guard var line else { return nil }
        line.headEnd = nil
        line.tailEnd = nil
        return line
    }

    static let colorNames: Set<String> = ["srgbClr", "schemeClr", "sysClr", "prstClr", "hslClr", "scrgbClr"]

    /// `a:tcTxStyle` as a list-style-like source (`TextStyleCascade`): b/i on/off (def → unchanged), the color
    /// (its own color element, else the fontRef's) as `a:solidFill`, the typeface (`a:font/a:latin`, else the
    /// fontRef idx major/minor as +mj-lt/+mn-lt). nil when it says nothing.
    static func textSource(_ tx: OOXMLNode?) -> OOXMLNode? {
        guard let tx else { return nil }
        var attrs: [String: String] = [:]
        for k in ["b", "i"] {
            switch tx.attr(k) {
            case "on": attrs[k] = "1"
            case "off": attrs[k] = "0"
            default: break
            }
        }
        var children: [OOXMLNode] = []
        let fontRef = tx.child("fontRef")
        if let c = tx.children.first(where: { colorNames.contains($0.name) }) ?? fontRef?.children.first {
            children.append(OOXMLNode(name: "solidFill", children: [c]))
        }
        if let latin = tx.child("font")?.child("latin") {
            children.append(latin)
        } else if let idx = fontRef?.attr("idx"), idx == "major" || idx == "minor" {
            children.append(OOXMLNode(name: "latin", attributes: ["typeface": idx == "major" ? "+mj-lt" : "+mn-lt"]))
        }
        guard !attrs.isEmpty || !children.isEmpty else { return nil }
        return OOXMLNode(name: "lstStyle", children: [
            OOXMLNode(name: "defPPr", children: [OOXMLNode(name: "defRPr", attributes: attrs, children: children)]),
        ])
    }

    /// The table background: `a:tblPr`'s own fill, else the style's `a:tblBg` (fill or fillRef).
    static func background(tblPr: OOXMLNode?, style: OOXMLNode?, colors: ColorContext, part: PartContext) -> Fill {
        if let tblPr, let f = FillResolver.explicitFill(tblPr, colors: colors, part: part) { return f }
        guard let bg = style?.child("tblBg") else { return .none }
        if let f = bg.child("fill") { return FillResolver.explicitFill(f, colors: colors) ?? .none }
        return FillResolver.fill(nil, style: bg, colors: colors)
    }
}
