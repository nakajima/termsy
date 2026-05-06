import XCTest

final class TermsyUITests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	@MainActor
	func testIpadSavedSessionsScreenshot() throws {
		try captureScreenshot(for: .savedSessions)
	}

	@MainActor
	func testIpadNewSessionScreenshot() throws {
		try captureScreenshot(for: .newSession)
	}

	@MainActor
	func testIpadTerminalScreenshot() throws {
		try captureScreenshot(for: .terminal)
	}

	@MainActor
	func testIpadBackgroundReconnectScreenshot() throws {
		try captureScreenshot(for: .backgroundReconnect)
	}

	@MainActor
	func testIpadSessionPickerScreenshot() throws {
		try captureScreenshot(for: .sessionPicker)
	}

	@MainActor
	func testIpadSettingsScreenshot() throws {
		try captureScreenshot(for: .settings)
	}

	@MainActor
	func testDirectSessionInputOpensTerminal() throws {
		let app = XCUIApplication()
		configureLaunchEnvironment(for: app, scenario: ScreenshotPlan.savedSessions.scenario)
		XCUIDevice.shared.orientation = .landscapeLeft
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not reach foreground")

		let filterField = app.textFields["field.sessionFilter"]
		XCTAssertTrue(filterField.waitForExistence(timeout: 10), "Session filter field did not appear")
		filterField.typeText("fresh@example.com:pwd#work -2222\n")

		XCTAssertTrue(app.otherElements["screen.terminal"].waitForExistence(timeout: 10), "Direct session input did not open a terminal")
	}

	@MainActor
	func testDirectSessionInputShowsDirectRowForExistingSession() throws {
		let app = XCUIApplication()
		configureLaunchEnvironment(for: app, scenario: ScreenshotPlan.savedSessions.scenario)
		XCUIDevice.shared.orientation = .landscapeLeft
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not reach foreground")

		let filterField = app.textFields["field.sessionFilter"]
		XCTAssertTrue(filterField.waitForExistence(timeout: 10), "Session filter field did not appear")
		filterField.typeText("root@pimux")

		XCTAssertTrue(app.buttons["row.directSession"].waitForExistence(timeout: 5), "Direct session row did not appear for an existing target")
		XCTAssertTrue(app.buttons["row.session.root@pimux:22#-"].exists, "Matching saved session row disappeared")
	}

	@MainActor
	func testSessionFilterControlNAndControlPMoveSelection() throws {
		let app = XCUIApplication()
		configureLaunchEnvironment(for: app, scenario: ScreenshotPlan.savedSessions.scenario)
		XCUIDevice.shared.orientation = .landscapeLeft
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not reach foreground")

		let filterField = app.textFields["field.sessionFilter"]
		let firstRow = app.buttons["row.session.root@pimux:22#-"]
		let secondRow = app.buttons["row.session.nethack@alt.org:22#-"]
		XCTAssertTrue(filterField.waitForExistence(timeout: 10), "Session filter field did not appear")
		XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "First saved session row did not appear")
		XCTAssertTrue(secondRow.waitForExistence(timeout: 10), "Second saved session row did not appear")

		waitForSelected(firstRow)

		filterField.typeKey("n", modifierFlags: .control)
		waitForSelected(secondRow)

		filterField.typeKey("p", modifierFlags: .control)
		waitForSelected(firstRow)
	}

	private func waitForSelected(
		_ element: XCUIElement,
		timeout: TimeInterval = 5,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let predicate = NSPredicate(format: "value == %@", "selected")
		let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
		let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
		XCTAssertEqual(result, .completed, "Element did not become selected", file: file, line: line)
	}

	private enum ScreenshotPlan {
		case savedSessions
		case newSession
		case terminal
		case backgroundReconnect
		case sessionPicker
		case settings

		var scenario: String {
			switch self {
			case .savedSessions:
				return "saved-sessions"
			case .newSession:
				return "new-session"
			case .terminal:
				return "terminal"
			case .backgroundReconnect:
				return "background-reconnect"
			case .sessionPicker:
				return "session-picker"
			case .settings:
				return "settings"
			}
		}

		var screenshotName: String {
			switch self {
			case .savedSessions:
				return "ipad-01-saved-sessions"
			case .newSession:
				return "ipad-02-new-session"
			case .terminal:
				return "ipad-03-terminal"
			case .backgroundReconnect:
				return "ipad-04-background-reconnect"
			case .sessionPicker:
				return "ipad-05-session-picker"
			case .settings:
				return "ipad-06-settings"
			}
		}
	}

	@MainActor
	private func captureScreenshot(for plan: ScreenshotPlan) throws {
		let app = XCUIApplication()
		configureLaunchEnvironment(for: app, scenario: plan.scenario)
		XCUIDevice.shared.orientation = .landscapeLeft
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App did not reach foreground")
		settleUI(for: plan.scenario, forceLandscape: true)
		takeScreenshot(named: plan.screenshotName)
	}

	private func configureLaunchEnvironment(for app: XCUIApplication, scenario: String) {
		let screenshotDBPath = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("termsy-screenshot-\(UUID().uuidString).sqlite")
			.path

		app.launchEnvironment["TERMSY_SCREENSHOT_SCENARIO"] = scenario
		app.launchEnvironment["TERMSY_SCREENSHOT_DB_PATH"] = screenshotDBPath
		app.launchArguments += ["-ui_testing"]
	}

	private func settleUI(for scenario: String, forceLandscape: Bool) {
		let baseDelay: TimeInterval
		switch scenario {
		case "terminal", "session-picker", "background-reconnect":
			baseDelay = 6.0
		default:
			baseDelay = 4.0
		}

		let orientationDelay: TimeInterval = forceLandscape ? 2.0 : 0.0
		RunLoop.current.run(until: Date(timeIntervalSinceNow: baseDelay + orientationDelay))
	}

	private func takeScreenshot(named name: String) {
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
