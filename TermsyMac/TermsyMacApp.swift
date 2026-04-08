#if os(macOS)
import AppKit
import SwiftUI

@main
struct TermsyMacApp: App {
	@NSApplicationDelegateAdaptor(TermsyMacAppDelegate.self) private var appDelegate

	let db: DB

	init() {
		NSWindow.allowsAutomaticWindowTabbing = true
		self.db = DB.path(URL.documentsDirectory.appending(path: "termsy.db").path)
		MacTerminalWindowManager.shared.configure(db: db)
	}

	var body: some Scene {
		Window("Settings", id: "settings") {
			MacSettingsView()
		}
		.defaultSize(width: 560, height: 480)
		.commands {
			TermsyMacTerminalCommands()
		}
	}
}

@MainActor
final class TermsyMacAppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		MacTerminalWindowManager.shared.openInitialWindowIfNeeded()
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag {
			MacTerminalWindowManager.shared.openLocalShellWindow()
		}
		return true
	}

	@IBAction func newWindowForTab(_ sender: Any?) {
		MacTerminalWindowManager.shared.openNewTabFromSystemRequest()
	}
}

private struct TermsyMacTerminalCommands: Commands {
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		CommandGroup(replacing: .appSettings) {
			Button("Settings…") {
				openWindow(id: "settings")
			}
			.keyboardShortcut(",", modifiers: .command)
		}

		CommandGroup(replacing: .newItem) {
			Button("New Window") {
				MacTerminalWindowManager.shared.openLocalShellWindow()
			}
			.keyboardShortcut("n", modifiers: .command)

			Button("New Tab") {
				MacTerminalWindowManager.shared.openNewLocalShellTabOrWindow()
			}
			.keyboardShortcut("t", modifiers: .command)

			Divider()

			Button("New SSH Session…") {
				MacTerminalWindowManager.shared.showNewSSHSessionSheet()
			}
			.keyboardShortcut("n", modifiers: [.command, .shift])
		}
	}
}
#endif
