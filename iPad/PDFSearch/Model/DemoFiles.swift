import UIKit

/// Fictional demo files for UI tests and screenshots (launch argument `-uiTestDemoFiles YES`):
/// replaces the app's own Documents folder with a few PDFs and JPEGs. No real data.
enum DemoFiles {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "uiTestDemoFiles") }

    static func install(in folder: URL = URL.documentsDirectory) throws {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: item)
        }
        let lorem = "Die Lieferung umfasst die vereinbarten Leistungen. Zahlbar innerhalb von 14 Tagen ohne Abzug."
        func page(_ extra: String) -> String { [lorem, extra, lorem].joined(separator: "\n\n") }
        try pdf(folder, "Rechnungen/Rechnung 2026-044 Heizung.pdf", [page("Wartung der Heizungsanlage. Rechnung Nr. 2026-044."),
                                                                   page("Ersatzteile: Dichtung, Filter."),
                                                                   page("Die nächste Wartung ist in zwölf Monaten fällig. Rechnung aufbewahren.")])
        try pdf(folder, "Rechnungen/Rechnung 2026-031 Gartenbau.pdf", [page("Rechnung für Heckenschnitt. Gesamtbetrag 412,00 EUR."),
                                                                     page("Die Rechnung enthält 19 % Umsatzsteuer.")])
        try pdf(folder, "Rechnungen/Stromabrechnung 2025.pdf", [page("Jahresabrechnung Strom. Diese Rechnung ersetzt die Abschläge.")])
        try pdf(folder, "Verträge/Mietvertrag Musterstraße 5.pdf", [page("Mietvertrag über Wohnräume."),
                                                                    page("Für Nachzahlungen folgt eine Rechnung."),
                                                                    page("Kündigungsfrist drei Monate.")])
        try pdf(folder, "Verträge/Handyvertrag.pdf", [page("Laufzeit 24 Monate. Die monatliche Rechnung kommt per E-Mail.")])
        try pdf(folder, "Handbücher/Waschmaschine.pdf", (1...8).map { i in
            page(i == 3 || i == 6 ? "Für Reparaturen außerhalb der Garantie stellt der Kundendienst eine Rechnung." : "Pflegehinweise, Abschnitt \(i).")
        })
        try jpeg(folder, "Fotos/Kassenbon Bäckerei.jpg", ["Bäckerei Morgenrot", "2 Brötchen 1,20", "Summe 4,70 EUR", "Rechnung Nr. 8812"])
        try jpeg(folder, "Fotos/Quittung Baumarkt.jpg", ["QUITTUNG", "Schrauben 4,99", "Summe 11,48 EUR", "Rechnung auf Wunsch"])
        // `-uiTestExtraImages n`: more photos, so an index run lasts long enough to be interrupted.
        let extra = UserDefaults.standard.integer(forKey: "uiTestExtraImages")
        for i in 0..<extra {
            try jpeg(folder, "Stapel/Notiz \(i).jpg", ["Notiz \(i)", "Einkauf Brot Milch", "Termin Werkstatt", "Anruf Vermieter"])
        }
    }

    private static func pdf(_ folder: URL, _ path: String, _ pages: [String]) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let title = (path as NSString).lastPathComponent.replacingOccurrences(of: ".pdf", with: "")
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            for (i, text) in pages.enumerated() {
                context.beginPage()
                let all = NSMutableAttributedString(string: "\(title) – Seite \(i + 1)\n\n", attributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
                all.append(NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 12)]))
                all.draw(in: bounds.insetBy(dx: 60, dy: 70))
            }
        }
    }

    private static func jpeg(_ folder: URL, _ path: String, _ lines: [String]) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1200, height: 1600)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var y: CGFloat = 120
            for (i, line) in lines.enumerated() {
                let font = i == 0 ? UIFont.boldSystemFont(ofSize: 54) : UIFont.systemFont(ofSize: 40)
                NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: UIColor.black]).draw(at: CGPoint(x: 90, y: y))
                y += i == 0 ? 110 : 70
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
