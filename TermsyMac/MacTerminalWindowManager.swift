#if os(macOS)
	import AppKit

	@MainActor
	final class MacTerminalWindowManager {
		static let shared = MacTerminalWindowManager()
		static let tabbingIdentifier = "fm.folder.Termsy.terminal"

		private static let windowLayoutStateDefaultsKey = "macTerminalWindowLayoutState"

		private final class TabGroupObservation {
			let group: NSWindowTabGroup
			private var windowsObservation: NSKeyValueObservation?
			private var selectedWindowObservation: NSKeyValueObservation?

			init(group: NSWindowTabGroup, onChange: @escaping () -> Void) {
				self.group = group
				windowsObservation = group.observe(\.windows, options: [.new]) { _, _ in
					onChange()
				}
				selectedWindowObservation = group.observe(\.selectedWindow, options: [.new]) { _, _ in
					onChange()
				}
			}
		}

		private var db: DB?
		private var controllers: [UUID: MacTerminalWindowController] = [:]
		private var tabGroupObservations: [ObjectIdentifier: TabGroupObservation] = [:]
		private var pendingTabSource: MacTerminalTab.Source?
		private var hasOpenedInitialWindow = false
		private var isRestoringPersistedLayout = false

		private init() {}

		func configure(db: DB) {
			self.db = db
		}

		func openInitialWindowIfNeeded() {
			guard !hasOpenedInitialWindow else { return }
			hasOpenedInitialWindow = true
			guard !restorePersistedWindowLayoutIfPossible() else { return }
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
			_ = openWindow(source: .localShell, hostWindow: hostWindow)
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

			_ = openWindow(source: .ssh(session), hostWindow: hostWindow)
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
			windowLayoutDidChange()
		}

		func windowLayoutDidChange() {
			refreshTabGroupObservations()
			persistWindowLayoutIfNeeded()
		}

		func persistWindowLayoutNow() {
			persistWindowLayout()
		}

		func selectTabNumber(_ number: Int) {
			guard number >= 1,
			      let group = frontmostController?.window?.tabGroup,
			      group.windows.indices.contains(number - 1),
			      let controller = controller(for: group.windows[number - 1])
			else { return }
			reveal(controller)
		}

		private var frontmostController: MacTerminalWindowController? {
			controller(for: NSApp.keyWindow ?? NSApp.mainWindow)
		}

		private func controller(forSceneID sceneID: UUID) -> MacTerminalWindowController? {
			controllers.values.first { $0.sceneID == sceneID }
		}

		private func existingController(for session: Session) -> MacTerminalWindowController? {
			controllers.values.first { controller in
				guard case let .ssh(existingSession) = controller.source else { return false }
				return existingSession.id == session.id
			}
		}

		private func makeSceneValue(for source: MacTerminalTab.Source) -> MacTerminalSceneValue {
			switch source {
			case .localShell:
				return .localShell()
			case let .ssh(session):
				return .ssh(session, customTitle: session.customTitle)
			}
		}

		@discardableResult
		private func openWindow(
			source: MacTerminalTab.Source,
			hostWindow: NSWindow? = nil
		) -> MacTerminalWindowController {
			openWindow(sceneValue: makeSceneValue(for: source), hostWindow: hostWindow, activate: true)
		}

		@discardableResult
		private func openWindow(
			sceneValue: MacTerminalSceneValue,
			hostWindow: NSWindow? = nil,
			activate: Bool
		) -> MacTerminalWindowController {
			switch sceneValue.kind {
			case .localShell:
				break
			case let .ssh(session):
				if let existing = existingController(for: session) {
					if activate {
						reveal(existing)
					}
					return existing
				}
			}

			guard let db else {
				fatalError("MacTerminalWindowManager must be configured before opening windows")
			}

			let controller = MacTerminalWindowController(sceneValue: sceneValue, db: db, manager: self)
			controllers[controller.id] = controller

			if let hostWindow {
				controller.prepareForAutomaticTabbing(with: hostWindow)
			}

			controller.showWindow(nil)
			if let hostWindow, let window = controller.window, window !== hostWindow {
				hostWindow.addTabbedWindow(window, ordered: .above)
			}
			if activate {
				controller.revealWindow()
			}
			windowLayoutDidChange()
			return controller
		}

		private func reveal(_ controller: MacTerminalWindowController) {
			controller.revealWindow()
			windowLayoutDidChange()
		}

		private func restorePersistedWindowLayoutIfPossible() -> Bool {
			guard let state = loadPersistedWindowLayout(), !state.groups.isEmpty else { return false }

			isRestoringPersistedLayout = true
			defer {
				isRestoringPersistedLayout = false
				windowLayoutDidChange()
			}

			var restoredControllers: [UUID: MacTerminalWindowController] = [:]

			for group in state.groups {
				var hostWindow: NSWindow?
				var groupControllers: [MacTerminalWindowController] = []

				for sceneValue in group.tabs {
					let controller = openWindow(sceneValue: sceneValue, hostWindow: hostWindow, activate: false)
					if hostWindow == nil {
						hostWindow = controller.window
					}
					restoredControllers[sceneValue.id] = controller
					groupControllers.append(controller)
				}

				if let frame = group.frame, let hostWindow {
					hostWindow.setFrame(frame, display: false)
				}

				if let selectedTabID = group.selectedTabID,
				   let selectedController = restoredControllers[selectedTabID],
				   let selectedWindow = selectedController.window
				{
					selectedWindow.tabGroup?.selectedWindow = selectedWindow
				} else if let fallbackWindow = groupControllers.first?.window {
					fallbackWindow.tabGroup?.selectedWindow = fallbackWindow
				}
			}

			guard !restoredControllers.isEmpty else { return false }

			if let frontmostTabID = state.frontmostTabID,
			   let frontmostController = restoredControllers[frontmostTabID]
			{
				reveal(frontmostController)
			} else if let fallbackController = restoredControllers.values.first {
				reveal(fallbackController)
			}

			return true
		}

		private func orderedManagedWindows() -> [NSWindow] {
			let orderedWindows = NSApp.orderedWindows.compactMap { window in
				controller(for: window) != nil ? window : nil
			}
			var seenWindowIDs = Set(orderedWindows.map(ObjectIdentifier.init))
			var result = orderedWindows
			for controller in controllers.values {
				guard let window = controller.window else { continue }
				let windowID = ObjectIdentifier(window)
				guard !seenWindowIDs.contains(windowID) else { continue }
				seenWindowIDs.insert(windowID)
				result.append(window)
			}
			return result
		}

		private func currentWindowLayoutState() -> MacTerminalWindowLayoutState {
			var groups: [MacTerminalWindowLayoutState.Group] = []
			var seenGroupIDs: Set<ObjectIdentifier> = []

			for window in orderedManagedWindows() {
				let group = window.tabGroup
				let groupID = group.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
				guard !seenGroupIDs.contains(groupID) else { continue }
				seenGroupIDs.insert(groupID)

				let groupWindows = group?.windows ?? [window]
				let tabs = groupWindows.compactMap { controller(for: $0)?.persistedSceneValue }
				guard !tabs.isEmpty else { continue }

				let selectedWindow = group?.selectedWindow ?? window
				let selectedTabID = controller(for: selectedWindow)?.sceneID
				groups.append(
					MacTerminalWindowLayoutState.Group(
						tabs: tabs,
						selectedTabID: selectedTabID,
						frame: selectedWindow.frame
					)
				)
			}

			return MacTerminalWindowLayoutState(
				groups: groups,
				frontmostTabID: frontmostController?.sceneID
			)
		}

		private func persistWindowLayoutIfNeeded() {
			guard !isRestoringPersistedLayout else { return }
			persistWindowLayout()
		}

		private func persistWindowLayout() {
			let layout = currentWindowLayoutState()
			guard !layout.groups.isEmpty else {
				UserDefaults.standard.removeObject(forKey: Self.windowLayoutStateDefaultsKey)
				return
			}

			do {
				let data = try JSONEncoder().encode(layout)
				UserDefaults.standard.set(data, forKey: Self.windowLayoutStateDefaultsKey)
			} catch {
				print("[State] failed to persist mac window layout: \(error)")
			}
		}

		private func loadPersistedWindowLayout() -> MacTerminalWindowLayoutState? {
			guard let data = UserDefaults.standard.data(forKey: Self.windowLayoutStateDefaultsKey) else {
				return nil
			}

			do {
				return try JSONDecoder().decode(MacTerminalWindowLayoutState.self, from: data)
			} catch {
				print("[State] failed to decode mac window layout: \(error)")
				UserDefaults.standard.removeObject(forKey: Self.windowLayoutStateDefaultsKey)
				return nil
			}
		}

		private func refreshTabGroupObservations() {
			var activeGroupIDs: Set<ObjectIdentifier> = []

			for controller in controllers.values {
				guard let group = controller.window?.tabGroup else { continue }
				let groupID = ObjectIdentifier(group)
				activeGroupIDs.insert(groupID)
				guard tabGroupObservations[groupID] == nil else { continue }
				tabGroupObservations[groupID] = TabGroupObservation(group: group) { [weak self] in
					Task { @MainActor [weak self] in
						self?.windowLayoutDidChange()
					}
				}
			}

			tabGroupObservations = tabGroupObservations.filter { activeGroupIDs.contains($0.key) }
		}
	}
#endif
