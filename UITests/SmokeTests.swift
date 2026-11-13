import TestSupport
import XCTest

/// Spec §7: the app starts, opens a folder, a search fills the grid, a tick selects a page.
final class SmokeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = try PDFFixtures.tempDirectory()
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("vertrag_2024.pdf"),
                                pages: ["Der Vertrag gilt ab Januar.", "Anlage ohne Treffer.", "Vertragsende im Dezember."])
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("angebot.pdf"), pages: ["Angebot zum Vertrag."])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSearchFillsGridAndTickSelectsPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("Vertrag*")

        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "at least one document row")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "documentRow").count, 1)

        let tick = row.checkBoxes.firstMatch
        XCTAssertTrue(tick.waitForExistence(timeout: 10))
        // The tick sits top left on the tile (Chris, Task 5.6); scroll it into view in case the grid
        // starts scrolled or the window is small.
        let grid = app.descendants(matching: .any).matching(identifier: "resultGrid").firstMatch
        // isHittable is true even outside the visible area, so compare the frames.
        for _ in 0..<30 where !grid.frame.contains(tick.frame) {
            grid.scroll(byDeltaX: 0, deltaY: -40)
        }
        XCTAssertTrue(grid.frame.contains(tick.frame), "tick scrolled into view: \(tick.frame) in \(grid.frame)")
        tick.click()
        let count = app.staticTexts["selectionCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt")
    }

    /// Spec 1.1 §4/§6: two folders loaded, a search shows rows from both.
    func testTwoFoldersShowRowsFromBoth() throws {
        let second = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: second) }
        try PDFFixtures.makePDF(at: second.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag zur Miete."])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolders", folder.path + "|" + second.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("Vertrag")
        // Rows are built lazily (only visible ones exist): check the two first rows by name and the total.
        let rows = app.descendants(matching: .any).matching(identifier: "documentRow")
        let fromSecond = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "mietvertrag.pdf")).firstMatch
        let fromFirst = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "angebot.pdf")).firstMatch
        XCTAssertTrue(fromSecond.waitForExistence(timeout: 20), "row from the second folder")
        XCTAssertTrue(fromFirst.waitForExistence(timeout: 20), "row from the first folder")
        let summary = app.staticTexts["summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String ?? summary.label).hasPrefix("Gefunden in 3 Dokumenten"), "all three documents of both folders")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sourcesMenu").firstMatch.exists)
    }

    /// 1.2.2 §1: two searches confirmed with Return; the arrow opens the history, a click on an entry searches it.
    func testSearchHistoryPicksEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("Angebot\r")
        app.typeKey(.escape, modifierFlags: [])
        field.click()
        field.typeText("Januar\r")
        let button = app.descendants(matching: .any).matching(identifier: "searchHistoryButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "history arrow")
        button.click()
        let entries = app.descendants(matching: .any).matching(identifier: "historyEntry")
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 5), "history list")
        let angebot = entries.matching(NSPredicate(format: "label == %@ OR value == %@", "Angebot", "Angebot")).firstMatch
        XCTAssertTrue(angebot.exists, "older entry listed")
        angebot.click()
        XCTAssertEqual(field.value as? String, "Angebot", "chosen term in the field")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'documentRow' AND label BEGINSWITH 'angebot.pdf'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the search ran")
    }

    /// 1.2.2 §2: the toolbar font slider at 20 pt makes „Reihen“ visibly larger and keeps it whole.
    func testToolbarFontGrows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        // The stepper's text carries „Reihen: n“ as its value, not as its label.
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reihen' OR value BEGINSWITH 'Reihen'")).firstMatch
        XCTAssertTrue(rows.waitForExistence(timeout: 10), "„Reihen“")
        let before = rows.frame
        app.typeKey(",", modifierFlags: .command)
        let tab = app.toolbars.buttons["Darstellung"].exists ? app.toolbars.buttons["Darstellung"] : app.buttons["Darstellung"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "settings tab „Darstellung“")
        tab.click()
        let slider = app.sliders["toolbarFontSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "font slider")
        slider.adjust(toNormalizedSliderPosition: 1.0)
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("w", modifierFlags: .command)                  // close the settings window
        let after = rows.frame
        XCTAssertGreaterThan(after.height, before.height, "taller")
        XCTAssertGreaterThanOrEqual(after.width, before.width * 1.3, "wider by the font, so not cut off (\(before.width) → \(after.width))")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(after), "inside the window")
    }

    /// 1.2.1 §2: window size and the preview divider survive a restart.
    func testWindowAndSplitterSurviveRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "window")
        let splitter = app.descendants(matching: .any).matching(identifier: "previewSplitter").firstMatch
        XCTAssertTrue(splitter.waitForExistence(timeout: 10), "divider")
        // Make the window smaller from its bottom-right corner, then move the divider down by 80 pt.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -120, dy: -90)))
        let handle = splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 80)))
        Thread.sleep(forTimeInterval: 0.5)
        let frame = window.frame, divider = splitter.frame
        app.terminate()

        app.launchArguments = ["-uiTestFolder", folder.path, "-uiTestKeepDefaults", "YES"]
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 15), "window after restart")
        XCTAssertTrue(splitter.waitForExistence(timeout: 10), "divider after restart")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 3, "width kept")
        XCTAssertEqual(window.frame.height, frame.height, accuracy: 3, "height kept")
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 3, "position kept")
        XCTAssertEqual(splitter.frame.minY - window.frame.minY, divider.minY - frame.minY, accuracy: 3, "divider kept")
    }

    /// 1.2.1 §1: adding a folder while one is loaded asks; „Ersetzen“ leaves one source, „Zusätzlich“ two.
    func testAddPromptReplace() throws { try addPrompt(answer: "addPrompt.replace", expected: "Quellen (1)") }
    func testAddPromptAdditionally() throws { try addPrompt(answer: "addPrompt.add", expected: "Quellen (2)") }

    private func addPrompt(answer: String, expected: String) throws {
        let second = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: second) }
        try PDFFixtures.makePDF(at: second.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag zur Miete."])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path, "-uiTestAddFolder", second.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let button = app.descendants(matching: .any).matching(identifier: answer).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the add prompt shows")
        let title = app.staticTexts["„\(second.lastPathComponent)“ hinzufügen?"]
        XCTAssertTrue(title.exists, "prompt title names the folder")
        button.click()
        let menu = app.descendants(matching: .any).matching(identifier: "sourcesMenu").firstMatch
        let text = { menu.title + " " + menu.label + " " + ((menu.value as? String) ?? "") }
        let deadline = Date().addingTimeInterval(15)
        while !text().contains(expected), Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertTrue(text().contains(expected), "sources menu shows \(expected), was: \(text())")
    }

    /// Spec 1.1 §7/§9: typing with the focus in the grid searches; ⌫, Esc, ⌘F, Return ticks, Tab order.
    func testKeyboardTypeToSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Browsing (empty field) shows rows; click a tile to put the focus into the grid.
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "browse rows")
        let grid = app.descendants(matching: .any).matching(identifier: "resultGrid").firstMatch
        grid.click()
        // The keys below must be routed from the grid, not typed by a focused field.
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "search field must not have the focus")
        app.typeText("vertragx")
        XCTAssertEqual(field.value as? String, "vertragx", "letters typed in the grid go to the search field")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(field.value as? String, "vertrag")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual((field.value as? String) ?? "", "", "Esc clears the search field")
        app.typeText("Angebot")
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertEqual((field.value as? String) ?? "", "", "⌘⌫ deletes the last word")
        // ⌘F puts the focus into the field and selects the text: typing replaces it.
        app.typeText("Vertrag")
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Angebot")
        XCTAssertEqual(field.value as? String, "Angebot", "⌘F selects the search text")
        // Tab from the search field goes to the grid (Tab skips the search field by default); Return ticks.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Tab left the search field")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let count = app.staticTexts["selectionCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt", "Return ticks the focused tile")
    }

    /// 1.2.1 bug: first start (fresh settings), folder loaded, a word typed without clicking anywhere — ↓ must
    /// go to the grid at once and select the first hit page (Return then ticks it).
    func testFirstStartTypeThenArrowSelectsFirstHit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "browse rows")
        let field = app.textFields["searchField"]
        print("first start: search field has focus = \(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false)")
        app.typeText("Vertrag")
        XCTAssertEqual(field.value as? String, "Vertrag", "typed text lands in the search field")
        let hitRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'documentRow' AND label CONTAINS 'Treffer'")).firstMatch
        XCTAssertTrue(hitRow.waitForExistence(timeout: 10), "hits")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "↓ left the search field")
        app.typeKey(.return, modifierFlags: [])
        let count = app.staticTexts["selectionCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt", "↓ selected the first hit page")
    }

    /// Spec 1.1 §3 (review of Task 9): moving the preview keeps the keyboard focus in the grid.
    func testPreviewPositionKeepsFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "browse rows")
        app.descendants(matching: .any).matching(identifier: "resultGrid").firstMatch.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let count = app.staticTexts["selectionCount"]
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt")
        let right = app.radioButtons["Vorschau rechts"].exists ? app.radioButtons["Vorschau rechts"] : app.buttons["Vorschau rechts"]
        XCTAssertTrue(right.waitForExistence(timeout: 5), "segment „Vorschau rechts“")
        right.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(count.value as? String ?? count.label, "Keine Seiten ausgewählt", "Return still acts on the focused tile")
        // A mouse click into the search field, then Tab: back to the grid, Return ticks again.
        let field = app.textFields["searchField"]
        field.click()
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Tab left the search field")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt", "Tab after a click into the field reaches the grid")
    }

    /// Spec 1.2: a scanned PDF and a photo become searchable through the text recognition; the photo shows
    /// as a tile with the photo symbol, the scan page with the „Texterkennung“ badge.
    func testScanAndPhotoAreFound() throws {
        let scans = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: scans) }
        try OCRFixtures.makeScanPDF(at: scans.appendingPathComponent("scan.pdf"),
                                    images: [try OCRFixtures.textImage(["Kündigung zum Jahresende"], size: CGSize(width: 1654, height: 2339)).image])
        try OCRFixtures.write(try OCRFixtures.textImage(["Quittung Kündigung"]).image, to: scans.appendingPathComponent("foto.png"), type: .png)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", scans.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("Kündigung")
        let rows = app.descendants(matching: .any).matching(identifier: "documentRow")
        let scanRow = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "scan.pdf")).firstMatch
        let photoRow = rows.matching(NSPredicate(format: "label BEGINSWITH %@", "foto.png")).firstMatch
        XCTAssertTrue(scanRow.waitForExistence(timeout: 60), "scan found after recognition")
        XCTAssertTrue(photoRow.waitForExistence(timeout: 60), "photo found after recognition")
        XCTAssertTrue(scanRow.descendants(matching: .any).matching(identifier: "ocrBadge").firstMatch.waitForExistence(timeout: 10),
                      "badge „Texterkennung“ on the scan page")
    }
}
