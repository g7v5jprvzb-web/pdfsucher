// Makes fictional demo PDFs and JPEGs for simulator screenshots (no real data).
// Usage: swift iPad/scripts/make-demo-files.swift <output folder>
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "demo")
let fm = FileManager.default

func pdf(_ path: String, pages: [String]) {
    let url = out.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for (i, text) in pages.enumerated() {
        ctx.beginPDFPage(nil)
        let title = NSAttributedString(string: "\((path as NSString).deletingPathExtension.components(separatedBy: "/").last!) – Seite \(i + 1)",
                                       attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let body = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let all = NSMutableAttributedString(attributedString: title)
        all.append(NSAttributedString(string: "\n\n"))
        all.append(body)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(all), CFRange(),
                                             CGPath(rect: box.insetBy(dx: 60, dy: 70), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func jpeg(_ path: String, lines: [String]) {
    let url = out.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let size = NSSize(width: 1200, height: 1600)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.92, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    var y = size.height - 140
    for (i, line) in lines.enumerated() {
        let font = i == 0 ? NSFont.boldSystemFont(ofSize: 54) : NSFont.systemFont(ofSize: 40)
        NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 90, y: y))
        y -= i == 0 ? 110 : 70
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: url)
}

let lorem = "Die Lieferung umfasst die vereinbarten Leistungen. Zahlbar innerhalb von 14 Tagen ohne Abzug. Bei Fragen wenden Sie sich bitte an den Kundenservice."
func page(_ extra: String) -> String { [lorem, extra, lorem, "Bitte geben Sie bei der Zahlung die Rechnungsnummer an."].joined(separator: "\n\n") }

pdf("Rechnungen/Rechnung 2026-031 Gartenbau.pdf", pages: [page("Rechnung für Heckenschnitt und Rasenpflege. Gesamtbetrag 412,00 EUR."), page("Positionen: Heckenschnitt, Grünschnitt-Entsorgung. Die Rechnung enthält 19 % Umsatzsteuer.")])
pdf("Rechnungen/Rechnung 2026-044 Heizung.pdf", pages: [page("Wartung der Heizungsanlage. Rechnung Nr. 2026-044."), page("Ersatzteile: Dichtung, Filter."), page("Hinweis: Die nächste Wartung ist in zwölf Monaten fällig. Rechnung bitte aufbewahren.")])
pdf("Rechnungen/Stromabrechnung 2025.pdf", pages: [page("Jahresabrechnung Strom. Verbrauch und Abschläge. Diese Rechnung ersetzt alle Abschlagsrechnungen."), page("Neuer Abschlag ab Januar. Tarifdetails im Anhang.")])
pdf("Verträge/Mietvertrag Musterstraße 5.pdf", pages: [page("Mietvertrag über Wohnräume. Die Miete ist monatlich im Voraus zu zahlen."), page("Nebenkosten werden jährlich abgerechnet; eine Rechnung über Nachzahlungen folgt."), page("Kündigungsfrist drei Monate."), page("Unterschriften beider Parteien.")])
pdf("Verträge/Handyvertrag.pdf", pages: [page("Vertrag über Mobilfunkleistungen, Laufzeit 24 Monate. Die monatliche Rechnung kommt per E-Mail.")])
pdf("Verträge/Versicherung Hausrat.pdf", pages: [page("Hausratversicherung, Versicherungssumme und Beitrag."), page("Im Schadensfall bitte Rechnung und Fotos einreichen.")])
pdf("Handbücher/Waschmaschine Bedienungsanleitung.pdf", pages: (1...8).map { i in page(i == 3 || i == 6 ? "Für Reparaturen außerhalb der Garantie stellt der Kundendienst eine Rechnung." : "Programmübersicht und Pflegehinweise, Abschnitt \(i).") })
jpeg("Fotos/Quittung Baumarkt.jpg", lines: ["QUITTUNG", "Baumarkt am Stadtrand", "Schrauben 4,99", "Holzleim 6,49", "Summe 11,48 EUR", "Vielen Dank! Rechnung auf Wunsch."])
jpeg("Fotos/Kassenbon Bäckerei.jpg", lines: ["Bäckerei Morgenrot", "2 Brötchen 1,20", "Kuchen 3,50", "Summe 4,70 EUR", "Rechnung Nr. 8812"])
jpeg("Fotos/Notiz Whiteboard.jpg", lines: ["Projektideen", "Ordnerbaum links", "Kacheln in der Mitte", "Vorschau daneben", "Sprachsuche testen"])
print("ok:", out.path)
