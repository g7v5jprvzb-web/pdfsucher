import Foundation
@testable import IndexKit
import Testing
import UniformTypeIdentifiers

/// 1.2.1: the accepted file types live in one place (drop, ⌘O and the folder scanner use it).
@Suite("Supported source types")
struct SupportedSourceTypesTests {
    @Test func supportedTypesInOnePlace() {
        #expect(SupportedSourceTypes.kind(forExtension: "PDF") == .pdf)
        #expect(SupportedSourceTypes.kind(forExtension: "jpeg") == .image)
        #expect(SupportedSourceTypes.kind(forExtension: "docx") == nil)
        #expect(DocumentKind(fileExtension: "HEIC") == SupportedSourceTypes.kind(forExtension: "heic"))
        #expect(DocumentKind.imageExtensions == SupportedSourceTypes.imageExtensions)
        #expect(SupportedSourceTypes.accepts(fileExtension: "png", includeImages: false) == false)
        #expect(SupportedSourceTypes.accepts(fileExtension: "pdf", includeImages: false))
        let types = SupportedSourceTypes.openPanelTypes
        #expect(types.contains(.folder) && types.contains(.pdf) && types.contains(.png) && types.contains(.jpeg) && types.contains(.heic))
        #expect(types.contains { $0.preferredFilenameExtension == "dng" || $0.tags[.filenameExtension]?.contains("dng") == true })
    }
}
