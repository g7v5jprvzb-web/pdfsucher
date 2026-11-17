import Testing
import SearchKit

@Suite("FoldedText")
struct FoldedTextTests {
    @Test func foldsCaseAndDiacritics() {
        #expect(FoldedText("MÜLLER Café").folded == "muller cafe")
    }

    @Test func mapsRangesThroughExpansions() {
        let text = "Straße ﬁnden"
        let f = FoldedText(text)
        #expect(f.folded == "strasse finden")
        // "finden" in folded text
        let r = f.folded.range(of: "finden")!
        #expect(String(text[f.originalRange(of: r)]) == "ﬁnden")
        // a range inside an expansion widens to the whole original character
        let s = f.folded.range(of: "ss")!
        #expect(String(text[f.originalRange(of: s)]) == "ß")
        let partial = f.folded.index(after: s.lowerBound)..<s.upperBound
        #expect(String(text[f.originalRange(of: partial)]) == "ß")
    }

    @Test func emptyRangeMapsToEmptyRange() {
        let text = "abc"
        let f = FoldedText(text)
        let end = f.folded.endIndex
        #expect(f.originalRange(of: end..<end) == text.endIndex..<text.endIndex)
    }

    @Test func emptyText() {
        let f = FoldedText("")
        #expect(f.folded == "")
    }
}

@Suite("PageMatcher")
struct PageMatcherTests {
    private func strings(_ terms: [QueryTerm], _ text: String) -> [String]? {
        PageMatcher(ParsedQuery(terms: terms)).ranges(in: text)?.map { String(text[$0]) }
    }

    @Test func wordDoesNotMatchCompound() {
        #expect(strings([.word("vertrag")], "Vertragsende") == nil)
        #expect(strings([.word("vertrag")], "Der Vertrag.") == ["Vertrag"])
        #expect(strings([.word("vertrag")], "Mietvertrag") == nil)
    }

    @Test func prefixHighlightsWholeWord() {
        #expect(strings([.prefix("vertrag")], "Vertragsende") == ["Vertragsende"])
        #expect(strings([.prefix("vertrag")], "Vertrag") == ["Vertrag"])
        #expect(strings([.prefix("vertrag")], "Mietvertrag") == nil)
    }

    @Test func suffixRejectsMiddle() {
        #expect(strings([.suffix("ende")], "Endergebnis") == nil)
        #expect(strings([.suffix("ende")], "Vertragsende") == ["Vertragsende"])
        #expect(strings([.suffix("ende")], "Ende.") == ["Ende"])
    }

    @Test func infixHighlightsOnlySequence() {
        #expect(strings([.infix("trag")], "Auftrag") == ["trag"])
        #expect(strings([.infix("trag")], "Tragweite, Vertragsende") == ["Trag", "trag"])
    }

    @Test func allTermsRequired() {
        #expect(strings([.word("a1"), .word("b2")], "a1 x") == nil)
        #expect(strings([.word("a1"), .word("b2")], "b2 und a1") == ["b2", "a1"])
    }

    @Test func countsMultiplePerPage() {
        let m = PageMatcher(ParsedQuery(terms: [.word("ende")]))
        #expect(m.matchCount(in: "Ende gut, Ende schlecht") == 2)
        #expect(m.matchCount(in: "nichts") == nil)
    }

    @Test func diacriticInsensitive() {
        #expect(PageMatcher(ParsedQuery(terms: [.word("muller")])).matchCount(in: "MÜLLER") == 1)
        // decomposed ü (u + combining diaeresis)
        #expect(PageMatcher(ParsedQuery(terms: [.word("muller")])).matchCount(in: "Mu\u{308}ller") == 1)
    }

    @Test func rangesMapBackThroughLengthChangingFolds() {
        let text = "Straße ﬁnden Ende"
        let r = PageMatcher(ParsedQuery(terms: [.word("ende")])).ranges(in: text)
        #expect(r?.count == 1)
        #expect(r.map { String(text[$0[0]]) } == "Ende")
        #expect(strings([.word("finden")], text) == ["ﬁnden"])
        #expect(strings([.word("strasse")], text) == ["Straße"])
    }

    @Test func phraseMatchesWordSequence() {
        #expect(strings([.phrase(["neuer", "vertrag"])], "Der neuer  Vertrag gilt") == ["neuer  Vertrag"])
        #expect(strings([.phrase(["neuer", "vertrag"])], "neuer\nVertrag") == ["neuer\nVertrag"])
        #expect(strings([.phrase(["neuer", "vertrag"])], "Vertrag neuer") == nil)
        #expect(strings([.phrase(["neuer", "vertrag"])], "erneuer Vertrags") == nil)
    }

    @Test func phraseMatchesAcrossPunctuationLikeTheIndex() {
        // "E-Mail" is parsed as phrase ["e","mail"]; the index tokenizes it the same way.
        #expect(strings([.phrase(["e", "mail"])], "Ihre E-Mail an") == ["E-Mail"])
    }

    @Test func rangesAreSortedAcrossTerms() {
        let text = "b a b a"
        let r = PageMatcher(ParsedQuery(terms: [.word("a"), .word("b")])).ranges(in: text)!
        #expect(r.map(\.lowerBound) == r.map(\.lowerBound).sorted())
        #expect(r.count == 4)
    }

    @Test func overlappingTermsAreMergedAndNotDoubleCounted() {
        // "trag" and "vertrag*" both hit "Vertrag": count it once, highlight it once.
        let text = "Vertrag"
        let r = PageMatcher(ParsedQuery(terms: [.infix("trag"), .prefix("vertrag")])).ranges(in: text)!
        #expect(r.map { String(text[$0]) } == ["Vertrag"])
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(PageMatcher(ParsedQuery(terms: [])).ranges(in: "Vertrag") == nil)
    }

    @Test func regexMetacharactersInTermsAreLiteral() {
        // Parser never produces these, but PageMatcher is public.
        #expect(strings([.infix("a.c")], "abc") == nil)
        #expect(strings([.infix("a.c")], "a.c") == ["a.c"])
    }
}

@Suite("PageMatcher review cases")
struct PageMatcherReviewTests {
    private func strings(_ terms: [QueryTerm], _ text: String) -> [String]? {
        PageMatcher(ParsedQuery(terms: terms)).ranges(in: text)?.map { String(text[$0]) }
    }

    @Test func suffixIsLinearOnLongRunsOfLetters() {
        let text = String(repeating: "a", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(PageMatcher(ParsedQuery(terms: [.suffix("b")])).ranges(in: text) == nil)
        }
        #expect(elapsed < .milliseconds(300), "took \(elapsed)")
    }

    @Test func foldingAThousandPagesIsFast() {
        let page = String(repeating: "Der Vertrag über die Lieferung endet am 31.12.2024. ", count: 60)  // ~3 KB
        let matcher = PageMatcher(ParsedQuery(terms: [.word("vertrag"), .infix("lief")]))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 { _ = matcher.matchCount(in: page) }
        }
        // debug-build bound: catches order-of-magnitude regressions only (release: SearchBenchmark)
        #if targetEnvironment(simulator) && DEBUG
        // iPad: the debug build in the iOS simulator takes ~5.4 s here (release: ~0.16 s, measured 2026-11-17).
        #expect(elapsed < .seconds(15), "took \(elapsed)")
        #else
        #expect(elapsed < .seconds(5), "took \(elapsed)")
        #endif
    }

    @Test func aeAndOtherFolds() {
        #expect(strings([.word("aether")], "Æther") == nil)  // Æ folds to æ, not "ae"
        #expect(strings([.word("æther")], "ÆTHER") == ["ÆTHER"])
    }

    @Test func crlfAndEmojiKeepRanges() {
        let text = "neuer\r\nVertrag 👨‍👩‍👧 Auftrag"
        #expect(strings([.phrase(["neuer", "vertrag"])], text) == ["neuer\r\nVertrag"])
        #expect(strings([.infix("trag")], text) == ["trag", "trag"])
    }

    @Test func occurrencesOfOneTermAreCountedWithoutOverlap() {
        #expect(strings([.infix("aa")], "aaaa") == ["aa", "aa"])
        #expect(PageMatcher(ParsedQuery(terms: [.infix("aa")])).matchCount(in: "aaaaa") == 2)
    }

    @Test func partialHitInsideSharpSWidensToTheCharacter() {
        #expect(strings([.infix("sse")], "Straße") == ["ße"])
        #expect(strings([.suffix("se")], "Straße") == ["Straße"])
    }

    @Test func mixedAsciiAndNonAscii() {
        let text = "Ärger mit Müller-Lüdenscheidt, ﬁnal: Straße"
        #expect(strings([.word("muller")], text) == ["Müller"])
        #expect(strings([.prefix("luden")], text) == ["Lüdenscheidt"])
        #expect(strings([.word("final")], text) == ["ﬁnal"])
        #expect(strings([.word("arger")], text) == ["Ärger"])
        #expect(strings([.word("strasse")], text) == ["Straße"])
    }
}
