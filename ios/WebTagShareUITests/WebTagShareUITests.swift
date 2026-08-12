import XCTest

final class WebTagShareUITests: XCTestCase {
    func testCompanionShellAndSettingsAreAccessible() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["待办"].exists)
        XCTAssertTrue(app.tabBars.buttons["传输"].exists)
        XCTAssertTrue(app.staticTexts["today.summary"].waitForExistence(timeout: 5))

        app.buttons["app.settings"].tap()
        XCTAssertTrue(app.textFields["settings.origin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.api-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout: 5))
    }

    func testDeepLinksSelectCompanionDestinations() {
        let app = XCUIApplication()
        app.launch()

        XCUIDevice.shared.system.open(URL(string: "webtag://todos")!)
        XCTAssertTrue(app.navigationBars["待办"].waitForExistence(timeout: 5))

        XCUIDevice.shared.system.open(URL(string: "webtag://transfers")!)
        XCTAssertTrue(app.navigationBars["传输"].waitForExistence(timeout: 5))
    }
}
