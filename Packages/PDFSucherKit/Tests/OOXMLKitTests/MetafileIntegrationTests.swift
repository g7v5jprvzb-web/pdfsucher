import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private let redRef = colorref(255, 0, 0)
private let blueRef = colorref(0, 0, 255)
private let nullPen: UInt32 = 0x8000_0008

@Suite struct MetafileIntegrationTests {
    private func redSquareEMF() -> Data {
        var b = EMFBuilder()
        b.brush(1, color: redRef)
        b.select(1)
        b.select(nullPen)
        b.rectangle(0, 0, 100, 100)
        return b.build()
    }

    @Test func imageDecoderReturnsVectorForEMFAndEMZ() throws {
        let emf = redSquareEMF()
        var w = WMFBuilder()
        w.brush(color: redRef)
        w.select(0)
        w.rectangle(0, 0, 1000, 1000)
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.emf", emf)
            $0.addData("ppt/media/image2.emz", gzip(emf))
            $0.addData("ppt/media/image3.wmf", w.build())
            $0.addData("ppt/media/image4.wmz", gzip(w.build()))
        }
        let dec = ImageDecoder(package: pkg)
        for (part, isEMF) in [("image1.emf", true), ("image2.emz", true), ("image3.wmf", false), ("image4.wmz", false)] {
            guard case .vector(let m)? = dec.image(ImageRef(part: "ppt/media/\(part)")) else {
                Issue.record("\(part) not vector"); continue
            }
            switch m {
            case .emf: #expect(isEMF)
            case .wmf: #expect(!isEMF)
            }
            #expect(m.bounds.width > 0)
        }
    }

    @Test func drawPictureDrawsEMF() throws {
        let pkg = try makePackage { $0.addData("ppt/media/image1.emf", redSquareEMF()) }
        let c = Canvas()
        let t = Transform2D(offset: CGPoint(x: 100, y: 0), extent: CGSize(width: 100, height: 100), rotation: 0,
                            flipH: false, flipV: false)
        renderer(pkg).drawPicture(PictureModel(transform: t, image: ImageRef(part: "ppt/media/image1.emf")), in: c.ctx)
        #expect(c.matches(150, 50, 255, 0, 0))
        #expect(c.isClear(50, 50))
    }

    @Test func recolorEffectsApplyToMetafiles() throws {
        // D2: a duotoned EMF icon is drawn recoloured by PowerPoint. The metafile is rasterized, then recoloured.
        let pkg = try makePackage { $0.addData("ppt/media/image1.emf", redSquareEMF()) }
        let c = Canvas()
        let t = Transform2D(offset: CGPoint(x: 100, y: 0), extent: CGSize(width: 100, height: 100), rotation: 0,
                            flipH: false, flipV: false)
        let ref = ImageRef(part: "ppt/media/image1.emf", effects: [.grayscale])
        renderer(pkg).drawPicture(PictureModel(transform: t, image: ref), in: c.ctx)
        #expect(c.matches(150, 50, 76, 76, 76))   // BT.601 luma of red
        #expect(c.isClear(50, 50))
    }

    @Test func recolorOnMetafileWithHostileCropDoesNotTrap() throws {
        // A crop leaving ~1e-12 of the source visible blows the full image rect up to ~1e14 pt: the raster size
        // must be clamped in floating point before converting to Int.
        let pkg = try makePackage { $0.addData("ppt/media/image1.emf", redSquareEMF()) }
        let c = Canvas()
        let t = Transform2D(offset: CGPoint(x: 100, y: 0), extent: CGSize(width: 1e8, height: 1e8), rotation: 0,
                            flipH: false, flipV: false)
        for crop in [SrcRect(r: 1 - 1e-12), SrcRect(t: 0.5, b: 0.5 - 1e-13), SrcRect(l: -1e300)] {
            let ref = ImageRef(part: "ppt/media/image1.emf", srcRect: crop, effects: [.grayscale])
            renderer(pkg).drawPicture(PictureModel(transform: t, image: ref), in: c.ctx)
        }
        #expect(c.isClear(50, 50))
    }

    @Test func drawPictureCropsEMF() throws {
        // Left half red, right half blue; srcRect l = 50 % shows only the blue half, stretched.
        var b = EMFBuilder()
        b.brush(1, color: redRef); b.brush(2, color: blueRef)
        b.select(nullPen)
        b.select(1); b.rectangle(0, 0, 50, 100)
        b.select(2); b.rectangle(50, 0, 100, 100)
        let pkg = try makePackage { $0.addData("ppt/media/image1.emf", b.build()) }
        let c = Canvas()
        let t = Transform2D(offset: .zero, extent: CGSize(width: 200, height: 100), rotation: 0, flipH: false, flipV: false)
        let ref = ImageRef(part: "ppt/media/image1.emf", srcRect: SrcRect(l: 0.5, t: 0, r: 0, b: 0))
        renderer(pkg).drawPicture(PictureModel(transform: t, image: ref), in: c.ctx)
        #expect(c.matches(10, 50, 0, 0, 255) && c.matches(190, 50, 0, 0, 255))
    }
}

