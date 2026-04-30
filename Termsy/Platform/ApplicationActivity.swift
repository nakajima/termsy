import Foundation
#if canImport(UIKit)
	import UIKit
#endif

@MainActor
enum ApplicationActivity {
	static var isActive = true
	static var onBackgroundExecutionExpiration: ((TimeInterval?) -> Void)?

	#if canImport(UIKit) && !os(macOS)
		private static var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

		static var hasBackgroundExecution: Bool {
			backgroundTaskID != .invalid
		}

		static var backgroundTimeRemaining: TimeInterval? {
			UIApplication.shared.backgroundTimeRemaining
		}

		@discardableResult
		static func beginBackgroundExecution(name: String) -> Bool {
			guard backgroundTaskID == .invalid else { return true }
			backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) {
				Task { @MainActor in
					let remaining = UIApplication.shared.backgroundTimeRemaining
					let taskID = backgroundTaskID
					backgroundTaskID = .invalid
					if taskID != .invalid {
						UIApplication.shared.endBackgroundTask(taskID)
					}
					onBackgroundExecutionExpiration?(remaining)
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
		static var backgroundTimeRemaining: TimeInterval? { nil }

		@discardableResult
		static func beginBackgroundExecution(name _: String) -> Bool { false }

		static func endBackgroundExecution() {}
	#endif
}
