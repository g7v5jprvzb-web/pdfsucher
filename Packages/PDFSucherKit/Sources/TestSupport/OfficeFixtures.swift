// OfficeFixtures.swift — 1.3 Office Task 4: minimal valid OOXML packages (pptx, docx) for tests.
import Foundation

public enum OfficeFixturesError: Error, CustomStringConvertible {
    case zipFailed(status: Int32, URL)

    public var description: String {
        switch self {
        case .zipFailed(let status, let url): "OfficeFixtures: /usr/bin/zip exited with \(status) for \(url.path)"
        }
    }
}

/// Minimal Office Open XML packages, zipped with `/usr/bin/zip -X -r` (test support only).
/// All indices are 0-based positions in the passed arrays.
public enum OfficeFixtures {

    // MARK: PowerPoint

    /// Writes `<dir>/<name>`: a 4:3 deck (720 × 540 pt) with one slide per entry of `slides`; each slide holds its
    /// text in one text box (a `\n` starts a new paragraph). Slides in `hidden` get `show="0"` on `p:sld`
    /// (PowerPoint skips them; Quick Look leaves them out). Slides in `slideNumberFieldOn` get a second text box
    /// with a slide-number field (`<a:fld type="slidenum">`) whose cached text is `‹#›`. A `.pptm` name gets the
    /// macro-enabled main content type (no macros inside). With `slideImages` (PNG data), slide `i` also shows
    /// `slideImages[i % count]` over the whole slide, behind its text (each image stored once, as `ppt/media/imageN.png`).
    @discardableResult
    public static func pptx(slides: [String], hidden: Set<Int> = [], slideNumberFieldOn: Set<Int> = [],
                            slideImages: [Data] = [], name: String = "Folien.pptx", in dir: URL) throws -> URL {
        var files: [String: Data] = [:]
        let count = slides.count
        let slideOverrides = (0..<count).map {
            #"<Override PartName="/ppt/slides/slide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }.joined()
        files["[Content_Types].xml"] = xml("""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/ppt/presentation.xml" ContentType="\(presentationContentType(name))"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
            \(slideOverrides)</Types>
            """)
        files["_rels/.rels"] = xml(relationships([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "ppt/presentation.xml"),
        ]))
        var presentationRels = [
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme", "theme/theme1.xml"),
        ]
        var slideIDs = ""
        for index in 0..<count {
            presentationRels.append(("rId\(index + 3)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
                                     "slides/slide\(index + 1).xml"))
            slideIDs += #"<p:sldId id="\#(256 + index)" r:id="rId\#(index + 3)"/>"#
        }
        files["ppt/_rels/presentation.xml.rels"] = xml(relationships(presentationRels))
        files["ppt/presentation.xml"] = xml("""
            <p:presentation \(pmlNamespaces)>\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            \(count > 0 ? "<p:sldIdLst>\(slideIDs)</p:sldIdLst>" : "")\
            <p:sldSz cx="9144000" cy="6858000" type="screen4x3"/><p:notesSz cx="6858000" cy="9144000"/>\
            </p:presentation>
            """)
        files["ppt/slideMasters/slideMaster1.xml"] = xml("""
            <p:sldMaster \(pmlNamespaces)><p:cSld>\(emptyTree)</p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
            accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
            """)
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = xml(relationships([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme", "../theme/theme1.xml"),
        ]))
        files["ppt/slideLayouts/slideLayout1.xml"] = xml("""
            <p:sldLayout \(pmlNamespaces) type="blank"><p:cSld name="Leer">\(emptyTree)</p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """)
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = xml(relationships([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/slideMaster1.xml"),
        ]))
        files["ppt/theme/theme1.xml"] = xml(theme)
        for (index, image) in slideImages.enumerated() { files["ppt/media/image\(index + 1).png"] = image }
        for (index, text) in slides.enumerated() {
            let picture = slideImages.isEmpty ? "" : """
                <p:pic><p:nvPicPr><p:cNvPr id="4" name="Bild"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="6858000"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                """
            var shapes = picture + textBox(id: 2, name: "Text", x: 457_200, y: 457_200, cx: 8_229_600, cy: 4_572_000,
                                 runs: text.components(separatedBy: "\n").map { run(escape($0), size: 2800) })
            if slideNumberFieldOn.contains(index) {
                let field = #"<a:fld id="{B6F15528-21DE-4FAA-801E-634DDDAF4B2B}" type="slidenum"><a:rPr lang="de-DE" sz="1200"/><a:t>‹#›</a:t></a:fld>"#
                shapes += textBox(id: 3, name: "Foliennummer", x: 7_315_200, y: 6_172_200, cx: 1_371_600, cy: 365_125,
                                  runs: [field])
            }
            files["ppt/slides/slide\(index + 1).xml"] = xml("""
                <p:sld \(pmlNamespaces)\(hidden.contains(index) ? #" show="0""# : "")><p:cSld><p:spTree>\(treeHeader)\
                \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """)
            var slideRels = [
                ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ]
            if !slideImages.isEmpty {
                slideRels.append(("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                                  "../media/image\(index % slideImages.count + 1).png"))
            }
            files["ppt/slides/_rels/slide\(index + 1).xml.rels"] = xml(relationships(slideRels))
        }
        return try package(files, name: name, in: dir)
    }

    // MARK: Word

    /// Writes `<dir>/<name>`: an A4 document with one `w:p` per entry of `paragraphs`; after each paragraph in
    /// `pageBreakAfter` follows a paragraph holding only `<w:br w:type="page"/>`. With `imagePNG`, a last paragraph
    /// holds that PNG inline (96 dpi, at most 15 cm wide). Without `sectionProperties` the body has no `w:sectPr`
    /// (no page size or margins in the file). A `.docm`/`.dotx` name gets the macro-enabled/template main content
    /// type (no macros inside).
    @discardableResult
    public static func docx(paragraphs: [String], pageBreakAfter: Set<Int> = [], imagePNG: Data? = nil,
                            sectionProperties: Bool = true, name: String = "Dokument.docx", in dir: URL) throws -> URL {
        var files: [String: Data] = [:]
        files["[Content_Types].xml"] = xml("""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" ContentType="\(documentContentType(name))"/>\
            </Types>
            """)
        files["_rels/.rels"] = xml(relationships([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "word/document.xml"),
        ]))
        var body = ""
        for (index, text) in paragraphs.enumerated() {
            body += #"<w:p><w:r><w:t xml:space="preserve">\#(escape(text))</w:t></w:r></w:p>"#
            if pageBreakAfter.contains(index) { body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"# }
        }
        var documentRels: [(String, String, String)] = []
        if let imagePNG {
            files["word/media/image1.png"] = imagePNG
            documentRels.append(("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "media/image1.png"))
            body += inlineImage(pixelSize: pngSize(imagePNG) ?? (200, 100))
        }
        files["word/_rels/document.xml.rels"] = xml(relationships(documentRels))
        let sectPr = sectionProperties ? """
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
            <w:pgMar w:top="1417" w:right="1417" w:bottom="1134" w:left="1417" w:header="708" w:footer="708" w:gutter="0"/>\
            </w:sectPr>
            """ : ""
        files["word/document.xml"] = xml("""
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\(sectPr)</w:body></w:document>
            """)
        return try package(files, name: name, in: dir)
    }

    // MARK: Parts

    private static let pmlNamespaces = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """

    private static let treeHeader = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

    private static var emptyTree: String { "<p:spTree>\(treeHeader)</p:spTree>" }

    private static func run(_ escapedText: String, size: Int) -> String {
        #"<a:r><a:rPr lang="de-DE" sz="\#(size)"/><a:t>\#(escapedText)</a:t></a:r>"#
    }

    /// `runs` are the contents of one paragraph each (already escaped XML).
    private static func textBox(id: Int, name: String, x: Int, y: Int, cx: Int, cy: Int, runs: [String]) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr wrap="square"/><a:lstStyle/>\(runs.map { "<a:p>\($0)</a:p>" }.joined())</p:txBody></p:sp>
        """
    }

    private static let theme = """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements>\
        <a:clrScheme name="Office"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2>\
        <a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2>\
        <a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4>\
        <a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6>\
        <a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme>\
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Office"><a:fillStyleLst>\(String(repeating: #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#, count: 3))</a:fillStyleLst>\
        <a:lnStyleLst>\(String(repeating: #"<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#, count: 3))</a:lnStyleLst>\
        <a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst>\
        <a:bgFillStyleLst>\(String(repeating: #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#, count: 3))</a:bgFillStyleLst>\
        </a:fmtScheme></a:themeElements></a:theme>
        """

    private static func inlineImage(pixelSize: (width: Int, height: Int)) -> String {
        let emuPerPixel = 9_525, maxWidth = 5_400_000 // 15 cm
        var cx = pixelSize.width * emuPerPixel, cy = pixelSize.height * emuPerPixel
        if cx > maxWidth { cy = cy * maxWidth / cx; cx = maxWidth }
        return """
            <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="1" name="Bild 1"/>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
            </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
    }

    /// Width and height from the PNG's IHDR chunk.
    private static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[12...15].elementsEqual("IHDR".utf8) else { return nil }
        let number = { (offset: Int) in bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (number(16), number(20))
    }

    // MARK: Helpers

    private static func relationships(_ entries: [(id: String, type: String, target: String)]) -> String {
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + entries.map { #"<Relationship Id="\#($0.id)" Type="\#($0.type)" Target="\#($0.target)"/>"# }.joined()
            + "</Relationships>"
    }

    /// Main part content type by extension, as Word writes it: `.docm` macro-enabled, `.dotx` template, else docx.
    static func documentContentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "docm": "application/vnd.ms-word.document.macroEnabled.main+xml"
        case "dotx": "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml"
        default: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
        }
    }

    /// Main part content type by extension, as PowerPoint writes it: `.pptm` macro-enabled, else pptx.
    static func presentationContentType(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased() == "pptm"
            ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml"
            : "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
    }

    private static func xml(_ body: String) -> Data {
        Data((#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n" + body).utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Writes `files` into a staging folder and zips it to `<dir>/<name>` (replacing an existing file).
    private static func package(_ files: [String: Data], name: String, in dir: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("OfficeFixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        for (path, data) in files {
            let url = staging.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let output = dir.appendingPathComponent(name)
        try? fileManager.removeItem(at: output)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // `-X` leaves out extra file attributes (uid/gid, extended timestamps).
        zip.arguments = ["-X", "-r", "-q", output.path, "."]
        zip.currentDirectoryURL = staging
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw OfficeFixturesError.zipFailed(status: zip.terminationStatus, output) }
        return output
    }
}
