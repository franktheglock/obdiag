import XCTest

/// Headless walkthrough of the primary flows using the debug launch hooks
/// (`-uiDemo`, `-demoAdapter`, `-startSection`, `-autoPrompt`).
final class OBDiagUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    // MARK: Onboarding

    func testOnboardingWelcomeScreen() {
        let app = launch(["-resetOnboarding"])
        XCTAssertTrue(
            app.staticTexts["Your car, explained in plain language"].waitForExistence(timeout: 10),
            "Welcome headline should be visible on first run"
        )
        XCTAssertTrue(app.buttons["Continue"].exists, "Continue button should exist")
        XCTAssertTrue(app.staticTexts["Live sensors"].exists)
        XCTAssertTrue(app.staticTexts["Fault codes"].exists)
    }

    // MARK: Dashboard

    func testDashboardShowsDemoFaultsAndLiveSensors() {
        let app = launch(["-uiDemo", "-demoAdapter", "-startSection=dashboard"])

        XCTAssertTrue(app.staticTexts["Daily driver"].firstMatch.waitForExistence(timeout: 15), "Vehicle name on dashboard")
        XCTAssertTrue(app.staticTexts["Fault codes"].waitForExistence(timeout: 10))

        let p0171Row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'P0171'")).firstMatch
        XCTAssertTrue(p0171Row.waitForExistence(timeout: 10), "Stored code P0171 should be listed")
        let p0420Row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'P0420'")).firstMatch
        XCTAssertTrue(p0420Row.exists, "Stored code P0420 should be listed")
        XCTAssertTrue(app.staticTexts["Live sensors"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["RPM"].exists, "RPM tile should be present")

        // Open the first fault code and verify the detail sheet.
        p0171Row.tap()
        XCTAssertTrue(app.staticTexts["What it means"].waitForExistence(timeout: 5), "DTC detail sheet")
        XCTAssertTrue(app.staticTexts["Likely causes"].exists)
        app.buttons["Done"].tap()
    }

    func testSensorDetailOpens() {
        let app = launch(["-uiDemo", "-demoAdapter", "-startSection=dashboard"])
        XCTAssertTrue(app.staticTexts["Daily driver"].firstMatch.waitForExistence(timeout: 15))

        let rpmTile = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Engine speed'")).firstMatch
        XCTAssertTrue(rpmTile.waitForExistence(timeout: 10), "RPM tile should be tappable")
        rpmTile.tap()
        XCTAssertTrue(app.staticTexts["What this tells you"].waitForExistence(timeout: 5), "Sensor detail sheet")
        XCTAssertTrue(app.staticTexts["Healthy range"].exists)
        app.buttons["Done"].tap()
    }

    // MARK: Chat

    func testDemoAssistantAnswersWithToolUse() {
        let app = launch(["-uiDemo", "-demoAdapter", "-autoPrompt=Explainmyfaultcodes"])

        // The answer is composed from tool results; wait for the grounded text.
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'System too lean'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 25), "Demo assistant should produce a grounded answer")

        let toolLine = app.staticTexts["Scanning fault codes"].firstMatch
        XCTAssertTrue(toolLine.exists || app.staticTexts["Reading live data"].firstMatch.exists,
                      "Tool activity should be shown in the transcript")
    }

    // MARK: Settings & subscription

    func testSettingsNavigationAndPaywall() {
        let app = launch(["-uiDemo", "-startSection=settings"])

        let providerRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'AI provider'")).firstMatch
        XCTAssertTrue(providerRow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Model'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Search'")).firstMatch.exists)

        providerRow.tap()
        XCTAssertTrue(app.staticTexts["OpenRouter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LM Studio (local)"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        let planRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'plan'")).firstMatch
        XCTAssertTrue(planRow.waitForExistence(timeout: 5))
        planRow.tap()
        XCTAssertTrue(app.staticTexts["Credit balance"].waitForExistence(timeout: 5), "Subscription sheet")
        XCTAssertTrue(app.staticTexts["Top up credits"].exists)
        app.buttons["Done"].tap()
    }

    // MARK: Garage

    func testGarageSelectionOpensDashboard() {
        let app = launch(["-uiDemo", "-startSection=garage"])

        XCTAssertTrue(app.staticTexts["Your vehicles"].waitForExistence(timeout: 10))
        let card = app.staticTexts["Daily driver"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["Fault codes"].waitForExistence(timeout: 10), "Garage card should open the dashboard")
    }
}
