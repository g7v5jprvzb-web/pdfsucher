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
        // The main window by its id: `windows.firstMatch` can be the settings window while it closes.
        let window = app.windows.matching(identifier: "main").firstMatch.frame
        XCTAssertTrue(window.contains(after), "inside the window (\(after) in \(window))")
    }

    /// 1.2.4: every settings tab shows its last element without scrolling; the window can be enlarged and keeps
    /// its size after a restart.
    func testSettingsTabsFitAndSizeIsKept() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        app.typeKey(",", modifierFlags: .command)
        // The settings window by its id: `windows.element(boundBy: 0)` became the main window after the drag, so
        // the test resized and measured the main window (found when „Allgemein“ fitted again).
        let window = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "settings window")
        let lastElements: [(tab: String, element: XCUIElement)] = [
            ("Allgemein", app.descendants(matching: .any)["debouncePicker"]),
            ("Vorschau", app.buttons["Zurücksetzen"]),
            ("Darstellung", app.descendants(matching: .any)["toolbarFontReset"]),
            ("Word/PowerPoint", app.buttons["Folien-Cache leeren"]),
            ("Speicher", app.buttons["Kachel-Cache leeren"]),
            ("Tastatur", app.descendants(matching: .any)["tabIncludesSearchToggle"]),
        ]
        var settingsWindow = window.frame
        for (tab, last) in lastElements {
            let button = app.toolbars.buttons[tab].exists ? app.toolbars.buttons[tab] : app.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "tab \(tab)")
            button.click()
            XCTAssertTrue(last.waitForExistence(timeout: 5), "last element of \(tab)")
            settingsWindow = window.frame
            XCTAssertTrue(settingsWindow.contains(last.frame), "\(tab): last element inside the window without scrolling")
        }
        // Enlarge from the bottom-right corner, close, restart: the size is kept.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: 80, dy: 40)))
        Thread.sleep(forTimeInterval: 0.5)
        let enlarged = window.frame
        XCTAssertGreaterThan(enlarged.width, settingsWindow.width + 40, "the settings window can be resized")
        // Another tab keeps the size the user chose (review I3).
        let general = app.toolbars.buttons["Allgemein"].exists ? app.toolbars.buttons["Allgemein"] : app.buttons["Allgemein"]
        general.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(window.frame.height, enlarged.height, accuracy: 3, "switching tabs keeps the height")
        XCTAssertEqual(window.frame.width, enlarged.width, accuracy: 3, "switching tabs keeps the width")
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
        app.launchArguments = ["-uiTestFolder", folder.path, "-uiTestKeepDefaults", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(window.waitForExistence(timeout: 5), "settings window after restart")
        Thread.sleep(forTimeInterval: 1)
        let restored = window.frame
        XCTAssertEqual(restored.width, enlarged.width, accuracy: 3, "width kept")
        XCTAssertEqual(restored.height, enlarged.height, accuracy: 3, "height kept")
    }

    /// Ordnerleiste: show the bar, click a folder → only its files; ✕ → all again.
    func testFolderBarFiltersAndClears() throws {
        let tree = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        let sub = tree.appendingPathComponent("Verträge", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: sub.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag"])
        try PDFFixtures.makePDF(at: tree.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", tree.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let rows = app.descendants(matching: .any).matching(identifier: "documentRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "browse rows")
        let toggle = app.descendants(matching: .any)["folderBarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "toolbar button")
        toggle.click()
        // A row without a disclosure triangle reports its text as value, one with a triangle as label (macOS 26).
        let folder = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'folderRow' AND (label BEGINSWITH 'Verträge' OR value BEGINSWITH 'Verträge')")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "folder „Verträge“ in the bar")
        folder.click()
        let header = app.descendants(matching: .any)["folderFilterHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "filter header")
        let deadline = Date().addingTimeInterval(10)
        while rows.count != 1, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 1, "only the folder's file")
        XCTAssertTrue(rows.firstMatch.label.hasPrefix("mietvertrag.pdf"))
        app.descendants(matching: .any)["folderFilterClear"].click()
        let back = Date().addingTimeInterval(10)
        while rows.count != 2, Date() < back { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 2, "all files again")
        XCTAssertFalse(header.exists, "no header without a filter")
    }

    /// 1.3.5 (Chris): Tab went from the folder bar into the grid but not back. Tab and ⇧Tab cycle both ways.
    func testTabCyclesFolderBarAndGrid() throws {
        let tree = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        let sub = tree.appendingPathComponent("Verträge", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: sub.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag"])
        try PDFFixtures.makePDF(at: tree.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", tree.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
            .waitForExistence(timeout: 20), "browse rows")
        app.descendants(matching: .any)["folderBarToggle"].click()
        let folderTree = app.descendants(matching: .any).matching(identifier: "folderTree").firstMatch
        XCTAssertTrue(folderTree.waitForExistence(timeout: 10), "folder bar")
        let folder = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'folderRow' AND (label BEGINSWITH 'Verträge' OR value BEGINSWITH 'Verträge')")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "folder „Verträge“ in the bar")
        folder.click()
        func treeHasFocus() -> Bool { folderTree.value(forKey: "hasKeyboardFocus") as? Bool ?? false }
        func expectTree(_ focused: Bool, _ step: String) {
            let deadline = Date().addingTimeInterval(3)
            while treeHasFocus() != focused, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertEqual(treeHasFocus(), focused, step)
        }
        expectTree(true, "click puts the focus into the folder bar")
        app.typeKey(.tab, modifierFlags: [])
        expectTree(false, "Tab: folder bar → grid")
        app.typeKey(.tab, modifierFlags: [])
        expectTree(true, "Tab: grid → folder bar")
        app.typeKey(.tab, modifierFlags: [])
        expectTree(false, "Tab: folder bar → grid again")
        app.typeKey(.tab, modifierFlags: [])
        expectTree(true, "Tab: grid → folder bar again")
    }

    /// 1.3.6 (Chris): ⇧Tab hides the folder bar, then the large preview as well, then shows both again; Tab still
    /// cycles folder bar ↔ grid afterwards.
    func testShiftTabCyclesLayout() throws {
        let tree = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        try PDFFixtures.makePDF(at: tree.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", tree.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "browse rows")
        let folderTree = app.descendants(matching: .any).matching(identifier: "folderTree").firstMatch
        if !folderTree.exists { app.descendants(matching: .any)["folderBarToggle"].click() }
        XCTAssertTrue(folderTree.waitForExistence(timeout: 10), "folder bar shown")
        let splitter = app.descendants(matching: .any).matching(identifier: "previewSplitter").firstMatch
        XCTAssertTrue(splitter.waitForExistence(timeout: 10), "preview shown")
        row.click()
        func expect(tree shown: Bool, preview: Bool, _ step: String) {
            let deadline = Date().addingTimeInterval(3)
            while (folderTree.exists != shown || splitter.exists != preview), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertEqual(folderTree.exists, shown, step + ": folder bar")
            XCTAssertEqual(splitter.exists, preview, step + ": preview")
        }
        app.typeKey(.tab, modifierFlags: .shift)
        expect(tree: false, preview: true, "1st ⇧Tab")
        app.typeKey(.tab, modifierFlags: .shift)
        expect(tree: false, preview: false, "2nd ⇧Tab")
        app.typeKey(.tab, modifierFlags: .shift)
        expect(tree: true, preview: true, "3rd ⇧Tab")
        app.typeKey(.tab, modifierFlags: [])
        let deadline = Date().addingTimeInterval(3)
        while !(folderTree.value(forKey: "hasKeyboardFocus") as? Bool ?? false), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(folderTree.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Tab: grid → folder bar after the cycle")
    }

    /// The tree opens down to a chosen folder: choose a deep folder below 40 others, close its parent, scroll
    /// up, hide and show the bar (⌃⌘S) → the parent is open again and the folder scrolled into view.
    func testFolderBarRevealsChosenFolder() throws {
        let tree = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        let deep = tree.appendingPathComponent("Verträge/2024", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: deep.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag"])
        try PDFFixtures.makePDF(at: tree.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot"])
        for i in 0..<40 {                                                    // above „Verträge“, without subfolders
            let other = tree.appendingPathComponent(String(format: "Akte %02d", i), isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: tree.appendingPathComponent("angebot.pdf"), to: other.appendingPathComponent("a.pdf"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", tree.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch.waitForExistence(timeout: 20))
        let toggle = app.descendants(matching: .any)["folderBarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        func row(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == 'folderRow' AND (label BEGINSWITH %@ OR value BEGINSWITH %@)", name, name)).firstMatch
        }
        let vertraege = row("Verträge")
        XCTAssertTrue(vertraege.waitForExistence(timeout: 10), "„Verträge“ under the open source root")
        XCTAssertFalse(row("2024").exists, "subfolders start closed")
        let outline = app.outlines.firstMatch
        let triangle = outline.disclosureTriangles.element(boundBy: 1)       // 0: the source root, 1: „Verträge“
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "disclosure triangle of „Verträge“")
        triangle.click()
        XCTAssertTrue(row("2024").waitForExistence(timeout: 5), "„2024“ after opening „Verträge“")
        row("2024").click()
        XCTAssertTrue(app.descendants(matching: .any)["folderFilterHeader"].waitForExistence(timeout: 5))
        triangle.click()                                                     // close „Verträge“ again
        let gone = Date().addingTimeInterval(5)
        while row("2024").exists, Date() < gone { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(row("2024").exists, "hidden in the closed parent")
        outline.scroll(byDeltaX: 0, deltaY: 5000)                            // back to the top
        XCTAssertTrue(row("Akte 00").isHittable, "scrolled to the top")
        XCTAssertFalse(row("Verträge").isHittable, "„Verträge“ below the visible part")
        toggle.click()                                                       // hide the bar …
        Thread.sleep(forTimeInterval: 0.5)
        toggle.click()                                                       // … and show it: opened to the filter
        XCTAssertTrue(row("2024").waitForExistence(timeout: 5), "the tree opened down to the chosen folder")
        XCTAssertTrue(row("2024").isHittable, "visible")
    }

    /// A folder chosen by code (as a place click does) below 40 others: the tree opens and scrolls to it —
    /// right after the start, before the tree is built (waits for it), and later with the bar already shown.
    func testFolderChosenByCodeIsRevealedAtOnce() throws { try folderChosenByCode(delay: 0) }
    func testFolderChosenByCodeIsRevealedLater() throws { try folderChosenByCode(delay: 3) }

    private func folderChosenByCode(delay: Double) throws {
        let tree = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tree) }
        let deep = tree.appendingPathComponent("Verträge/2024", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: deep.appendingPathComponent("mietvertrag.pdf"), pages: ["Der Vertrag"])
        for i in 0..<40 {
            let other = tree.appendingPathComponent(String(format: "Akte %02d", i), isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: deep.appendingPathComponent("mietvertrag.pdf"), to: other.appendingPathComponent("a.pdf"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", tree.path, "-uiTestSelectFolder", deep.path, "-uiTestSelectFolderDelay", "\(delay)"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'folderRow' AND (label BEGINSWITH '2024' OR value BEGINSWITH '2024')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the tree opened down to „2024“")
        let deadline = Date().addingTimeInterval(5)
        while !row.isHittable, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(row.isHittable, "scrolled into view below the 40 other folders")
        XCTAssertTrue(app.descendants(matching: .any)["folderFilterHeader"].exists, "filtered")
    }

    /// 1.3.2: a document whose name alone matches shows with „Treffer im Dateinamen“; one whose text matches does not.
    func testFileNameHitIsMarked() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PDFFixtures.makePDF(at: dir.appendingPathComponent("Rechnung März.pdf"), pages: ["Nur Zahlen 123"])
        try PDFFixtures.makePDF(at: dir.appendingPathComponent("Protokoll.pdf"), pages: ["Die Rechnung kommt"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", dir.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let rows = app.descendants(matching: .any).matching(identifier: "documentRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "browse rows")
        let field = app.descendants(matching: .any)["searchField"]
        field.click()
        field.typeText("Rechnung")
        let deadline = Date().addingTimeInterval(10)
        while rows.count != 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 2, "the name hit and the text hit")
        let hint = app.descendants(matching: .any)["nameHitHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "„Treffer im Dateinamen“")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "nameHitHint").count, 1, "only on the name-only row")
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
    /// go to the grid at once and select the first hit page (Return then ticks it). Since 1.3.3 the search
    /// already shows that page; the first ↓ enters the grid on it (Chris: „Erst auf den ersten Treffer“).
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
        let firstName = String(hitRow.label.split(separator: " (")[0])
        let shown = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", firstName + " · S. ")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the preview shows the first document's hit (\(firstName))")
        let shownLabel = shown.value as? String
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "↓ left the search field")
        XCTAssertTrue(shown.exists, "the preview still shows the first document's hit")
        XCTAssertEqual(shown.value as? String, shownLabel, "the first ↓ keeps the shown page")
        app.typeKey(.return, modifierFlags: [])
        let count = app.staticTexts["selectionCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String ?? count.label, "1 Seite ausgewählt", "↓ selected the first hit page")
    }

    /// 1.3.3: a typed term with hits shows its first hit page in the large preview at once, without an arrow;
    /// the keyboard stays in the search field (typing goes on). The first ↓ enters the grid on that page, the
    /// second moves on to the next document.
    func testSearchShowsFirstHitInPreviewAtOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window")
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "browse rows")
        let field = app.textFields["searchField"]
        field.click()
        field.typeText("Vertrag")
        let shown = app.staticTexts.matching(NSPredicate(format: "value CONTAINS ' · S. '")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the preview shows a hit page without ↓")
        XCTAssertTrue(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "the search field keeps the keyboard")
        field.typeText(" ")           // same term (partial words are off: „Vertra“ alone finds nothing)
        XCTAssertEqual(field.value as? String, "Vertrag ", "typing goes on in the field")
        let firstRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'documentRow' AND label CONTAINS 'Treffer'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "hits")
        let firstLabel = shown.value as? String ?? ""
        XCTAssertTrue(firstRow.label.hasPrefix(String(firstLabel.split(separator: " · ").first ?? "")),
                      "the preview shows the first document of the list (\(firstLabel) / \(firstRow.label))")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertFalse(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "↓ left the search field")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(shown.value as? String, firstLabel, "the first ↓ enters the grid on the shown first hit")
        app.typeKey(.downArrow, modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        let preview = app.staticTexts.matching(NSPredicate(format: "value CONTAINS ' · S. '")).firstMatch
        while (preview.value as? String) == firstLabel, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertNotEqual(preview.value as? String, firstLabel, "the second ↓ moved to the next document")
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
