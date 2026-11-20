#if DEBUG
import Foundation
import PDFSearchCore
import UIKit

/// Sample files and a scripted start, for screenshots and trying the app in the simulator.
///
/// Launch arguments (Debug builds only):
///   -demoData YES                 create "Beispiele" in the app's Documents folder, add and index it
///   -demoQuery Vertrag            search for this text (left out: list of all files)
///   -demoScreen library|search|page|photo|selection
enum DemoData {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "demoData") }
    static var query: String? { UserDefaults.standard.string(forKey: "demoQuery") }
    static var screen: String? { UserDefaults.standard.string(forKey: "demoScreen") }

    static var folderURL: URL {
        URL.documentsDirectory.appending(path: "Beispiele", directoryHint: .isDirectory)
    }

    /// Writes the sample files once.
    static func createFilesIfNeeded() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folderURL.path) else { return }
        try fm.createDirectory(at: folderURL.appending(path: "Angebote"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folderURL.appending(path: "Belege"), withIntermediateDirectories: true)
        try writePDF(name: "vertrag_2024.pdf", title: "Dienstleistungsvertrag 2024", pages: 18, hitPages: [1, 3, 4, 7, 9, 11, 12, 15])
        try writePDF(name: "Angebote/angebot_mueller.pdf", title: "Angebot Müller GmbH", pages: 12, hitPages: [2, 3, 5, 6, 8, 10])
        try writePDF(name: "mietvertrag_buero.pdf", title: "Mietvertrag Büro", pages: 9, hitPages: [1, 2, 4, 5, 7])
        try writePDF(name: "rahmenvertrag_it.pdf", title: "Rahmenvertrag IT", pages: 24, hitPages: [2, 14])
        try writePDF(name: "protokoll_maerz.pdf", title: "Protokoll März", pages: 3, hitPages: [])
        try writePhoto(name: "Belege/IMG_2041.jpg", lines: ["Rechnung Nr. 2041", "gemäß Vertrag vom 12.03.", "Leistung März", "Vertragsnummer 4471-B", "Summe 1.250,00 EUR"])
        try writePhoto(name: "Belege/IMG_1988.jpg", lines: ["Quittung", "Anzahlung laut Vertrag", "500,00 EUR"])
        try writePhoto(name: "Belege/IMG_1702.jpg", lines: ["Lieferschein 1702", "Kein Bezug", "3 Kartons"])
    }

    private static let filler = [
        "Die Parteien vereinbaren die folgenden Bedingungen für die Zusammenarbeit.",
        "Leistungen werden monatlich abgerechnet und sind innerhalb von 14 Tagen zahlbar.",
        "Änderungen bedürfen der Schriftform. Mündliche Nebenabreden bestehen nicht.",
        "Die Haftung ist auf den vorhersehbaren, typischen Schaden begrenzt.",
        "Gerichtsstand ist der Sitz des Auftraggebers.",
    ]

    private static func writePDF(name: String, title: String, pages: Int, hitPages: Set<Int>) throws {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let titleFont = UIFont.boldSystemFont(ofSize: 18)
        let headFont = UIFont.boldSystemFont(ofSize: 13)
        let bodyFont = UIFont.systemFont(ofSize: 11)
        let data = renderer.pdfData { context in
            for page in 1...pages {
                context.beginPage()
                var y: CGFloat = 60
                func draw(_ text: String, _ font: UIFont, gap: CGFloat = 8) {
                    let rect = CGRect(x: 60, y: y, width: bounds.width - 120, height: 200)
                    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
                    let height = ceil(attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil).height)
                    attributed.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
                    y += height + gap
                }
                if page == 1 { draw(title, titleFont, gap: 18) }
                draw("§ \(page) Abschnitt \(page)", headFont)
                for paragraph in 0..<6 {
                    var text = filler[(page + paragraph) % filler.count]
                    if hitPages.contains(page) && paragraph % 3 == 0 {
                        text = "Dieser Vertrag regelt in Abschnitt \(page) die Pflichten aus dem Vertrag. " + text
                    }
                    draw(text, bodyFont)
                }
                draw("Seite \(page) von \(pages)", UIFont.systemFont(ofSize: 9))
            }
        }
        try data.write(to: folderURL.appending(path: name))
    }

    private static func writePhoto(name: String, lines: [String]) throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.29, green: 0.26, blue: 0.23, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: -0.05)
            let paper = CGRect(x: -420, y: -620, width: 840, height: 1240)
            UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
            cg.fill(paper)
            var y = paper.minY + 90
            for (index, line) in lines.enumerated() {
                let font = index == 0 ? UIFont.boldSystemFont(ofSize: 56) : UIFont.systemFont(ofSize: 44)
                NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: UIColor.black])
                    .draw(at: CGPoint(x: paper.minX + 70, y: y))
                y += index == 0 ? 120 : 90
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try data.write(to: folderURL.appending(path: name))
    }
}

extension AppModel {
    /// Runs the scripted demo start (Debug builds, launch argument -demoData YES).
    func runDemoIfRequested() async {
        guard DemoData.isRequested else { return }
        do {
            try DemoData.createFilesIfNeeded()
        } catch {
            alertMessage = "Beispieldateien konnten nicht angelegt werden: \(error.localizedDescription)"
            return
        }
        let path = DemoData.folderURL.standardizedFileURL.path
        if !folders.contains(where: { $0.url?.standardizedFileURL.path == path }) {
            await addFolder(DemoData.folderURL)
        }
        await waitForIndexing()

        // Without -demoQuery the search screen shows the list of all files.
        if let text = DemoData.query {
            query = text
            rememberQuery()
        }
        runSearch()
        try? await Task.sleep(for: .milliseconds(600))

        switch DemoData.screen {
        case "search":
            tab = .search
        case "page":
            tab = .search
            if let document = result.pdfDocuments.first, let page = document.pages.dropFirst().first?.number {
                searchPath = [.page(fileID: document.fileID, page: page)]
            }
        case "photo":
            tab = .search
            if let photo = result.photos.first { searchPath = [.photo(fileID: photo.fileID)] }
        case "selection":
            for document in result.pdfDocuments.prefix(2) {
                for page in document.pages.prefix(2) { toggleSelection(document, page: page.number) }
            }
            if let photo = result.photos.first { toggleSelection(photo, page: 1) }
            tab = .selection
        case "library":
            tab = .library
        default:
            break
        }
    }
}
#endif
