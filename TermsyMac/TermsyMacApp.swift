#if os(macOS)
import AppKit
import GRDBQuery
import SwiftUI

@main
struct TermsyMacApp: App {
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue

	let db: DB

	init() {
		NSWindow.allowsAutomaticWindowTabbing = true
		self.db = DB.path(URL.documentsDirectory.appending(path: "termsy.db").path)
	}

	private var theme: TerminalTheme {
		TerminalTheme(rawValue: selectedTheme) ?? .mocha
	}

	var body: some Scene {
		WindowGroup("Termsy", for: MacTerminalSceneValue.self) { $sceneValue in
			MacRootView(sceneValue: sceneValue)
				.databaseContext(.readWrite { self.db.queue })
				.environment(\.appTheme, theme.appTheme)
				.preferredColorScheme(theme.appTheme.colorScheme)
				.tint(theme.appTheme.accent)
		} defaultValue: {
			MacTerminalSceneValue.localShell()
		}
		.commands {
			TermsyMacTerminalCommands()
		}
	}
}

private struct TermsyMacTerminalCommands: Commands {
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		CommandGroup(after: .newItem) {
			Button("New Local Shell") {
				openLocalShell()
			}
			.keyboardShortcut("t", modifiers: .command)

			Button("New SSH Session…") {
				showNewSSHSessionSheet()
			}
			.keyboardShortcut("n", modifiers: [.command, .shift])
		}
	}

	private func openLocalShell() {
		MacNativeTabCoordinator.shared.prepareForNewTab(from: NSApp.keyWindow ?? NSApp.mainWindow)
		openWindow(value: MacTerminalSceneValue.localShell())
	}

	private func showNewSSHSessionSheet() {
		if let window = NSApp.keyWindow ?? NSApp.mainWindow {
			NotificationCenter.default.post(name: .termsyPresentSSHSessionSheet, object: window)
			return
		}

		openWindow(value: MacTerminalSceneValue.localShell())
		DispatchQueue.main.async {
			guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
			NotificationCenter.default.post(name: .termsyPresentSSHSessionSheet, object: window)
		}
	}
}
#endif
