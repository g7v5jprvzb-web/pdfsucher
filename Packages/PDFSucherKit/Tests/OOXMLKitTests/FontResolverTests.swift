import Testing
import Foundation
import CoreText
@testable import OOXMLKit

// Tests only rely on fonts that ship with macOS (Helvetica Neue, Georgia, Menlo, Times New Roman,
// Hiragino Sans). Calibri-specific checks are gated on isInstalled("Calibri").

private let fictional = "TeleGrotesk Next Fictional"
private let serifFamilies: Set<String> = ["georgia", "times new roman", "times", "cambria", "garamond", "palatino"]

private func family(_ f: CTFont) -> String { CTFontCopyFamilyName(f) as String }
private func traits(_ f: CTFont) -> CTFontSymbolicTraits { CTFontGetSymbolicTraits(f) }
private func styleClass(_ f: CTFont) -> UInt32 {
    traits(f).rawValue & CTFontSymbolicTraits.classMaskTrait.rawValue
}
private let serifClasses: [UInt32] = ([.oldStyleSerifsClass, .transitionalSerifsClass,
    .modernSerifsClass, .clarendonSerifsClass, .slabSerifsClass, .freeformSerifsClass] as [CTFontStylisticClass]).map(\.rawValue)

/// The look-alike table (`.similar`); `.powerPoint` (the default) is tested in PowerPointSubstitutionTests.
@Suite struct FontResolverTests {
    let r = FontResolver(theme: nil, substitution: .similar)

    @Test func installedFamilyIsUsedCaseInsensitively() {
        #expect(r.isInstalled("Helvetica Neue"))
        #expect(r.isInstalled("helvetica neue"))
        #expect(!r.isInstalled(fictional))
        #expect(family(r.font(typeface: "georgia", size: 12, bold: false, italic: false)) == "Georgia")
        #expect(r.resolvedFamily("Menlo") == "Menlo")
    }

    @Test func sizeIsApplied() {
        #expect(CTFontGetSize(r.font(typeface: "Menlo", size: 17.5, bold: false, italic: false)) == 17.5)
    }

    @Test func latoNeverGetsASerifFamily() {
        for name in ["Lato", "Lato Black", "Lato Light", "Lato Medium", fictional, "Open Sans", "Segoe UI",
                     "Aptos", "Tahoma", "HP Simplified", "TeleNeo", "TeleGrotesk Next"] {
            let f = r.font(typeface: name, size: 14, bold: false, italic: false)
            #expect(!serifFamilies.contains(family(f).lowercased()), "\(name) -> \(family(f))")
            #expect(!serifClasses.contains(styleClass(f)), "\(name) -> class \(styleClass(f))")
            #expect(!serifFamilies.contains(r.resolvedFamily(name).lowercased()))
        }
    }

    /// Face names with a "regular" style word ("Avenir Book", "Avenir Heavy") use the installed family; "Book"
    /// must not classify them as serif.
    @Test(.enabled(if: FontResolver(theme: nil).isInstalled("Avenir"))) func regularStyleWordsKeepTheInstalledFamily() {
        #expect(r.resolvedFamily("Avenir Book") == "Avenir")
        #expect(r.resolvedFamily("Avenir Heavy") == "Avenir")
        #expect(r.resolvedFamily("Avenir Regular") == "Avenir")
        #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Fictional Roman")))
    }

    @Test func unknownSansGoesToHelveticaNeueIfNotInstalled() {
        #expect(r.resolvedFamily(fictional) == "Helvetica Neue")
        #expect(r.resolvedFamily("Sans Serif Fictional") == "Helvetica Neue")
        #expect(r.resolvedFamily("Fictional Sans") == "Helvetica Neue")
    }

    @Test func patternClassification() {
        #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Fictional Garamond Pro")))
        #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Fictional Serif")))
        #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Fictional Roman")))
        #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Fictional Palatino")))
        #expect(r.resolvedFamily("Fictional Mono") == "Menlo")
        #expect(r.resolvedFamily("Fictional Code") == "Menlo")
        #expect(r.resolvedFamily("Fictional Courier") == "Menlo")
    }

    @Test func substitutionTable() {
        // Names that are certainly not installed on a Mac are checked through resolvedFamily; for names
        // that may be installed, only assert when they are not.
        if !r.isInstalled("Consolas") { #expect(r.resolvedFamily("Consolas") == "Menlo") }
        if !r.isInstalled("Cambria") { #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Cambria"))) }
        if !r.isInstalled("Constantia") { #expect(["Georgia", "Times New Roman"].contains(r.resolvedFamily("Constantia"))) }
        if !r.isInstalled("Courier New") { #expect(r.resolvedFamily("Courier New") == "Menlo") }
        if !r.isInstalled("Lato") { #expect(r.resolvedFamily("Lato") == "Helvetica Neue") }
        if !r.isInstalled("Calibri") { #expect(r.resolvedFamily("Calibri") == "Helvetica Neue") }
        if !r.isInstalled("Aptos") { #expect(r.resolvedFamily("Aptos") == "Helvetica Neue") }
        if !r.isInstalled("Verdana") { #expect(r.resolvedFamily("Verdana") == "Helvetica Neue") }
        if !r.isInstalled("Georgia") { #expect(r.resolvedFamily("Georgia") == "Times New Roman") }
        if !r.isInstalled("MS PGothic") { #expect(r.resolvedFamily("MS PGothic") == "Hiragino Sans") }
        if !r.isInstalled("ＭＳ Ｐゴシック") { #expect(r.resolvedFamily("ＭＳ Ｐゴシック") == "Hiragino Sans") }
        if !r.isInstalled("MS Gothic") { #expect(r.resolvedFamily("MS Gothic") == "Hiragino Sans") }
        if !r.isInstalled("Wingdings") { #expect(r.resolvedFamily("Wingdings") == "Helvetica Neue") }
    }

    @Test func calibriWhenInstalled() {
        guard r.isInstalled("Calibri") else { return }
        #expect(r.resolvedFamily("Calibri") == "Calibri")
        #expect(family(r.font(typeface: "Calibri", size: 12, bold: false, italic: false)) == "Calibri")
    }

    @Test func themeShorthands() {
        var theme = Theme.fallback
        theme.majorLatin = "Georgia"; theme.minorLatin = "Menlo"
        theme.majorEA = "Hiragino Sans"; theme.minorEA = "Times New Roman"
        let t = FontResolver(theme: theme, substitution: .similar)
        #expect(t.resolvedFamily("+mn-lt") == "Menlo")
        #expect(t.resolvedFamily("+mj-lt") == "Georgia")
        #expect(t.resolvedFamily("+mj-ea") == "Hiragino Sans")
        #expect(t.resolvedFamily("+mn-ea") == "Times New Roman")
        #expect(t.resolvedFamily(nil) == "Menlo")
        #expect(t.resolvedFamily("") == "Menlo")
        #expect(t.resolvedFamily("+mn-lt", script: .eastAsian) == "Menlo")
        #expect(family(t.font(typeface: "+mn-lt", size: 10, bold: false, italic: false)) == "Menlo")
        #expect(t.resolvedFamily(nil, script: .eastAsian) == "Times New Roman")
        #expect(!t.resolvedFamily("+mn-cs", script: .complexScript).isEmpty)
    }

    @Test func noThemeUsesCalibriDefaults() {
        let expectedMinor = r.isInstalled("Calibri") ? "Calibri" : "Helvetica Neue"
        // "Calibri Light" is a style of the family "Calibri" in macOS' font list, so it resolves to
        // Calibri + light weight when Office is installed.
        let expectedMajor = r.isInstalled("Calibri Light") ? "Calibri Light" : expectedMinor
        #expect(r.resolvedFamily(nil) == expectedMinor)
        #expect(r.resolvedFamily("+mn-lt") == expectedMinor)
        #expect(r.resolvedFamily("+mj-lt") == expectedMajor)
    }

    @Test func eastAsianDefaultWithoutThemeIsHiragino() {
        #expect(r.resolvedFamily(nil, script: .eastAsian) == "Hiragino Sans")
        #expect(r.resolvedFamily("+mn-ea", script: .eastAsian) == "Hiragino Sans")
    }

    @Test func boldAndItalic() {
        let regular = r.font(typeface: "Helvetica Neue", size: 12, bold: false, italic: false)
        let bold = r.font(typeface: "Helvetica Neue", size: 12, bold: true, italic: false)
        let italic = r.font(typeface: "Helvetica Neue", size: 12, bold: false, italic: true)
        let both = r.font(typeface: "Helvetica Neue", size: 12, bold: true, italic: true)
        #expect(!traits(regular).contains(.traitBold) && !traits(regular).contains(.traitItalic))
        #expect(traits(bold).contains(.traitBold))
        #expect(traits(italic).contains(.traitItalic))
        #expect(traits(both).contains(.traitBold) && traits(both).contains(.traitItalic))
        #expect(family(bold) == "Helvetica Neue")
    }

    @Test func boldAndItalicOnSubstitutes() {
        let f = r.font(typeface: fictional, size: 12, bold: true, italic: true)
        #expect(family(f) == "Helvetica Neue")
        #expect(traits(f).contains(.traitBold) && traits(f).contains(.traitItalic))
    }

    @Test func missingBoldFaceKeepsRegular() {
        // Family without a bold face: no synthesis, regular face is kept (and nothing crashes).
        // "Apple Symbols" ships with macOS with a single face.
        guard r.isInstalled("Apple Symbols") else { return }
        let f = r.font(typeface: "Apple Symbols", size: 12, bold: true, italic: false)
        #expect(family(f) == "Apple Symbols")
        #expect(!traits(f).contains(.traitBold))
        #expect(CTFontGetSize(f) == 12)
    }

    @Test func weightWordsOnSubstitutes() {
        func weight(_ f: CTFont) -> Double {
            let t = CTFontCopyTraits(f) as NSDictionary
            return (t[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        }
        func width(_ f: CTFont) -> Double {
            let t = CTFontCopyTraits(f) as NSDictionary
            return (t[kCTFontWidthTrait as String] as? NSNumber)?.doubleValue ?? 0
        }
        let regular = r.font(typeface: "\(fictional)", size: 12, bold: false, italic: false)
        let black = r.font(typeface: "\(fictional) Black", size: 12, bold: false, italic: false)
        let light = r.font(typeface: "\(fictional) Light", size: 12, bold: false, italic: false)
        let cond = r.font(typeface: "\(fictional) Condensed", size: 12, bold: false, italic: false)
        #expect(family(black) == "Helvetica Neue")
        #expect(weight(black) > weight(regular))
        #expect(weight(light) < weight(regular))
        // Width is best effort: Helvetica Neue only ships condensed faces in bold/black, so a bare
        // "Condensed" keeps the regular width; with a weight word it picks the condensed face.
        let condBlack = r.font(typeface: "\(fictional) Condensed Black", size: 12, bold: false, italic: false)
        #expect(width(cond) <= width(regular))
        #expect(width(condBlack) < width(regular))
        #expect(r.resolvedFamily("\(fictional) Black") == "Helvetica Neue")
    }

    @Test func cacheReturnsIdenticalObject() {
        let a = r.font(typeface: fictional, size: 12, bold: true, italic: false)
        let b = r.font(typeface: fictional, size: 12, bold: true, italic: false)
        #expect(a === b)
        let c = r.font(typeface: "Fictional Other Sans", size: 12, bold: true, italic: false)
        #expect(a === c) // same resolved family, same traits -> same object
        let d = r.font(typeface: fictional, size: 13, bold: true, italic: false)
        #expect(a !== d)
        let e = r.font(typeface: fictional, size: 12, bold: false, italic: false)
        #expect(a !== e)
    }

    @Test func threadSafety() async {
        let resolver = FontResolver(theme: nil)
        let names: [String?] = [nil, "Helvetica Neue", "Georgia", "Menlo", fictional, "Lato", "+mn-lt", "Consolas"]
        let families = await withTaskGroup(of: String.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let f = resolver.font(typeface: names[i % names.count], size: CGFloat(8 + i % 5),
                                          bold: i % 2 == 0, italic: i % 3 == 0)
                    return CTFontCopyFamilyName(f) as String
                }
            }
            var out: [String] = []
            for await x in group { out.append(x) }
            return out
        }
        #expect(families.count == 200)
        #expect(families.allSatisfy { !$0.isEmpty })
        // Same key from many tasks -> identical object.
        let ids = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    ObjectIdentifier(resolver.font(typeface: "Menlo", size: 11, bold: true, italic: true))
                }
            }
            var out: [ObjectIdentifier] = []
            for await x in group { out.append(x) }
            return out
        }
        #expect(ids.count == 200)
        #expect(Set(ids).count == 1)
    }

    // MARK: symbol mapping

    @Test func wingdingsMapping() {
        func m(_ s: String, _ face: String = "Wingdings") -> String { FontResolver.mapSymbolText(s, typeface: face).text }
        #expect(m("\u{F0A7}") == "\u{25AA}")
        #expect(m("\u{F0FC}") == "\u{2713}")
        #expect(m("\u{F0D8}") == "\u{27A2}")
        #expect(m("\u{A7}") == "\u{25AA}")
        #expect(m("\u{FC}") == "\u{2713}")
        #expect(m("\u{D8}") == "\u{27A2}")
        #expect(m("\u{F0A7}\u{F0FC}") == "\u{25AA}\u{2713}")
        #expect(FontResolver.mapSymbolText("\u{F0A7}", typeface: "wingdings").typeface == nil)
        // Arrows DF…E6 (glyph names barb2left … barb2se in the macOS Wingdings font).
        #expect(m("\u{F0E0}\u{F0DF}\u{F0E1}\u{F0E6}") == "→←↑↘")
        #expect(m("\u{F046}") == "\u{261E}")
        // White arrows EF…F4 (glyph names bleft, bright, bup, bdown, bleftright, bupdown); F3 is used as "⇔" in a deck.
        #expect(m("\u{F0EF}\u{F0F0}\u{F0F1}\u{F0F2}\u{F0F3}\u{F0F4}") == "\u{21E6}\u{21E8}\u{21E7}\u{21E9}\u{2B04}\u{21F3}")
        // Wingdings 2: "P" is the usual Office check mark; codes from the real glyph names.
        #expect(m("P", "Wingdings 2") == "\u{2713}")
        #expect(m("\u{F050}", "Wingdings 2") == "\u{2713}")
        #expect(m("\u{F04F}", "Wingdings 2") == "\u{2717}")
        #expect(m("\u{F052}", "Wingdings 2") == "\u{2611}")
        #expect(m("\u{F053}", "Wingdings 2") == "\u{2612}")
        #expect(m("\u{F0A3}", "Wingdings 2") == "\u{25A1}")
        #expect(m("\u{F075}", "Wingdings 3") == "\u{25BA}")
        #expect(m("\u{F074}", "Wingdings 3") == "\u{25C4}")
        #expect(m("\u{F070}", "Wingdings 3") == "\u{25B2}")
        #expect(m("\u{F071}", "Wingdings 3") == "\u{25BC}")
    }

    @Test func symbolMapping() {
        func m(_ s: String) -> String { FontResolver.mapSymbolText(s, typeface: "Symbol").text }
        #expect(m("\u{F0B7}") == "\u{2022}")
        #expect(m("\u{B7}") == "\u{2022}")
        #expect(m("a") == "\u{3B1}")
        #expect(m("\u{F061}") == "\u{3B1}")
        #expect(m("\u{F0AE}") == "\u{2192}")
        #expect(FontResolver.mapSymbolText("\u{F0B7}", typeface: "Symbol").typeface == nil)
    }

    @Test func nonSymbolTextIsUntouched() {
        let res = FontResolver.mapSymbolText("Hallo \u{F0A7}", typeface: "Calibri")
        #expect(res.text == "Hallo \u{F0A7}")
        #expect(res.typeface == nil)
    }

    @Test func unmappedSymbolCharsKeepFont() {
        let res = FontResolver.mapSymbolText("\u{F0FF}", typeface: "Wingdings")
        #expect(res.text == "\u{F0FF}")
        #expect(res.typeface == "Wingdings")
    }
}

@Suite struct LatinGothicNamesTests {
    @Test func latinGothicNamesAreNotCJK() {
        let r = FontResolver(theme: nil, substitution: .similar)
        for name in ["Trade Gothic Fictional", "News Gothic Fictional", "Bell Gothic Fictional"] {
            #expect(r.resolvedFamily(name) == "Helvetica Neue", "\(name)")
        }
        #expect(r.resolvedFamily("MS Gothic Fictional") == "Hiragino Sans")
        #expect(r.resolvedFamily("Yu Gothic Fictional") == "Hiragino Sans")
    }
}

/// `.powerPoint`: PowerPoint for Mac draws a missing font in Calibri (measured on its PDF exports,
/// docs/decisions.md); Office's own, CJK and symbol fonts keep the look-alike table.
@Suite struct PowerPointSubstitutionTests {
    let r = FontResolver(theme: nil)
    private var office: String { r.isInstalled("Calibri") ? "Calibri" : "Arial" }

    @Test func powerPointIsTheDefault() {
        #expect(r.substitution == .powerPoint)
        #expect(FontSubstitution.allCases == [.powerPoint, .similar])
        #expect(FontSubstitution(rawValue: "similar") == .similar)
    }

    @Test func missingFamilyGetsTheOfficeDefaultWithBoldAndItalic() {
        #expect(r.resolvedFamily(fictional) == office)
        #expect(family(r.font(typeface: fictional, size: 12, bold: false, italic: false)) == office)
        let bi = r.font(typeface: fictional, size: 12, bold: true, italic: true)
        #expect(family(bi) == office)
        #expect(traits(bi).contains(.traitBold))
        #expect(traits(bi).contains(.traitItalic))
        #expect(!traits(r.font(typeface: fictional, size: 12, bold: false, italic: false)).contains(.traitBold))
    }

    @Test func weightWordsAreNotAppliedToTheSubstitute() {
        let plain = r.font(typeface: fictional, size: 12, bold: false, italic: false)
        for name in ["Fictional Black", "Fictional ExtraBold", "Fictional Light", "Fictional Condensed"] {
            let f = r.font(typeface: name, size: 12, bold: false, italic: false)
            #expect(family(f) == office, "\(name)")
            #expect(CTFontCopyPostScriptName(f) as String == CTFontCopyPostScriptName(plain) as String, "\(name)")
        }
    }

    @Test func serifAndMonoNamesAreNotClassified() {
        for name in ["Fictional Garamond Pro", "Fictional Serif", "Fictional Mono", "Fictional Code"] {
            #expect(r.resolvedFamily(name) == office, "\(name)")
        }
    }

    @Test func installedFamiliesAndFacesStay() {
        #expect(r.resolvedFamily("Helvetica Neue") == "Helvetica Neue")
        #expect(r.resolvedFamily("georgia") == "Georgia")
        #expect(r.resolvedFamily("Menlo") == "Menlo")
        #expect(r.resolvedFamily("Helvetica Neue Medium") == "Helvetica Neue")
        let medium = r.font(typeface: "Helvetica Neue Medium", size: 12, bold: false, italic: false)
        #expect(CTFontCopyPostScriptName(medium) as String == "HelveticaNeue-Medium")
    }

    @Test func officeCJKAndSymbolFontsKeepTheTable() {
        let similar = FontResolver(theme: nil, substitution: .similar)
        for name in ["Lato", "Lato Black", "Aptos", "Cambria", "Consolas", "Candara", "MS PGothic", "ＭＳ Ｐゴシック",
                     "MS Mincho", "Wingdings", "Symbol"] {
            #expect(r.resolvedFamily(name) == similar.resolvedFamily(name), "\(name)")
        }
    }

    @Test func missingNamesInTheLookAlikeTableGetCalibriToo() {
        // D7's HP Simplified (not installed) is drawn in Calibri by PowerPoint; Latin "Gothic" names are no CJK.
        for name in ["HP Simplified", "Trade Gothic Fictional", "News Gothic Fictional", "TeleNeo Office Medium"]
        where !r.isInstalled(name) {
            #expect(r.resolvedFamily(name) == office, "\(name)")
        }
    }

    @Test func fontsOfficeShipsKeepTheTable() {
        // PowerPoint draws these in their own face (Office for Mac ships them), so the look-alike stays.
        let similar = FontResolver(theme: nil, substitution: .similar)
        for name in ["Garamond", "Book Antiqua", "Bookman Old Style", "Century Schoolbook", "Century Gothic",
                     "Franklin Gothic Book", "Gill Sans MT", "Rockwell", "News Gothic MT", "Lucida Console",
                     "Palatino Linotype", "Segoe UI", "Times New Roman", "Mangal"] {
            #expect(r.resolvedFamily(name) == similar.resolvedFamily(name), "\(name)")
        }
        if !r.isInstalled("Garamond") { #expect(serifFamilies.contains(r.resolvedFamily("Garamond").lowercased())) }
    }

    @Test func eastAsianAndComplexScriptRunsKeepTheTable() {
        // The measured rule covers Latin runs only.
        let similar = FontResolver(theme: nil, substitution: .similar)
        for script in [Script.eastAsian, .complexScript] {
            #expect(r.resolvedFamily("Vrinda Fictional", script: script)
                    == similar.resolvedFamily("Vrinda Fictional", script: script))
        }
    }

    @Test func themeFontsResolveFirst() {
        var theme = Theme.fallback
        theme.majorLatin = fictional; theme.minorLatin = "Menlo"
        let t = FontResolver(theme: theme)
        #expect(t.resolvedFamily("+mn-lt") == "Menlo")
        #expect(t.resolvedFamily("+mj-lt") == office)
    }
}
