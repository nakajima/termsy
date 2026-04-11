#if os(macOS)
	import AppKit
	import GRDB
	import GRDBQuery
	import SwiftUI

	@MainActor
	final class MacTerminalWindowController: NSWindowController, NSWindowDelegate {
		let id = UUID()
		let source: MacTerminalTab.Source
		let terminal: MacTerminalTab

		private let db: DB
		private weak var manager: MacTerminalWindowManager?
		private var bypassesCloseConfirmation = false
		private var isShowingCloseConfirmation = false

		init(source: MacTerminalTab.Source, db: DB, manager: MacTerminalWindowManager) {
			self.source = source
			self.db = db
			self.manager = manager
			self.terminal = MacTerminalTab(source: source)

			let window = TermsyTerminalWindow(
				contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
				styleMask: [.titled, .closable, .miniaturizable, .resizable],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.delegate = nil
			window.center()
			window.contentMinSize = NSSize(width: 700, height: 450)

			super.init(window: window)

			terminal.onRequestClose = { [weak self] in
				self?.requestClose()
			}
			terminal.onRequestRename = { [weak self] in
				self?.presentRenameAlert()
			}
			window.onRenameTabRequest = { [weak self] in
				self?.presentRenameAlert()
			}

			window.delegate = self
			window.contentViewController = NSHostingController(rootView: rootView())
			applyWindowAppearance()
			updateWindowTitle(terminal.windowTitle)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		func prepareForAutomaticTabbing(with hostWindow: NSWindow) {
			guard let window else { return }
			hostWindow.tabbingMode = .preferred
			hostWindow.tabbingIdentifier = MacTerminalWindowManager.tabbingIdentifier
			window.tabbingMode = .preferred
			window.tabbingIdentifier = MacTerminalWindowManager.tabbingIdentifier
			window.setFrame(hostWindow.frame, display: false)
		}

		func presentConnectSheet() {
			guard let window else { return }
			NotificationCenter.default.post(name: .termsyPresentSSHSessionSheet, object: window)
		}

		func requestClose() {
			guard let window else {
				close()
				return
			}
			window.performClose(nil)
		}

		func presentRenameAlert() {
			guard let window else { return }

			let alert = NSAlert()
			alert.messageText = "Rename Tab"
			alert.informativeText = "Leave blank to use the automatic title."

			let textField = NSTextField(string: terminal.customTitle ?? "")
			textField.placeholderString = terminal.automaticTitle
			textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
			alert.accessoryView = textField

			alert.addButton(withTitle: "Save")
			alert.addButton(withTitle: "Use Automatic Title")
			alert.addButton(withTitle: "Cancel")

			alert.beginSheetModal(for: window) { [weak self] response in
				guard let self else { return }
				switch response {
				case .alertFirstButtonReturn:
					self.persistRename(textField.stringValue)
				case .alertSecondButtonReturn:
					self.persistRename(nil)
				default:
					break
				}
				self.updateWindowTitle(self.terminal.windowTitle)
			}

			DispatchQueue.main.async {
				window.makeFirstResponder(textField)
				textField.selectText(nil)
			}
		}

		private func persistRename(_ title: String?) {
			terminal.rename(to: title)
			guard case let .ssh(session) = source else { return }

			var updatedSession = session
			updatedSession.customTitle = terminal.customTitle
			do {
				try db.queue.write { db in
					if updatedSession.id == nil {
						try updatedSession.save(db)
					} else {
						try updatedSession.update(db)
					}
				}
			} catch {
				print("[DB] failed to persist customTitle for session \(updatedSession.id.map(String.init) ?? "new"): \(error)")
			}
		}

		func updateWindowTitle(_ title: String) {
			window?.title = title
			window?.tab.title = title
			window?.tab.toolTip = title
		}

		func applyWindowAppearance() {
			guard let window else { return }
			let theme = TerminalTheme.current.appTheme
			let blurMode = TerminalBackgroundBlurSettings(
				rawValue: UserDefaults.standard.string(forKey: TerminalBackgroundBlurSettings.key) ?? ""
			) ?? .default
			var opacity = TerminalBackgroundSettings.normalizedOpacity(
				UserDefaults.standard.object(forKey: TerminalBackgroundSettings.opacityKey) as? Double
					?? TerminalBackgroundSettings.defaultOpacity
			)
			if blurMode.requiresTransparency, opacity >= 0.999 {
				opacity = TerminalBackgroundBlurSettings.recommendedOpacityWhenEnabled
				UserDefaults.standard.set(opacity, forKey: TerminalBackgroundSettings.opacityKey)
			}
			let backgroundColor = theme.backgroundUIColor.withAlphaComponent(CGFloat(opacity))

			window.styleMask.remove(.fullSizeContentView)
			window.titleVisibility = .visible
			window.titlebarAppearsTransparent = false
			window.isMovableByWindowBackground = false
			window.toolbar = nil
			window.isOpaque = opacity >= 0.999
			window.backgroundColor = backgroundColor
			window.appearance = NSAppearance(named: theme.colorScheme == .dark ? .darkAqua : .aqua)
			window.tabbingMode = .preferred
			window.tabbingIdentifier = MacTerminalWindowManager.tabbingIdentifier
			if #available(macOS 11.0, *) {
				window.titlebarSeparatorStyle = .automatic
			}

			window.contentView?.wantsLayer = true
			window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
			window.contentView?.superview?.wantsLayer = true
			window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
			MacWindowBlurController.shared.applyBlur(mode: blurMode, opacity: opacity, to: window)
		}

		func revealWindow() {
			guard let window else { return }
			window.tabGroup?.selectedWindow = window
			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)
			terminal.setDisplayActive(true)
			requestTerminalFocus()
		}

		func windowShouldClose(_ sender: NSWindow) -> Bool {
			if bypassesCloseConfirmation {
				bypassesCloseConfirmation = false
				return true
			}

			guard terminal.needsCloseConfirmation else { return true }
			guard !isShowingCloseConfirmation else { return false }

			let alert = NSAlert()
			alert.messageText = "Close Tab?"
			alert.informativeText = "A process may still be running in this tab. Close it anyway?"
			alert.alertStyle = .warning
			alert.addButton(withTitle: "Close Tab")
			alert.addButton(withTitle: "Cancel")

			isShowingCloseConfirmation = true
			alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
				guard let self else { return }
				self.isShowingCloseConfirmation = false
				guard response == .alertFirstButtonReturn, let sender else { return }
				self.bypassesCloseConfirmation = true
				sender.performClose(nil)
			}
			return false
		}

		func windowDidBecomeKey(_: Notification) {
			terminal.setDisplayActive(true)
			requestTerminalFocus()
		}

		func windowDidResignKey(_: Notification) {
			terminal.setDisplayActive(false)
		}

		func windowWillClose(_: Notification) {
			terminal.close()
			manager?.controllerDidClose(self)
		}

		private func rootView() -> some View {
			MacRootView(
				terminal: terminal,
				onOpenSSH: { [weak self] session, hostWindow in
					self?.manager?.openSSHSession(session, from: hostWindow)
				},
				onWindowTitleChange: { [weak self] title in
					self?.updateWindowTitle(title)
				},
				onWindowAppearanceChange: { [weak self] in
					self?.applyWindowAppearance()
				}
			)
			.databaseContext(.readWrite { db.queue })
		}

		private func requestTerminalFocus(retryCount: Int = 6) {
			guard let window, window.attachedSheet == nil else { return }
			if focusTerminalView(in: window) {
				return
			}
			guard retryCount > 0 else { return }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
				self?.requestTerminalFocus(retryCount: retryCount - 1)
			}
		}

		@discardableResult
		private func focusTerminalView(in window: NSWindow) -> Bool {
			let terminalView = terminal.terminalView
			guard terminalView.window === window else { return false }
			if window.firstResponder === terminalView {
				return true
			}
			return window.makeFirstResponder(terminalView)
		}
	}
#endif
