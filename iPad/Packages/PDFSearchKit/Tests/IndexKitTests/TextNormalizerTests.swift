import Testing
import Foundation
import IndexKit

@Suite("TextNormalizer")
struct TextNormalizerTests {
    private func n(_ s: String) -> String { TextNormalizer.normalize(s) }

    @Test func joinsHyphenatedLineBreak() {
        #expect(n("Ver-\ntrag") == "Vertrag")
        #expect(n("Nord-\nSüd") == "Nord-Süd")
    }

    @Test func joinsAcrossCRLFAndSurroundingSpaces() {
        #expect(n("Ver- \r\n  trag endet") == "Vertrag endet")
        #expect(n("Ver-\rtrag") == "Vertrag")
        #expect(n("Ver-\n\u{00FC}ber") == "Ver\u{00FC}ber") // lowercase non-ASCII
    }

    @Test func keepsHyphenBeforeDigitsAndAtEnd() {
        #expect(n("Seite 3-\n4") == "Seite 3- 4")
        #expect(n("Ende-\n") == "Ende-")
        #expect(n("Ende-") == "Ende-")
    }

    @Test func keepsHyphenWithoutLineBreak() {
        #expect(n("Nord-Süd E-Mail") == "Nord-Süd E-Mail")
        #expect(n("ab - cd") == "ab - cd")
    }

    @Test func keepsSuspendedHyphenBeforeConjunction() {
        #expect(n("Kranken-\nund Pflegeversicherung") == "Kranken- und Pflegeversicherung")
        #expect(n("Vor-\noder Nachteile") == "Vor- oder Nachteile")
        #expect(n("Ein-\nbzw. Ausgang") == "Ein- bzw. Ausgang")
        #expect(n("Ver-\nunden") == "Verunden") // only whole conjunctions
    }

    @Test func joinsOnlyAfterALetter() {
        #expect(n("3-\nfach") == "3- fach")
        #expect(n("100,-\nzzgl.") == "100,- zzgl.")
        #expect(n("Rabatt -\nSumme") == "Rabatt - Summe")
        #expect(n("Rabatt -\nsumme") == "Rabatt - summe")
    }

    @Test func paragraphBreakIsNotJoined() {
        #expect(n("Ver-\n\n\nUnd") == "Ver- Und")
        #expect(n("Ver-\n\ntrag") == "Ver- trag")
        #expect(n("Ver-\r\ntrag") == "Vertrag") // CRLF is one break
    }

    @Test func otherDashesAreNotHyphenation() {
        #expect(n("Ver\u{2010}\ntrag") == "Vertrag")       // U+2010 hyphen joins
        #expect(n("1990\u{2013}\n2000") == "1990\u{2013} 2000") // en dash stays, break is a space
        #expect(n("Ver\u{2011}\ntrag") == "Ver\u{2011} trag")   // non-breaking hyphen
    }

    @Test func dropsInvisibleFormatCharacters() {
        #expect(n("Ver\u{200B}trag\u{FEFF}") == "Vertrag")
        #expect(n("a\u{0000}b\u{0007}c") == "a b c")
        #expect(n("👨\u{200D}👩\u{200D}👧") == "👨\u{200D}👩\u{200D}👧") // ZWJ kept
    }

    @Test func privateUseCharactersBecomeSpaces() {
        // Word bullet (Symbol font) and other PUA glyphs must not glue onto the next word.
        #expect(n("\u{F0B7}Vertrag") == "Vertrag")
        #expect(n("a\u{F0B7}b \u{E000}c") == "a b c")
        #expect(n("x\u{F0000}y") == "x y") // supplementary PUA
    }

    @Test func softHyphenIsRemoved() {
        #expect(n("Ver\u{00AD}trag") == "Vertrag")
        #expect(n("Ver\u{00AD}\nTrag") == "VerTrag")
    }

    @Test func expandsLigatures() {
        #expect(n("ﬁnden ﬂach") == "finden flach")
        #expect(n("ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ") == "ff fi fl ffi ffl st st")
        #expect(n("Ver-\nﬁnden") == "Verfinden")
    }

    @Test func collapsesWhitespace() {
        #expect(n("a \n\t b") == "a b")
        #expect(n("  a\u{00A0}\u{2028}b  ") == "a b")
        #expect(n("") == "")
        #expect(n(" \n ") == "")
    }

    @Test func resultIsNFC() {
        let decomposed = "Mu\u{0308}ller"
        let result = n(decomposed)
        #expect(result.unicodeScalars.map(\.value) == "M\u{00FC}ller".unicodeScalars.map(\.value))
    }

    @Test func leavesOtherCharactersAlone() {
        #expect(n("Straße ² ½ Æ") == "Straße ² ½ Æ")
    }
}
