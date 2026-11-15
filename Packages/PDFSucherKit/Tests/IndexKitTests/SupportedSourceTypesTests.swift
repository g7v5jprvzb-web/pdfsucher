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
        // 1.3 Part A: Word/PowerPoint are known kinds, accepted only with includeOffice.
        #expect(SupportedSourceTypes.kind(forExtension: "docx") == .word)
        #expect(SupportedSourceTypes.kind(forExtension: "PPTX") == .powerpoint)
        #expect(SupportedSourceTypes.kind(forExtension: "ppt") == nil)
        #expect(SupportedSourceTypes.accepts(fileExtension: "docx", includeImages: true) == false)
        #expect(SupportedSourceTypes.accepts(fileExtension: "docx", includeImages: false, includeOffice: true))
        #expect(SupportedSourceTypes.accepts(fileName: "~$a.docx", includeImages: true, includeOffice: true) == false)
        #expect(DocumentKind.wordExtensions == SupportedSourceTypes.wordExtensions)
        #expect(DocumentKind.powerpointExtensions == SupportedSourceTypes.powerpointExtensions)
        #expect(DocumentKind(fileExtension: "HEIC") == SupportedSourceTypes.kind(forExtension: "heic"))
        #expect(DocumentKind.imageExtensions == SupportedSourceTypes.imageExtensions)
        #expect(SupportedSourceTypes.accepts(fileExtension: "png", includeImages: false) == false)
        #expect(SupportedSourceTypes.accepts(fileExtension: "pdf", includeImages: false))
        let types = SupportedSourceTypes.openPanelTypes
        #expect(types.contains(.folder) && types.contains(.pdf) && types.contains(.png) && types.contains(.jpeg) && types.contains(.heic))
        #expect(types.contains { $0.preferredFilenameExtension == "dng" || $0.tags[.filenameExtension]?.contains("dng") == true })
    }

    /// 1.3 Part B: ⌘O offers Word/PowerPoint always (the classifier ignores them when „office.include“ is off).
    @Test func openPanelOffersOffice() throws {
        let types = SupportedSourceTypes.openPanelTypes
        #expect(types.contains(try #require(UTType(filenameExtension: "docx"))))
        #expect(types.contains(try #require(UTType(filenameExtension: "pptx"))))
        if let ppt = UTType(filenameExtension: "ppt") { #expect(!types.contains(ppt)) }
    }
}
