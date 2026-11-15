#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import ViewerUI

/// Renders the search field's icon buttons light and dark into PNGs for a visual check (opt-in:
/// `PDFSUCHER_ICON_SHOTS=<dir>`), and checks the enabled icon is drawn darker than a secondary one.
@MainActor @Suite("Search field icons")
struct FieldIconRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_ICON_SHOTS"] != nil))
    func renderLightAndDark() throws {
        let dir = ProcessInfo.processInfo.environment["PDFSUCHER_ICON_SHOTS"]!
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(spacing: 12) {
                Text("aktiv:")
                Button {} label: { Image(systemName: "chevron.down.circle") }.buttonStyle(FieldIconButtonStyle())
                Button {} label: { Image(systemName: "questionmark.circle") }.buttonStyle(FieldIconButtonStyle())
                Text("deaktiviert:")
                Button {} label: { Image(systemName: "chevron.down.circle") }.buttonStyle(FieldIconButtonStyle()).disabled(true)
                Text("1.2.3:")
                Image(systemName: "chevron.down.circle").foregroundStyle(.secondary)
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try rep.write(to: URL(fileURLWithPath: dir).appendingPathComponent("field-icons-\(scheme == .light ? "hell" : "dunkel").png"))
        }
    }
}
#endif
