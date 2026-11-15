import CoreGraphics
import Foundation
import Testing
import TestSupport
import UniformTypeIdentifiers
@testable import OOXMLKit

private func size(_ d: DecodedImage?) -> CGSize? {
    guard case .bitmap(let img)? = d else { return nil }
    return CGSize(width: img.width, height: img.height)
}

@Suite struct ImageDecoderTests {
    @Test func decodesPNG() throws {
        let pkg = try makePackage { $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255))) }
        let dec = ImageDecoder(package: pkg)
        #expect(size(dec.image(ImageRef(part: "ppt/media/image1.png"))) == CGSize(width: 20, height: 10))
    }

    @Test(arguments: [UTType.tiff, .jpeg, .gif, .bmp])
    func decodesOtherFormats(_ type: UTType) throws {
        let ext = type.preferredFilenameExtension ?? "bin"
        let data = testImage(left: (255, 0, 0), right: (0, 0, 255), type: type)
        let pkg = try makePackage { $0.addData("ppt/media/image1.\(ext)", data) }
        let dec = ImageDecoder(package: pkg)
        #expect(size(dec.image(ImageRef(part: "ppt/media/image1.\(ext)"))) == CGSize(width: 20, height: 10))
    }

    @Test func tiffLoads() throws {
        let data = testImage(left: (0, 255, 0), right: (0, 255, 0), type: .tiff)
        let pkg = try makePackage { $0.addData("word/media/image2.tiff", data) }
        #expect(ImageDecoder(package: pkg).image(ImageRef(part: "word/media/image2.tiff")) != nil)
    }

    @Test func hdPhotoIsIgnored() throws {
        // Even if the bytes were decodable, a .wdp/.jxr/.hdp part is not used (PNG data on purpose).
        let png = testImage(left: (255, 0, 0), right: (0, 0, 255))
        let pkg = try makePackage {
            $0.addData("ppt/media/hdphoto1.wdp", png)
            $0.addData("ppt/media/hdphoto2.jxr", png)
            $0.addData("ppt/media/hdphoto3.hdp", png)
        }
        let dec = ImageDecoder(package: pkg)
        #expect(dec.image(ImageRef(part: "ppt/media/hdphoto1.wdp")) == nil)
        #expect(dec.image(ImageRef(part: "ppt/media/hdphoto2.jxr")) == nil)
        #expect(dec.image(ImageRef(part: "ppt/media/hdphoto3.hdp")) == nil)
    }

    @Test func hdPhotoMagicIsIgnoredWhateverTheExtension() throws {
        var wdp = Data([0x49, 0x49, 0xBC, 0x01])
        wdp.append(Data(count: 60))
        let pkg = try makePackage { $0.addData("ppt/media/image9.png", wdp) }
        #expect(ImageDecoder(package: pkg).image(ImageRef(part: "ppt/media/image9.png")) == nil)
    }

    @Test func garbageEMFAndWMFGiveNil() throws {
        let pkg = try makePackage {
            $0.addData("ppt/media/image1.emf", Data(count: 100))
            $0.addData("ppt/media/image2.wmf", Data(count: 100))
        }
        let dec = ImageDecoder(package: pkg)
        #expect(dec.image(ImageRef(part: "ppt/media/image1.emf")) == nil)
        #expect(dec.image(ImageRef(part: "ppt/media/image2.wmf")) == nil)
    }

    @Test func missingOrGarbageGivesNil() throws {
        let pkg = try makePackage { $0.addData("ppt/media/bad.png", Data("not an image".utf8)) }
        let dec = ImageDecoder(package: pkg)
        #expect(dec.image(ImageRef(part: "ppt/media/missing.png")) == nil)
        #expect(dec.image(ImageRef(part: "ppt/media/bad.png")) == nil)
        #expect(dec.image(ImageRef(part: "")) == nil)
    }

    @Test func cacheReturnsSameImageAndIgnoresCropForKey() throws {
        let pkg = try makePackage { $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255))) }
        let dec = ImageDecoder(package: pkg)
        guard case .bitmap(let a)? = dec.image(ImageRef(part: "ppt/media/image1.png")),
              case .bitmap(let b)? = dec.image(ImageRef(part: "ppt/media/image1.png",
                                                       srcRect: SrcRect(l: 0.5, t: 0, r: 0, b: 0)))
        else { Issue.record("no image"); return }
        #expect(a === b)
    }

    @Test func sizeAwareDecodingUsesPowerOfTwoBuckets() throws {
        let pkg = try makePackage { $0.addData("ppt/media/big.png", testImage(width: 1000, height: 500, left: (255, 0, 0), right: (0, 0, 255))) }
        let dec = ImageDecoder(package: pkg)
        let part = "ppt/media/big.png"
        #expect(size(dec.image(part: part, maxPixel: 200)) == CGSize(width: 256, height: 128))
        #expect(size(dec.image(part: part, maxPixel: 256)) == CGSize(width: 256, height: 128))
        #expect(size(dec.image(part: part, maxPixel: 300)) == CGSize(width: 512, height: 256))
        #expect(size(dec.image(part: part, maxPixel: 1)) == CGSize(width: 64, height: 32))      // smallest bucket
        // At or above the native size: the full image, the same object as without a size.
        guard case .bitmap(let full)? = dec.image(part: part), case .bitmap(let big)? = dec.image(part: part, maxPixel: 3000),
              case .bitmap(let a)? = dec.image(part: part, maxPixel: 200), case .bitmap(let b)? = dec.image(part: part, maxPixel: 150)
        else { Issue.record("no image"); return }
        #expect(full === big && full.width == 1000)
        #expect(a === b)                                                                         // one bucket, one decode
        // Garbage and metafiles ignore the size.
        #expect(dec.image(part: "ppt/media/missing.png", maxPixel: 100) == nil)
    }

    @Test func pixelSizeDecodingUsesThePerAxisNeed() throws {
        // A 1000×50 strip stretched into a square: the short side decides, not the long one.
        let pkg = try makePackage { $0.addData("ppt/media/strip.png", testImage(width: 1000, height: 50, left: (255, 0, 0), right: (0, 0, 255))) }
        let dec = ImageDecoder(package: pkg)
        let part = "ppt/media/strip.png"
        // 20×20 px box: 20/50 of the height → 400 px long side → 512 bucket (512×26), not 64×4.
        let small = try #require(size(dec.image(part: part, pixelSize: CGSize(width: 20, height: 20))))
        #expect(small.width == 512 && small.height >= 20)
        // 40×40 px box: needs 800 px → bucket 1024 ≥ native → the full image.
        #expect(size(dec.image(part: part, pixelSize: CGSize(width: 40, height: 40))) == CGSize(width: 1000, height: 50))
        // Same aspect as the image: same as the long-side request.
        #expect(size(dec.image(part: part, pixelSize: CGSize(width: 200, height: 10))) == CGSize(width: 256, height: 13))
        // Degenerate sizes and missing parts behave like `image(part:)`.
        #expect(size(dec.image(part: part, pixelSize: .zero)) == CGSize(width: 1000, height: 50))
        #expect(size(dec.image(part: part, pixelSize: CGSize(width: CGFloat.nan, height: 1))) == CGSize(width: 1000, height: 50))
        #expect(dec.image(part: "ppt/media/missing.png", pixelSize: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func cacheEvictsLeastRecentlyUsedEntries() throws {
        // Three 100×100 images (40 000 bytes each), room for two: using A again before C arrives evicts B, not A.
        let pkg = try makePackage {
            for n in ["a", "b", "c"] { $0.addData("ppt/media/\(n).png", testImage(width: 100, height: 100, left: (255, 0, 0), right: (0, 0, 255))) }
        }
        let dec = ImageDecoder(package: pkg, cacheLimit: 90_000)
        func img(_ n: String) -> CGImage? {
            if case .bitmap(let i)? = dec.image(part: "ppt/media/\(n).png") { return i }
            return nil
        }
        guard let a1 = img("a"), let b1 = img("b") else { Issue.record("no image"); return }
        _ = img("a")
        _ = img("c")
        #expect(img("a") === a1)
        #expect(img("b") !== b1)
        #expect(dec.cachedBytes <= 90_000)
    }

    @Test func concurrentAccessIsSafe() async throws {
        let pkg = try makePackage { $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255))) }
        let dec = ImageDecoder(package: pkg)
        let ok = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 { group.addTask { dec.image(ImageRef(part: "ppt/media/image1.png")) != nil } }
            var all = true
            for await r in group { all = all && r }
            return all
        }
        #expect(ok)
    }

    @Test func imageRefFromBlipFillResolvesRelationshipAndCrop() throws {
        let pkg = try makePackage {
            $0.add("ppt/slides/slide1.xml", "<x/>")
            $0.add("ppt/slides/_rels/slide1.xml.rels", slideRels([("rId2", "../media/image1.png")]))
            $0.addData("ppt/media/image1.png", testImage(left: (255, 0, 0), right: (0, 0, 255)))
        }
        let part = PartContext(package: pkg, part: "ppt/slides/slide1.xml")
        let bf = try xml("""
        <p:blipFill \(drawingNS)><a:blip r:embed="rId2"><a:alphaModFix amt="40000"/></a:blip>\
        <a:srcRect l="10000" t="-5000" r="20000"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        """)
        let ref = ImageRef(blipFill: bf, in: part)
        #expect(ref?.part == "ppt/media/image1.png")
        #expect(ref?.srcRect == SrcRect(l: 0.1, t: -0.05, r: 0.2, b: 0))
        #expect(ref?.alphaModFix == 0.4)

        let missing = try xml("<p:blipFill \(drawingNS)><a:blip r:embed=\"rId9\"/></p:blipFill>")
        #expect(ImageRef(blipFill: missing, in: part) == nil)
        let linked = try xml("<p:blipFill \(drawingNS)><a:blip r:link=\"rId2\"/></p:blipFill>")
        #expect(ImageRef(blipFill: linked, in: part) == nil)
    }
}
