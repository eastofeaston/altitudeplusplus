import XCTest

/// Remote navigation checks. Runs with `-previewHome`, so no account is needed.
final class FocusNavigationTests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-previewHome"] + extraArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 30))
        sleep(2)
    }

    private var focusedLabel: String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? focused.label : "<none>"
    }

    private func press(_ button: XCUIRemote.Button, _ note: String) {
        remote.press(button)
        sleep(1)
        print("FOCUS after \(note): \(focusedLabel)")
    }

    func testUpFromWatchLiveReachesTabBar() {
        launch()
        press(.down, "down")
        XCTAssertTrue(app.buttons["Watch Live"].hasFocus, "Down from the tab bar should land on Watch Live")
        press(.up, "up from Watch Live")
        XCTAssertTrue(app.tabBars.buttons["Live"].hasFocus, "Up from Watch Live should reach the Live tab")
    }

    /// With an error showing, the Live page is taller than the screen, so
    /// browsing Up Next scrolls it and hides the tab bar.
    func testUpFromWatchLiveAfterBrowsingTallPage() {
        launch(["-previewError"])
        press(.down, "down to Watch Live")
        press(.down, "down to Up Next")
        press(.right, "right along Up Next")
        press(.up, "up back to hero")
        XCTAssertTrue(app.buttons["Watch Live"].hasFocus, "Up from Up Next should return to Watch Live")
        press(.up, "up from Watch Live")
        XCTAssertTrue(app.tabBars.buttons["Live"].hasFocus, "Up from Watch Live should reach the Live tab")
    }

    func testUpFromTeamRowsReachesTabBar() {
        launch()
        press(.right, "right on tab bar")
        XCTAssertTrue(app.tabBars.buttons["Avalanche"].hasFocus)
        press(.down, "down into Avalanche")
        let deadline = Date().addingTimeInterval(20)
        while focusedLabel == "Avalanche", Date() < deadline { sleep(1); remote.press(.down) }
        let firstRowItem = focusedLabel
        press(.down, "down to row 2")
        press(.down, "down to row 3")
        press(.up, "up to row 2")
        press(.up, "up to row 1")
        XCTAssertEqual(focusedLabel, firstRowItem, "Should be back on the first row")
        press(.up, "up from first row")
        XCTAssertTrue(app.tabBars.buttons["Avalanche"].hasFocus, "Up from the first row should reach the Avalanche tab")
    }

    /// `-favoriteTeam` sets the saved preference for this launch only (UserDefaults argument domain).
    func testTeamOrderFollowsSetting() {
        launch()
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 1).label, "Avalanche", "Avalanche is first by default")
        app.terminate()

        launch(["-favoriteTeam", "nuggets"])
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 1).label, "Nuggets")
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 2).label, "Avalanche")
    }

    func testSettingsBottomBackToTabBar() {
        launch(["-tab", "settings"])
        print("FOCUS at launch: \(focusedLabel)")
        for step in 1...12 { press(.down, "down \(step)") }
        for step in 1...12 {
            press(.up, "up \(step)")
            if app.tabBars.buttons["Settings"].hasFocus { break }
        }
        XCTAssertTrue(app.tabBars.buttons["Settings"].hasFocus, "Up from the bottom of Settings should reach the Settings tab")
    }
}
