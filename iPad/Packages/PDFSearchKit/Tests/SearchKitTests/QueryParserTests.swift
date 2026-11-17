import Testing
import SearchKit

@Suite("QueryParser")
struct QueryParserTests {
    private func parse(_ s: String, partial: Bool = false) -> [QueryTerm] {
        QueryParser.parse(s, partialWords: partial).terms
    }

    @Test func plainWord() {
        #expect(parse("Vertrag") == [.word("vertrag")])
    }

    @Test func plainWordBecomesInfixWithPartialWords() {
        #expect(parse("Vertrag", partial: true) == [.infix("vertrag")])
    }

    @Test func wildcards() {
        #expect(parse("Vertrag*") == [.prefix("vertrag")])
        #expect(parse("*Ende") == [.suffix("ende")])
        #expect(parse("*trag*") == [.infix("trag")])
        #expect(parse("*trag*", partial: true) == [.infix("trag")])
        #expect(parse("Vertrag*", partial: true) == [.prefix("vertrag")])
        #expect(parse("**trag**") == [.infix("trag")])
    }

    @Test func diacriticsAndCaseAreFolded() {
        #expect(parse("Müller") == [.word("muller")])
        #expect(parse("STRASSE Straße") == [.word("strasse"), .word("strasse")])
    }

    @Test func multipleWordsAndPhrase() {
        #expect(parse("\"neuer Vertrag\" Ende") == [.phrase(["neuer", "vertrag"]), .word("ende")])
        #expect(parse("Ende   gut\tund") == [.word("ende"), .word("gut"), .word("und")])
    }

    @Test func phraseIsNotAffectedByPartialWords() {
        #expect(parse("\"neuer Vertrag\"", partial: true) == [.phrase(["neuer", "vertrag"])])
    }

    @Test func starsInsidePhraseAreStripped() {
        #expect(parse("\"neu* *Vertrag\"") == [.phrase(["neu", "vertrag"])])
    }

    @Test func parserNeutralizesFTSSyntax() {
        #expect(parse("(a) -b NEAR \"c") == [.word("a"), .word("b"), .word("near"), .phrase(["c"])])
        #expect(parse("*").isEmpty)
        #expect(parse("***").isEmpty)
        #expect(parse("   ").isEmpty)
        #expect(parse("").isEmpty)
        #expect(parse("\"\"").isEmpty)
        #expect(parse("\" ( ) \"").isEmpty)
        #expect(parse("AND OR NOT") == [.word("and"), .word("or"), .word("not")])
        #expect(parse("a^b:c{d}") == [.phrase(["a", "b", "c", "d"])])
        #expect(QueryParser.parse("*", partialWords: false).isEmpty)
    }

    @Test func unterminatedQuoteIsPhraseToEnd() {
        #expect(parse("Ende \"neuer Vertrag") == [.word("ende"), .phrase(["neuer", "vertrag"])])
    }

    @Test func hyphenatedTokenBecomesPhrase() {
        #expect(parse("E-Mail") == [.phrase(["e", "mail"])])
    }

    @Test func typographicQuotesStartPhrases() {
        #expect(parse("„neuer Vertrag“ Ende") == [.phrase(["neuer", "vertrag"]), .word("ende")])
        #expect(parse("“neuer Vertrag”") == [.phrase(["neuer", "vertrag"])])
        #expect(parse("»neuer Vertrag«") == [.phrase(["neuer", "vertrag"])])
        #expect(parse("\"").isEmpty)
    }

    @Test func innerStarIsAWildcardInsideTheWord() {
        #expect(parse("Ver*trag") == [.prefix("ver"), .suffix("trag")])
        #expect(parse("*a*b*") == [.infix("a"), .infix("b")])
    }

    @Test func partialWordsAppliesToHyphenatedTokensToo() {
        #expect(parse("Kfz-Vers", partial: true) == [.suffix("kfz"), .prefix("vers")])
        #expect(parse("a-b-c", partial: true) == [.suffix("a"), .word("b"), .prefix("c")])
    }

    @Test func wildcardsSurviveSurroundingPunctuation() {
        #expect(parse("Vertrag*,") == [.prefix("vertrag")])
        #expect(parse("(*trag*)") == [.infix("trag")])
        #expect(parse("(Vertrag)") == [.word("vertrag")])
    }

    @Test func markOnlyRunsAndOtherScripts() {
        #expect(parse("\u{301}").isEmpty)
        #expect(parse("東京") == [.word("東京")])
    }

    @Test func hyphenatedTokenWithWildcardsSplitsIntoTerms() {
        #expect(parse("Kfz-Vers*") == [.word("kfz"), .prefix("vers")])
        #expect(parse("*fz-Vers*") == [.suffix("fz"), .prefix("vers")])
        #expect(parse("*a-b-c") == [.suffix("a"), .word("b"), .word("c")])
    }

    @Test func digitsAreKept() {
        #expect(parse("2024") == [.word("2024")])
        #expect(parse("§12") == [.word("12")])
    }
}
