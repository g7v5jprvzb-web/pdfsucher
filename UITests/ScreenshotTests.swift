import TestSupport
import XCTest

/// Screenshots for Chris (Task 5.5). Runs only when `PDFSUCHER_SCREENSHOTS` is set. The sandboxed test
/// runner may not write into the project, so the images are kept as attachments of the test result:
/// `TEST_RUNNER_PDFSUCHER_SCREENSHOTS=1 scripts/uitest.sh -only-testing:PDFSucherUITests/ScreenshotTests`, then
/// `xcrun xcresulttool export attachments --path <.xcresult> --output-path <folder>` (names in manifest.json).
final class ScreenshotTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard let flag = ProcessInfo.processInfo.environment["PDFSUCHER_SCREENSHOTS"], !flag.isEmpty else {
            throw XCTSkip("PDFSUCHER_SCREENSHOTS not set")
        }
        continueAfterFailure = false
        folder = try PDFFixtures.tempDirectory()
        try ScreenshotFixtures.make(in: folder)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func save(_ app: XCUIApplication, _ name: String) throws {
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func search(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch.waitForExistence(timeout: 20))
        sleep(2)   // thumbnails render off the main actor
    }

    private func focusFirstTile(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(identifier: "documentRow").firstMatch
        let tile = row.descendants(matching: .image).firstMatch
        if tile.waitForExistence(timeout: 5) { tile.click() } else { row.click() }
        sleep(2)
    }

    func testScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFolder", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        search(app, "Vertrag")
        focusFirstTile(app)
        try save(app, "01-treffer-fest-5-seiten.png")

        let automatic = app.checkBoxes["columnsAutomatic"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        automatic.click()
        sleep(2)
        try save(app, "02-treffer-automatisch.png")
        automatic.click()

        search(app, "Mietvertrag")
        focusFirstTile(app)
        try save(app, "03-getrenntes-wort-markiert.png")
    }
}
