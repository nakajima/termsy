#if os(macOS)
import AppKit
import GRDBQuery
import SwiftUI

@MainActor
final class MacTerminalWindowController: NSWindowController, NSWindowDelegate {
	let id = UUID()
	let source: MacTerminalTab.Source
	let terminal: MacTerminalTab

	private let db: DB
	private weak var manager: MacTerminalWindowManager?

	init(source: MacTerminalTab.Source, db: DB, manager: MacTerminalWindowManager) {
		self.source = source
		self.db = db
		self.manager = manager
		self.terminal = MacTerminalTab(source: source)

		let window = NSWindow(
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
			self?.close()
		}

		window.delegate = self
		window.contentViewController = NSHostingController(rootView: rootView())
		applyWindowAppearance()
		updateWindowTitle(terminal.windowTitle)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
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

	func updateWindowTitle(_ title: String) {
		window?.title = title
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
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func windowWillClose(_ notification: Notification) {
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
}
#endif
