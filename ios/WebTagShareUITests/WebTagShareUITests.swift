import XCTest

final class WebTagShareUITests: XCTestCase {
    func testSettingsSurfaceExposesAccessibleConfigurationControls() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.textFields["settings.origin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.api-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout: 5))
    }
}
