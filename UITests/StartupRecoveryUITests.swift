import XCTest

@MainActor final class StartupRecoveryUITests: XCTestCase {
    func testColdLaunchTabsAndForegroundRecovery() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.clearkeyboard")
        for attempt in 1...3 {
            app.terminate(); app.launch()
            let home = app.buttons["home.setup"]
            XCTAssertTrue(home.waitForExistence(timeout: 12), "Home did not load on cold launch \(attempt)")
            XCTAssertEqual(app.state, .runningForeground)
            let bar = app.tabBars.firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            for title in ["定制", "输入", "首页"] {
                let tab = bar.buttons[title]
                XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
                XCTAssertEqual(app.state, .runningForeground)
            }
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(home.waitForExistence(timeout: 8))
            XCTAssertEqual(app.state, .runningForeground)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "startup-recovery-\(attempt)"; image.lifetime = .keepAlways; add(image)
        }
        print("APP_STARTUP_RECOVERY_OK coldLaunches=3 tabs=3 foregroundRecovery=3")
    }
}
