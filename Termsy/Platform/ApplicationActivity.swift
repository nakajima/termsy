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

		static var isForegroundActive: Bool {
			if UIApplication.shared.applicationState == .active {
				return true
			}
			return UIApplication.shared.connectedScenes.contains { scene in
				scene.activationState == .foregroundActive
			}
		}

		static var diagnosticStateDescription: String {
			let appState: String
			switch UIApplication.shared.applicationState {
			case .active:
				appState = "active"
			case .inactive:
				appState = "inactive"
			case .background:
				appState = "background"
			@unknown default:
				appState = "unknown"
			}
			let sceneStates = UIApplication.shared.connectedScenes.map { scene in
				let state: String
				switch scene.activationState {
				case .foregroundActive:
					state = "foregroundActive"
				case .foregroundInactive:
					state = "foregroundInactive"
				case .background:
					state = "background"
				case .unattached:
					state = "unattached"
				@unknown default:
					state = "unknown"
				}
				return "\(scene.session.role.rawValue):\(state)"
			}.sorted().joined(separator: ",")
			return "applicationState=\(appState) isForegroundActive=\(isForegroundActive) scenes=[\(sceneStates)] backgroundTaskActive=\(hasBackgroundExecution)"
		}

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
		static var isForegroundActive: Bool { isActive }
		static var diagnosticStateDescription: String { "isActive=\(isActive)" }
		static var hasBackgroundExecution: Bool { false }
		static var backgroundTimeRemaining: TimeInterval? { nil }

		@discardableResult
		static func beginBackgroundExecution(name _: String) -> Bool { false }

		static func endBackgroundExecution() {}
	#endif
}
