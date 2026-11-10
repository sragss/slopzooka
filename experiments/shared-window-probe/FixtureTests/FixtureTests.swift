import XCTest

final class FixtureTests: XCTestCase {
    @MainActor func testSettingsInteractionAndEvidence() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["increment"].waitForExistence(timeout: 15))
        app.buttons["increment"].tap()
        XCTAssertEqual(app.staticTexts["counter"].label, "Count: 1")
        let toggle = app.switches["setting"]
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let field = app.textFields["draft"]
        field.tap()
        let nonce = "probe-" + UUID().uuidString.prefix(8)
        field.typeText(String(nonce))
        XCTAssertTrue((field.value as? String ?? "").contains(nonce))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Settings-after-actual-tap-and-type-\(nonce)"; shot.lifetime = .keepAlways
        add(shot)
    }
    @MainActor func testScrollRotationAndDialog() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["show-dialog"].waitForExistence(timeout: 15))
        app.buttons["show-dialog"].tap()
        XCTAssertTrue(app.alerts["Fixture dialog"].waitForExistence(timeout: 5))
        app.alerts.buttons["Done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        let row = app.staticTexts["row-30"]
        for _ in 0..<12 {
            if row.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.isHittable, "Scrolling must expose a previously offscreen row")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "landscape-scrolled"; shot.lifetime = .keepAlways; add(shot)
    }
}
