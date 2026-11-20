import XCTest

/// The main view with fictional demo files (`-uiTestDemoFiles YES`), in landscape.
@MainActor
final class MainViewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() async throws {
        if let app, let path = ProcessInfo.processInfo.environment["UITEST_DUMP_DIR"] {
            try? app.debugDescription.write(toFile: path + "/" + name.replacingOccurrences(of: " ", with: "_") + ".txt", atomically: true, encoding: .utf8)
        }
        app?.terminate()
    }

    /// Starts with demo files and the query; view settings are reset unless `keepSettings`.
    @discardableResult
    private func launch(query: String = "Rechnung", keepSettings: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemoFiles", "YES", "-demoQuery", query] + extra
        if !keepSettings {
            app.launchArguments += ["-uiTestResetSettings", "YES"]
        }
        app.launch()
        self.app = app
        XCTAssertTrue(app.descendants(matching: .any)["tile-Rechnung 2026-044 Heizung.pdf-1"].waitForExistence(timeout: 60),
                      "Treffer erscheinen nach dem Indizieren")
        return app
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private var tiles: XCUIElementQuery { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")) }

    func testLandscapeAndAllPanes() {
        launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "Querformat")
        XCTAssertTrue(element("folderTree").exists)
        XCTAssertTrue(element("resultsPane").exists)
        XCTAssertTrue(element("previewPane").exists)
        XCTAssertTrue(element("micButton").exists)
        XCTAssertTrue(element("wholeIPad").exists)
    }

    func testTappingATileChangesThePreview() {
        launch()
        let title = element("previewTitle")
        XCTAssertEqual(title.label, "Rechnung 2026-044 Heizung.pdf")
        element("tile-Waschmaschine.pdf-6").tap()
        XCTAssertTrue(waitFor(title, label: "Waschmaschine.pdf"))
        XCTAssertTrue(waitFor(element("previewPage"), label: "Seite 6 von 8"))
        element("tile-Kassenbon Bäckerei.jpg-1").tap()
        XCTAssertTrue(waitFor(title, label: "Kassenbon Bäckerei.jpg"))
        XCTAssertTrue(waitFor(element("matchCounter"), label: "Treffer 1 von 1"), "OCR-Rahmen auf dem JPEG")
    }

    func testPreviousAndNextMatch() {
        launch()
        let counter = element("matchCounter")
        XCTAssertTrue(waitFor(counter, label: "Treffer 1 von 5"))
        element("nextMatch").tap()
        XCTAssertTrue(waitFor(counter, label: "Treffer 2 von 5"))
        element("nextMatch").tap()
        XCTAssertTrue(waitFor(counter, label: "Treffer 3 von 5"))
        element("prevMatch").tap()
        XCTAssertTrue(waitFor(counter, label: "Treffer 2 von 5"))
        element("prevMatch").tap()
        element("prevMatch").tap()
        XCTAssertTrue(waitFor(counter, label: "Treffer 5 von 5"), "vom ersten Treffer rückwärts zum letzten")
        // The third page holds the last match.
        XCTAssertTrue(waitFor(element("previewPage"), label: "Seite 3 von 3"))
    }

    func testFullScreenOpensAndCloses() {
        launch()
        element("fullScreen").tap()
        XCTAssertTrue(waitForGone(element("resultsPane")))
        XCTAssertFalse(element("folderTree").exists)
        XCTAssertTrue(element("previewPane").exists)
        element("fullScreen").tap()
        XCTAssertTrue(element("resultsPane").waitForExistence(timeout: 5))
        XCTAssertTrue(element("folderTree").exists)
    }

    func testTreeToggles() {
        launch()
        XCTAssertTrue(element("folderTree").exists)
        element("toggleTree").tap()
        XCTAssertTrue(waitForGone(element("folderTree")))
        element("toggleTree").tap()
        XCTAssertTrue(element("folderTree").waitForExistence(timeout: 5))
    }

    func testPreviewSwapsSidesAndIsRemembered() {
        launch()
        XCTAssertGreaterThan(element("previewPane").frame.minX, element("resultsPane").frame.minX, "Vorschau rechts")
        element("swapPreview").tap()
        XCTAssertTrue(waitUntil { self.element("previewPane").frame.minX < self.element("resultsPane").frame.minX }, "Vorschau links")
        app.terminate()
        launch(keepSettings: true)
        XCTAssertLessThan(element("previewPane").frame.minX, element("resultsPane").frame.minX, "nach Neustart weiter links")
        element("swapPreview").tap()
        XCTAssertTrue(waitUntil { self.element("previewPane").frame.minX > self.element("resultsPane").frame.minX })
    }

    func testTileSliderChangesTileSizeAndCountAndIsRemembered() {
        launch()
        let slider = app.sliders["tileSizeSlider"]
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(waitUntil { self.tileWidth() > 100 })
        let bigWidth = tileWidth()
        let bigVisible = visibleTiles()
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(waitUntil { self.tileWidth() < 50 })
        let smallVisible = visibleTiles()
        XCTAssertLessThan(tileWidth(), bigWidth)
        XCTAssertGreaterThan(smallVisible, bigVisible, "kleine Kacheln: mehr sichtbar (\(smallVisible) gegenüber \(bigVisible))")
        app.terminate()
        launch(keepSettings: true)
        XCTAssertLessThan(tileWidth(), 50, "Kachelgröße bleibt nach Neustart")
        app.sliders["tileSizeSlider"].adjust(toNormalizedSliderPosition: 0.5)
    }

    func testKindFilter() {
        launch()
        let summary = element("resultsSummary")
        XCTAssertTrue(waitFor(summary, prefix: "8 Dateien"))
        app.buttons["JPEG"].tap()
        XCTAssertTrue(waitFor(summary, prefix: "2 Dateien"))
        XCTAssertFalse(element("tile-Handyvertrag.pdf-1").exists)
        app.buttons["PDF"].tap()
        XCTAssertTrue(waitFor(summary, prefix: "6 Dateien"))
        XCTAssertFalse(element("tile-Kassenbon Bäckerei.jpg-1").exists)
        app.buttons["Alle"].tap()
        XCTAssertTrue(waitFor(summary, prefix: "8 Dateien"))
    }

    func testTreeSelectionAndWholeIPad() {
        launch()
        let summary = element("resultsSummary")
        XCTAssertTrue(waitFor(summary, prefix: "8 Dateien"))
        element("folder-Fotos").tap()
        XCTAssertTrue(waitFor(summary, prefix: "2 Dateien"))
        XCTAssertTrue(summary.label.contains("Fotos"))
        element("wholeIPad").tap()
        XCTAssertTrue(waitFor(summary, prefix: "8 Dateien"))
        XCTAssertTrue(summary.label.contains("Ganzes iPad"))
        element("wholeIPad").tap()
        XCTAssertTrue(waitFor(summary, prefix: "2 Dateien"), "ohne „Ganzes iPad“ gilt wieder die Auswahl")
    }

    func testSortMenu() {
        launch()
        element("sortMenu").tap()
        app.buttons["Name"].tap()
        XCTAssertTrue(waitUntil { self.firstTileFile() == "Handyvertrag.pdf" }, "Name: \(firstTileFile() ?? "-")")
        element("sortMenu").tap()
        app.buttons["Trefferanzahl"].tap()
        XCTAssertTrue(waitUntil { self.firstTileFile() == "Rechnung 2026-044 Heizung.pdf" })
    }

    /// Run with the permissions revoked or granted beforehand (`xcrun simctl privacy … revoke|grant microphone/speech-recognition`);
    /// a permission prompt, if any, is denied. The app must keep running (crash 2026-11-17) and show a German hint or listen.
    func testMicrophoneDoesNotCrash() {
        launch()
        element("micButton").tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 4) else { break }
            let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT (label BEGINSWITH[c] 'Allow')")).firstMatch
            if deny.exists { deny.tap() } else { alert.buttons.element(boundBy: 0).tap() }
        }
        let message = element("speechMessage")
        let mic = element("micButton")
        XCTAssertTrue(waitUntil(timeout: 10) { message.exists || mic.label == "Sprachsuche beenden" },
                      "Hinweis oder Zuhören (Zustand: \(app.state.rawValue))")
        XCTAssertEqual(app.state, .runningForeground, "App läuft weiter")
        if message.exists {
            XCTAssertTrue(["nicht erlaubt", "nicht verfügbar", "konnte nicht starten"].contains { message.label.contains($0) }, message.label)
        } else {
            mic.tap()
            XCTAssertTrue(waitUntil { mic.label == "Sprachsuche" })
        }
    }

    /// Index stopped in the background (grace period ends at once by launch argument) and continued on return.
    func testIndexingContinuesAfterBackground() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemoFiles", "YES", "-demoQuery", "Summe", "-uiTestResetSettings", "YES",
                               "-uiTestBackgroundExpiresAtOnce", "YES", "-uiTestExtraImages", "60"]
        app.launch()
        self.app = app
        // Leave while the first run is still recognizing the photos.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        // Back at once, while the stopped run is still ending (the case that used to leave the rest undone).
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // Right after the return a tap can get lost in the scene transition: retry.
        for _ in 0..<5 where !app.navigationBars["Ordner und Index"].exists {
            element("openFolders").tap()
            _ = app.navigationBars["Ordner und Index"].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.navigationBars["Ordner und Index"].exists)
        // „Jetzt indizieren“ is offered only when no run is going.
        XCTAssertTrue(app.buttons["Jetzt indizieren"].waitForExistence(timeout: 120), "der fortgesetzte Lauf endet")
        XCTAssertTrue(element("interruptions").exists, "der Lauf wurde wirklich im Hintergrund unterbrochen")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'unterbrochen, wird fortgesetzt'")).firstMatch.exists)
        app.buttons["Fertig"].tap()
        // The JPEG matches come from text recognition, the last step of a run: present = the resumed run completed.
        XCTAssertTrue(element("tile-Kassenbon Bäckerei.jpg-1").waitForExistence(timeout: 10))
        XCTAssertTrue(element("tile-Quittung Baumarkt.jpg-1").exists)
        // Every photo is recognized, also those the stopped run had not reached.
        let field = element("searchField")
        field.tap()
        app.buttons["Suche löschen"].tap()
        field.typeText("Werkstatt")
        XCTAssertTrue(waitFor(element("resultsSummary"), prefix: "60 Dateien", timeout: 15), element("resultsSummary").label)
    }

    func testFoldersScreenOpens() {
        launch()
        element("openFolders").tap()
        XCTAssertTrue(app.navigationBars["Ordner und Index"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Auf diesem iPad"].exists)
        XCTAssertTrue(app.buttons["Ordner hinzufügen …"].exists)
        XCTAssertTrue(app.buttons["Jetzt indizieren"].exists)
        app.buttons["Fertig"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["Ordner und Index"]))
    }

    func testNoHitsShowsEmptyState() {
        launch()
        let field = element("searchField")
        field.tap()
        app.buttons["Suche löschen"].tap()
        field.typeText("Xylophonquartett")
        XCTAssertTrue(app.staticTexts["Keine Treffer"].waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    private func tileWidth() -> CGFloat { element("tile-Rechnung 2026-044 Heizung.pdf-1").frame.width }

    private func visibleTiles() -> Int {
        let pane = element("resultsScroll").frame
        return tiles.allElementsBoundByIndex.filter { pane.contains($0.frame) }.count
    }

    private func firstTileFile() -> String? {
        let all = tiles.allElementsBoundByIndex
        guard let first = all.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) else { return nil }
        let id = first.identifier.dropFirst("tile-".count)
        return id.split(separator: "-").dropLast().joined(separator: "-")
    }

    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.label == label }
    }

    private func waitFor(_ element: XCUIElement, prefix: String, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.label.hasPrefix(prefix) }
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
