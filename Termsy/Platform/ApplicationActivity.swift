import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum ApplicationActivity {
	static var isActive = true

	#if canImport(UIKit) && !os(macOS)
	private static var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

	static var hasBackgroundExecution: Bool {
		backgroundTaskID != .invalid
	}

	@discardableResult
	static func beginBackgroundExecution(name: String) -> Bool {
		guard backgroundTaskID == .invalid else { return true }
		backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) {
			let taskID = backgroundTaskID
			backgroundTaskID = .invalid
			if taskID != .invalid {
				UIApplication.shared.endBackgroundTask(taskID)
			}
		}
		return backgroundTaskID != .invalid
	}

	static func endBackgroundExecution() {
		guard backgroundTaskID != .invalid else { return }
		let taskID = backgroundTaskID
		backgroundTaskID = .invalid
		UIApplication.shared.endBackgroundTask(taskID)
	}
	#else
	static var hasBackgroundExecution: Bool { false }

	@discardableResult
	static func beginBackgroundExecution(name _: String) -> Bool { false }

	static func endBackgroundExecution() {}
	#endif
}
