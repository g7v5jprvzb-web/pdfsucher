import Testing
import Foundation
import OutputKit

@Suite("DefaultFileName")
struct DefaultFileNameTests {
    var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }
    var date: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10))! }

    @Test func fileNameFormat() {
        #expect(DefaultFileName.make(searchTerm: "Vertrag", date: date, calendar: calendar)
                == "Auswahl_Vertrag_2026-11-12.pdf")
    }

    @Test func fileNameSanitizes() {
        #expect(DefaultFileName.make(searchTerm: "a/b:c*", date: date, calendar: calendar)
                == "Auswahl_a-b-c_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: #"x\?"<>|y"#, date: date, calendar: calendar)
                == "Auswahl_x-y_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "  Kündigung  ", date: date, calendar: calendar)
                == "Auswahl_Kündigung_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "zeile\neins", date: date, calendar: calendar)
                == "Auswahl_zeile-eins_2026-11-12.pdf")
    }

    @Test func otherControlCharactersBecomeDashes() {
        #expect(DefaultFileName.make(searchTerm: "a\tb\u{0}c", date: date, calendar: calendar)
                == "Auswahl_a-b-c_2026-11-12.pdf")
    }

    @Test func invisibleFormatCharactersAreDroppedWithoutLosingLetters() {
        // Soft hyphen (common in text copied from PDFs) and bidi overrides vanish; letters stay.
        #expect(DefaultFileName.make(searchTerm: "Ver\u{AD}trag", date: date, calendar: calendar)
                == "Auswahl_Vertrag_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "abc\u{202E}fdp.exe", date: date, calendar: calendar)
                == "Auswahl_abcfdp.exe_2026-11-12.pdf")
        // Joiners are part of the writing system and of emoji, so they are kept.
        #expect(DefaultFileName.make(searchTerm: "می\u{200C}خواهم", date: date, calendar: calendar)
                == "Auswahl_می\u{200C}خواهم_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "👨‍👩‍👧", date: date, calendar: calendar)
                == "Auswahl_👨‍👩‍👧_2026-11-12.pdf")
        // Subdivision flags are built from tag characters (also category "format").
        let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        #expect(DefaultFileName.make(searchTerm: scotland, date: date, calendar: calendar)
                == "Auswahl_\(scotland)_2026-11-12.pdf")
    }

    @Test func emptyTermOmitsSegment() {
        #expect(DefaultFileName.make(searchTerm: "", date: date, calendar: calendar) == "Auswahl_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: " *** ", date: date, calendar: calendar) == "Auswahl_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "\u{200D}\u{AD} ", date: date, calendar: calendar) == "Auswahl_2026-11-12.pdf")
    }

    @Test func dateUsesCalendarTimeZone() {
        // 23:30 UTC on Nov 11 is already Nov 12 in Berlin.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let late = utc.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23, minute: 30))!
        #expect(DefaultFileName.make(searchTerm: "x", date: late, calendar: calendar) == "Auswahl_x_2026-11-12.pdf")
        #expect(DefaultFileName.make(searchTerm: "x", date: late, calendar: utc) == "Auswahl_x_2026-11-11.pdf")
    }

    @Test func dateIsGregorianEvenForOtherCalendars() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        #expect(DefaultFileName.make(searchTerm: "x", date: date, calendar: buddhist) == "Auswahl_x_2026-11-12.pdf")
    }

    @Test func longTermIsTruncatedToSafeLength() {
        let name = DefaultFileName.make(searchTerm: String(repeating: "ä", count: 500), date: date, calendar: calendar)
        #expect(name.hasPrefix("Auswahl_ää"))
        #expect(name.hasSuffix("_2026-11-12.pdf"))
        #expect(name.utf8.count <= 255) // APFS file name limit
    }

    @Test func truncationCutsOnlyAtCharacterBoundaries() {
        // 1 + 39 × 3 = 118 bytes; a 40th "€" would exceed the 120-byte budget.
        let name = DefaultFileName.make(searchTerm: "a" + String(repeating: "€", count: 100), date: date, calendar: calendar)
        #expect(name == "Auswahl_a" + String(repeating: "€", count: 39) + "_2026-11-12.pdf")
    }

    @Test func truncationTrimsTrailingSeparators() {
        let term = String(repeating: "x", count: 118) + " /" + String(repeating: "y", count: 50)
        let name = DefaultFileName.make(searchTerm: term, date: date, calendar: calendar)
        #expect(name == "Auswahl_" + String(repeating: "x", count: 118) + "_2026-11-12.pdf")
    }
}
