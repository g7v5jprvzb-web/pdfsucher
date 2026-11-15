import CoreGraphics
import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private let redRef = colorref(255, 0, 0)
private let blueRef = colorref(0, 0, 255)
private let nullPen: UInt32 = 0x8000_0008

/// A builder with a red brush and the stock null pen selected.
private func redBrush() -> EMFBuilder {
    var b = EMFBuilder()
    b.brush(1, color: redRef)
    b.select(1)
    b.select(nullPen)
    return b
}

@Suite struct EMFTests {
    @Test func headerGivesFrameBounds() throws {
        var b = EMFBuilder()
        b.frame = (100, 200, 1100, 2200)
        let doc = try EMFDocument(data: b.build())
        #expect(doc.bounds == CGRect(x: 100, y: 200, width: 1000, height: 2000))
    }

    @Test func garbageThrows() {
        #expect(throws: MetafileError.self) { try EMFDocument(data: Data("hello".utf8)) }
        #expect(throws: MetafileError.self) { try EMFDocument(data: Data(count: 200)) }
        #expect(throws: MetafileError.self) { try WMFDocument(data: Data(count: 3)) }
    }

    @Test func polygonFillsTheRightPixels() throws {
        var b = redBrush()
        b.polygon16([(10, 10), (60, 10), (60, 60), (10, 60)])
        let c = try render(b)
        #expect(c.matches(30, 30, 255, 0, 0))
        #expect(c.matches(55, 15, 255, 0, 0))
        #expect(c.isClear(80, 80) && c.isClear(5, 5) && c.isClear(150, 50))
    }

    @Test func frameMapsOntoTargetRect() throws {
        var b = redBrush()
        b.polygon16([(0, 0), (50, 0), (50, 50), (0, 50)])   // top-left quarter of the frame
        let doc = try EMFDocument(data: b.build())
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 100, y: 0, width: 100, height: 100))
        #expect(c.matches(110, 10, 255, 0, 0) && c.matches(145, 45, 255, 0, 0))
        #expect(c.isClear(155, 55) && c.isClear(50, 10))
    }

    @Test func descriptionAtOffset88IsNotReadAsHeaderExtension() throws {
        // "Adobe…" right after szlMillimeters must not be taken as szlMicrometers.
        var b = redBrush()
        b.description = "Adobe Illustrator"
        b.polygon16([(0, 0), (50, 0), (50, 50), (0, 50)])
        let c = try render(b)
        #expect(c.matches(25, 25, 255, 0, 0) && c.isClear(75, 75))
    }

    @Test func anisotropicWindowViewportMapping() throws {
        var b = redBrush()
        b.mapMode(8)
        b.windowOrg(0, 0)
        b.windowExt(1000, 1000)
        b.viewportOrg(0, 100)
        b.viewportExt(100, -100)       // y up: logical y 0 is the bottom of the frame
        b.polygon16([(0, 0), (500, 0), (500, 300), (0, 300)])
        let c = try render(b)
        // Logical x 0…500 → device 0…50; y 0…300 → device 100…70.
        #expect(c.matches(25, 85, 255, 0, 0))
        #expect(c.isClear(25, 50) && c.isClear(75, 85))
    }

    @Test func isotropicKeepsAspect() throws {
        var b = redBrush()
        b.mapMode(7)
        b.windowExt(100, 200)
        b.viewportExt(100, 100)        // isotropic: scale = min(1, 0.5) = 0.5 in both directions
        b.polygon16([(0, 0), (100, 0), (100, 100), (0, 100)])
        let c = try render(b)
        #expect(c.matches(25, 25, 255, 0, 0))
        #expect(c.isClear(75, 25) && c.isClear(25, 75))
    }

    @Test func worldTransformScales() throws {
        var b = redBrush()
        b.worldTransform(CGAffineTransform(scaleX: 2, y: 2))
        b.polygon16([(0, 0), (10, 0), (10, 10), (0, 10)])
        let c = try render(b)
        #expect(c.matches(15, 15, 255, 0, 0) && c.isClear(25, 25))
    }

    @Test func bezierPathIsFilled() throws {
        var b = redBrush()
        b.beginPath()
        b.moveTo(10, 50)
        // A cubic bulging up to y ≈ 12 between x 10 and 90.
        b.polyBezierTo16([(10, 0), (90, 0), (90, 50)])
        b.closeFigure()
        b.endPath()
        b.fillPath()
        let c = try render(b)
        #expect(c.matches(50, 30, 255, 0, 0))
        #expect(c.isClear(50, 5))            // above the curve's peak (y = 12.5)
        #expect(c.isClear(12, 15))           // outside the curve near the left end
        #expect(c.isClear(50, 60))
    }

    @Test func strokePathUsesPen() throws {
        var b = EMFBuilder()
        b.extPen(1, style: 0x10000, width: 6, color: blueRef)
        b.select(1)
        b.beginPath()
        b.moveTo(10, 50)
        b.lineTo(90, 50)
        b.endPath()
        b.strokePath()
        let c = try render(b)
        #expect(c.matches(50, 50, 0, 0, 255))
        #expect(c.isClear(50, 40))
    }

    @Test func rectangleAndEllipseFillAndStroke() throws {
        var b = redBrush()
        b.rectangle(0, 0, 40, 40)
        b.ellipse(50, 50, 100, 100)
        let c = try render(b)
        #expect(c.matches(20, 20, 255, 0, 0))
        #expect(c.matches(75, 75, 255, 0, 0) && c.isClear(52, 52))
    }

    @Test func stockObjects() throws {
        var b = EMFBuilder()
        b.select(0x8000_0004)          // BLACK_BRUSH
        b.select(nullPen)
        b.rectangle(0, 0, 50, 50)
        b.select(0x8000_0005)          // NULL_BRUSH
        b.select(0x8000_0007)          // BLACK_PEN
        b.rectangle(60, 60, 90, 90)
        let c = try render(b)
        #expect(c.matches(25, 25, 0, 0, 0))
        #expect(c.isClear(75, 75))       // hollow
        #expect(!c.isClear(60, 75))      // outline
    }

    @Test func saveRestoreRestoresBrush() throws {
        var b = EMFBuilder()
        b.brush(1, color: redRef)
        b.brush(2, color: blueRef)
        b.select(nullPen)
        b.select(1)
        b.saveDC()
        b.select(2)
        b.restoreDC(-1)
        b.rectangle(0, 0, 100, 100)
        let c = try render(b)
        #expect(c.matches(50, 50, 255, 0, 0))
    }

    @Test func absoluteRestoreDC() throws {
        var b = EMFBuilder()
        b.brush(1, color: redRef)
        b.brush(2, color: blueRef)
        b.select(nullPen)
        b.select(1)
        b.saveDC()          // level 1: red
        b.select(2)
        b.saveDC()          // level 2: blue
        b.restoreDC(1)
        b.rectangle(0, 0, 100, 100)
        let c = try render(b)
        #expect(c.matches(50, 50, 255, 0, 0))
    }

    @Test func intersectClipRectAndRestore() throws {
        var b = redBrush()
        b.saveDC()
        b.intersectClipRect(0, 0, 50, 100)
        b.rectangle(0, 0, 100, 50)
        b.restoreDC(-1)
        b.rectangle(0, 60, 100, 100)
        let c = try render(b)
        #expect(c.matches(25, 25, 255, 0, 0) && c.isClear(75, 25))
        #expect(c.matches(75, 80, 255, 0, 0))   // clip gone after RESTOREDC
    }

    @Test func clipPath() throws {
        var b = redBrush()
        b.beginPath()
        b.ellipse(0, 0, 100, 100)
        b.endPath()
        b.selectClipPath(5)            // RGN_COPY
        b.rectangle(0, 0, 100, 100)
        let c = try render(b)
        #expect(c.matches(50, 50, 255, 0, 0) && c.isClear(3, 3))
    }

    @Test func textDrawsInk() throws {
        var b = EMFBuilder()
        b.font(1, height: -40, face: "Helvetica")
        b.select(1)
        b.textColor(colorref(0, 0, 0))
        b.bkMode(1)
        b.textAlign(0)                 // TA_TOP | TA_LEFT
        b.textOut(20, 20, "Ä")
        let c = try render(b)
        #expect(hasInk(c, CGRect(x: 20, y: 20, width: 40, height: 45)))
        #expect(!hasInk(c, CGRect(x: 0, y: 70, width: 100, height: 30)))
        #expect(!hasInk(c, CGRect(x: 0, y: 0, width: 100, height: 15)))
    }

    @Test func textIsUprightAndBaselineAligned() throws {
        // TA_BASELINE: ink of "T" lies above y = 60; its bar is at the top.
        var b = EMFBuilder()
        b.font(1, height: -40)
        b.select(1)
        b.bkMode(1)
        b.textAlign(24)
        b.textOut(10, 60, "T")
        let c = try render(b)
        #expect(hasInk(c, CGRect(x: 10, y: 30, width: 30, height: 30)))
        #expect(!hasInk(c, CGRect(x: 0, y: 63, width: 100, height: 37)))
        // Bar of the T: a wide row of ink near the top of the glyph.
        var widest = 0, widestY = 0
        for y in 25..<60 {
            var n = 0
            for x in 0..<100 where !c.isClear(x, y) { n += 1 }
            if n > widest { widest = n; widestY = y }
        }
        #expect(widestY < 40)
    }

    @Test func textDxPositionsGlyphs() throws {
        var b = EMFBuilder()
        b.font(1, height: -20)
        b.select(1)
        b.bkMode(1)
        b.textOut(0, 10, "II", dx: [80, 10])
        let c = try render(b)
        #expect(hasInk(c, CGRect(x: 0, y: 10, width: 15, height: 25)))
        #expect(!hasInk(c, CGRect(x: 20, y: 0, width: 55, height: 100)))
        #expect(hasInk(c, CGRect(x: 78, y: 10, width: 15, height: 25)))
    }

    @Test(arguments: [24, 32])
    func dibBottomUp(_ bpp: Int) throws {
        var b = EMFBuilder()
        let dib = packedDIB(bpp: bpp, rows: [[(255, 0, 0), (255, 0, 0)], [(0, 0, 255), (0, 0, 255)]])
        b.stretchDIBits(dest: (0, 0, 100, 100), dib: dib, width: 2, height: 2)
        let c = try render(b)
        #expect(c.matches(50, 10, 255, 0, 0))      // top row red
        #expect(c.matches(50, 90, 0, 0, 255))      // bottom row blue
    }

    @Test func dibTopDown() throws {
        var b = EMFBuilder()
        let dib = packedDIB(bpp: 24, rows: [[(255, 0, 0), (0, 255, 0)], [(0, 0, 255), (0, 0, 255)]], bottomUp: false)
        b.stretchDIBits(dest: (0, 0, 100, 100), dib: dib, width: 2, height: 2)
        let c = try render(b)
        #expect(c.matches(10, 10, 255, 0, 0) && c.matches(90, 10, 0, 255, 0))
        #expect(c.matches(50, 90, 0, 0, 255))
    }

    @Test func patInvertMaskIdiomPaintsFirstBrush() throws {
        // PATINVERT (yellow) → black fill under R2_MASKPEN → PATINVERT: yellow where the fill was.
        func patInvert(_ b: inout EMFBuilder) {
            b.rec(76) { p in
                p.i32(0).i32(0).i32(-1).i32(-1).i32(0).i32(0).i32(100).i32(100).u32(0x005A_0049).i32(0).i32(0)
                p.f32(1).f32(0).f32(0).f32(1).f32(0).f32(0).u32(0).u32(0).u32(0).u32(0).u32(0).u32(0)
            }
        }
        var b = EMFBuilder()
        b.brush(1, color: colorref(255, 255, 0))
        b.select(1)
        b.select(nullPen)
        patInvert(&b)
        b.rec(20) { $0.u32(9) }                 // SETROP2 R2_MASKPEN
        b.select(0x8000_0004)                   // BLACK_BRUSH
        b.rectangle(0, 0, 50, 100)
        b.rec(20) { $0.u32(13) }                // R2_COPYPEN
        b.select(1)
        patInvert(&b)
        let c = try render(b)
        #expect(c.matches(25, 50, 255, 255, 0))
        #expect(c.isClear(75, 50))
    }

    @Test func sizeZeroRecordStopsParsing() throws {
        var b = redBrush()
        b.polygon16([(0, 0), (40, 0), (40, 40), (0, 40)])
        b.rawRecord(type: 86, size: 0)
        b.polygon16([(60, 60), (100, 60), (100, 100), (60, 100)])
        let doc = try EMFDocument(data: b.build())
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(c.matches(20, 20, 255, 0, 0))
        #expect(c.isClear(80, 80))
    }

    @Test func overrunningRecordStopsParsing() throws {
        var b = redBrush()
        b.polygon16([(0, 0), (40, 0), (40, 40), (0, 40)])
        b.rawRecord(type: 86, size: 0x7FFF_FFF0, payload: Data(count: 16))
        let c = try render(b)
        #expect(c.matches(20, 20, 255, 0, 0))
    }

    @Test func emfPlusOnlyIsRecognised() throws {
        var b = EMFBuilder()
        b.emfPlusComment()
        let doc = try EMFDocument(data: b.build())
        #expect(doc.isEMFPlusOnly)
        var d = redBrush()
        d.emfPlusComment()
        d.rectangle(0, 0, 10, 10)
        #expect(try EMFDocument(data: d.build()).isEMFPlusOnly == false)
    }

    @Test func unknownRecordsAreSkipped() throws {
        var b = redBrush()
        b.rec(0x7777) { $0.u32(1).u32(2) }
        b.rectangle(0, 0, 100, 100)
        let doc = try EMFDocument(data: b.build())
        #expect(doc.unknownRecordTypes[0x7777] == 1)
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(c.matches(50, 50, 255, 0, 0))
    }

    @Test func fuzzNeverCrashes() throws {
        // Valid file with many record kinds, then seeded mutations and truncations.
        var b = redBrush()
        b.mapMode(8); b.windowExt(100, 100); b.viewportExt(100, 100)
        b.font(2, height: -12); b.select(2); b.textOut(5, 5, "Hallo", dx: [5, 5, 5, 5, 5])
        b.beginPath(); b.moveTo(1, 1); b.polyBezierTo16([(1, 2), (3, 4), (5, 6)]); b.endPath(); b.fillPath()
        b.stretchDIBits(dest: (0, 0, 10, 10), dib: packedDIB(bpp: 24, rows: [[(1, 2, 3)]]), width: 1, height: 1)
        b.saveDC(); b.intersectClipRect(0, 0, 5, 5); b.restoreDC(-1)
        b.worldTransform(CGAffineTransform(a: 1, b: 0.5, c: 0, d: 1, tx: 0, ty: 0))
        b.polygon16([(0, 0), (5, 0), (5, 5)])
        let base = [UInt8](b.build())
        var rng = SplitMix(seed: 0x5EED)
        let c = Canvas()
        for i in 0..<400 {
            var bytes = base
            let flips = 1 + Int(rng.next() % 12)
            for _ in 0..<flips where bytes.count > 108 {
                let at = 108 + Int(rng.next() % UInt64(bytes.count - 108))
                bytes[at] = UInt8(truncatingIfNeeded: rng.next())
            }
            if i % 7 == 0 { bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count)))) }
            if let doc = try? EMFDocument(data: Data(bytes)) {
                doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            var garbage = [UInt8](repeating: 0, count: Int(rng.next() % 600))
            for k in garbage.indices { garbage[k] = UInt8(truncatingIfNeeded: rng.next()) }
            _ = try? EMFDocument(data: Data(garbage))
            _ = try? WMFDocument(data: Data(garbage))
            _ = Metafile.decode(Data(garbage))
        }
    }
}

@Suite struct MetafileReviewTests {
    @Test func fullWidthBitfieldsMaskDoesNotTrap() throws {
        var b = EMFBuilder()
        b.stretchDIBits(dest: (0, 0, 100, 100), dib: bitfieldsDIB(pixel: 0xFFFF_FFFF, masks: (0xFFFF_FFFF, 0, 0)),
                        width: 1, height: 1)
        let c = try render(b)
        #expect(c.matches(50, 50, 255, 0, 0))
    }

    @Test func createPenWidthIsGeometric() throws {
        var b = EMFBuilder()
        b.pen(1, style: 0, width: 10, color: blueRef)
        b.select(1)
        b.moveTo(10, 50)
        b.lineTo(90, 50)
        let c = try render(b)
        #expect(c.matches(50, 46, 0, 0, 255) && c.matches(50, 53, 0, 0, 255))
        #expect(c.isClear(50, 40) && c.isClear(50, 60))
    }

    @Test func dibClaimingHugeDimensionsIsRejected() throws {
        // 6000 × 6000 × 24 bit claimed (144 MB decoded), one row of pixels present.
        var b = EMFBuilder()
        let hdr = LEBytes()
        hdr.u32(40).i32(6000).i32(6000).u16(1).u16(24).u32(0).u32(0).i32(0).i32(0).u32(0).u32(0)
        b.stretchDIBits(dest: (0, 0, 100, 100), dib: (hdr.data, Data(count: 18000)), width: 6000, height: 6000)
        let doc = try EMFDocument(data: b.build())
        let bitmaps = doc.program.records.filter { if case .bitmap = $0 { return true } else { return false } }
        #expect(bitmaps.isEmpty)
    }

    @Test func documentPixelBudgetLimitsDecodedBitmaps() throws {
        var b = EMFBuilder()
        let dib = packedDIB(bpp: 24, rows: Array(repeating: Array(repeating: (255, 0, 0), count: 10), count: 10))
        for _ in 0..<3 { b.stretchDIBits(dest: (0, 0, 100, 100), dib: dib, width: 10, height: 10) }
        let doc = try EMFDocument(data: b.build(), pixelBudget: 250)
        let bitmaps = doc.program.records.filter { if case .bitmap = $0 { return true } else { return false } }
        #expect(bitmaps.count == 2)
    }

    @Test func gzipWithHugeISIZEIsCheap() {
        // 20 bytes: gzip header, an empty final stored deflate block, CRC 0, ISIZE 256 MB.
        let bomb = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3, 0x03, 0x00, 0, 0, 0, 0, 0, 0, 0, 0x10])
        #expect(bomb.count == 20)
        #expect(Metafile.inflateCapacity(compressed: bomb.count, isize: 256 * 1024 * 1024) <= 20 * 1100 + 1024)
        #expect(Metafile.inflateCapacity(compressed: 10_000_000, isize: 1 << 31) <= Metafile.maxInflatedSize)
        #expect(Metafile.maxInflatedSize <= 64 * 1024 * 1024)
        #expect(Metafile.decode(bomb) == nil)
    }

    @Test func recordCountIsCapped() throws {
        var b = EMFBuilder()
        for _ in 0..<50 { b.saveDC() }
        let doc = try EMFDocument(data: b.build(), maxRecords: 10)
        #expect(doc.program.records.count <= 10)
    }
}

@Suite struct EmbeddedPDFTests {
    @Test func embeddedPDFIsDrawnWhenEMFPartDrawsNothing() throws {
        var b = EMFBuilder()
        b.embeddedPDF(leftHalfPDF(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), output: (0, 0, 100, 100))
        let c = try render(b)
        #expect(c.matches(25, 50, 255, 0, 0))
        #expect(c.isClear(75, 50))
    }

    @Test func embeddedPDFIsIgnoredWhenEMFPartDraws() throws {
        var b = redBrush()
        b.embeddedPDF(leftHalfPDF(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)), output: (0, 0, 100, 100))
        b.rectangle(50, 0, 100, 100)
        let c = try render(b)
        #expect(c.isClear(25, 50))
        #expect(c.matches(75, 50, 255, 0, 0))
    }
}

@Suite struct WMFTests {
    @Test func placeableBoundsInHundredthsOfMillimetre() throws {
        let w = WMFBuilder()   // 1000 units at 1000 units/inch = 1 inch = 2540
        let doc = try WMFDocument(data: w.build())
        #expect(doc.bounds == CGRect(x: 0, y: 0, width: 2540, height: 2540))
    }

    @Test func polygonFills() throws {
        var w = WMFBuilder()
        w.windowOrg(0, 0)
        w.windowExt(1000, 1000)
        w.brush(color: redRef)             // slot 0
        w.select(0)
        w.pen(style: 5, color: 0)          // PS_NULL, slot 1
        w.select(1)
        w.polygon([(100, 100), (600, 100), (600, 600), (100, 600)])
        let doc = try WMFDocument(data: w.build())
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(c.matches(30, 30, 255, 0, 0))
        #expect(c.isClear(80, 80) && c.isClear(5, 5))
    }

    @Test func objectTableReusesLowestFreeSlot() throws {
        var w = WMFBuilder()
        w.brush(color: blueRef)            // slot 0
        w.brush(color: colorref(0, 255, 0)) // slot 1
        w.delete(0)
        w.brush(color: redRef)             // reuses slot 0
        w.pen(style: 5, color: 0)          // slot 2
        w.select(2)
        w.select(0)
        w.rectangle(0, 0, 1000, 1000)
        let doc = try WMFDocument(data: w.build())
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(c.matches(50, 50, 255, 0, 0))
    }

    @Test func standardHeaderWithoutPlaceableUsesWindow() throws {
        var w = WMFBuilder()
        w.placeable = false
        w.windowOrg(0, 0)
        w.windowExt(200, 200)
        w.brush(color: redRef)
        w.select(0)
        w.rectangle(0, 0, 100, 100)
        let doc = try WMFDocument(data: w.build())
        #expect(doc.bounds.width > 0)
        let c = Canvas()
        doc.draw(in: c.ctx, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(c.matches(25, 25, 255, 0, 0) && c.isClear(75, 75))
    }
}

/// Deterministic PRNG for the fuzz test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
