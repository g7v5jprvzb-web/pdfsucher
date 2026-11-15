// DeckParser.swift — Tasks 8, 9 (SlideKit)
// Opens a .pptx/.pptm and maps OOXMLKit errors to SlideKitError.
import CoreGraphics
import Foundation
import OOXMLKit

enum DeckParser {
    static let extensions: Set<String> = ["pptx", "pptm"]

    struct Parsed {
        let package: OPCPackage
        let presentationPart: String
        let slides: [SlideRef]
        let slideSize: CGSize
    }

    static func open(url: URL) throws(SlideKitError) -> Parsed {
        // .ppt and everything else is decided by the extension alone, without touching the file.
        guard extensions.contains(url.pathExtension.lowercased()) else { throw .unsupportedFormat }

        let zip: ZipArchive
        do {
            zip = try ZipArchive(url: url)
        } catch .notAZip {
            throw .notAZip
        } catch .oleCompound {
            throw OLECompound.isEncryptedOOXML(url: url) ? .encrypted : .unsupportedFormat
        } catch {
            throw .malformed("zip: \(error)")
        }

        let package = OPCPackage(zip: zip)
        let info: PresentationInfo
        do {
            info = try PresentationInfo(package: package)
        } catch PresentationInfoError.noPresentation {
            throw .malformed("no presentation part")
        } catch PresentationInfoError.malformed(let reason) {
            throw .malformed(reason)
        } catch {
            throw .malformed("\(error)")
        }

        let slides = info.visibleSlides.map { SlideRef(partPath: $0.partPath, powerPointNumber: $0.powerPointNumber) }
        return Parsed(package: package, presentationPart: info.presentationPart, slides: slides, slideSize: info.slideSize)
    }
}
