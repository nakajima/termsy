#if os(macOS)
import AppKit

@MainActor
final class MacTerminalWindowManager {
	static let shared = MacTerminalWindowManager()
	static let tabbingIdentifier = "fm.folder.Termsy.terminal"

	private var db: DB?
	private var controllers: [UUID: MacTerminalWindowController] = [:]
	private var pendingTabSource: MacTerminalTab.Source?
	private var hasOpenedInitialWindow = false

	private init() {}

	func configure(db: DB) {
		self.db = db
	}

	func openInitialWindowIfNeeded() {
		guard !hasOpenedInitialWindow else { return }
		hasOpenedInitialWindow = true
		_ = openLocalShellWindow()
	}

	@discardableResult
	func openLocalShellWindow() -> MacTerminalWindowController {
		openWindow(source: .localShell)
	}

	func openNewLocalShellTabOrWindow() {
		guard let hostWindow = frontmostController?.window else {
			_ = openLocalShellWindow()
			return
		}
		hostWindow.makeKeyAndOrderFront(nil)
		let sent = NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
		if !sent {
			_ = openWindow(source: .localShell, hostWindow: hostWindow)
		}
	}

	func showNewSSHSessionSheet() {
		if let controller = frontmostController {
			controller.presentConnectSheet()
			return
		}

		let controller = openLocalShellWindow()
		DispatchQueue.main.async {
			controller.presentConnectSheet()
		}
	}

	func openSSHSession(_ session: Session, from hostWindow: NSWindow?) {
		if let existing = existingController(for: session) {
			reveal(existing)
			return
		}

		guard let hostWindow, controller(for: hostWindow) != nil else {
			_ = openWindow(source: .ssh(session))
			return
		}

		pendingTabSource = .ssh(session)
		hostWindow.makeKeyAndOrderFront(nil)
		let sent = NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
		if !sent {
			pendingTabSource = nil
			_ = openWindow(source: .ssh(session), hostWindow: hostWindow)
		}
	}

	func openNewTabFromSystemRequest() {
		let source = pendingTabSource ?? .localShell
		pendingTabSource = nil
		let hostWindow = frontmostController?.window
		_ = openWindow(source: source, hostWindow: hostWindow)
	}

	func controller(for window: NSWindow?) -> MacTerminalWindowController? {
		guard let window else { return nil }
		return controllers.values.first { $0.window === window }
	}

	func controllerDidClose(_ controller: MacTerminalWindowController) {
		controllers.removeValue(forKey: controller.id)
	}

	private var frontmostController: MacTerminalWindowController? {
		controller(for: NSApp.keyWindow ?? NSApp.mainWindow)
	}

	private func existingController(for session: Session) -> MacTerminalWindowController? {
		controllers.values.first { controller in
			guard case let .ssh(existingSession) = controller.source else { return false }
			return existingSession.uuid == session.uuid
		}
	}

	@discardableResult
	private func openWindow(
		source: MacTerminalTab.Source,
		hostWindow: NSWindow? = nil
	) -> MacTerminalWindowController {
		if case let .ssh(session) = source,
		   let existing = existingController(for: session) {
			reveal(existing)
			return existing
		}

		guard let db else {
			fatalError("MacTerminalWindowManager must be configured before opening windows")
		}

		let controller = MacTerminalWindowController(source: source, db: db, manager: self)
		controllers[controller.id] = controller

		if let hostWindow {
			controller.prepareForAutomaticTabbing(with: hostWindow)
		}

		controller.showWindow(nil)
		controller.revealWindow()
		return controller
	}

	private func reveal(_ controller: MacTerminalWindowController) {
		controller.revealWindow()
	}
}
#endif
