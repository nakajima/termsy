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
			Settings {
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
		func applicationDidFinishLaunching(_: Notification) {
			MacTerminalWindowManager.shared.openInitialWindowIfNeeded()
		}

		func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
			if !flag {
				MacTerminalWindowManager.shared.openLocalShellWindow()
			}
			return true
		}

		@IBAction func newWindowForTab(_: Any?) {
			MacTerminalWindowManager.shared.openNewTabFromSystemRequest()
		}
	}

	private struct TermsyMacTerminalCommands: Commands {
		var body: some Commands {
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

			CommandMenu("Tabs") {
				ForEach(1 ... 9, id: \.self) { number in
					Button("Select Tab \(number)") {
						MacTerminalWindowManager.shared.selectTabNumber(number)
					}
					.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
				}
			}
		}
	}
#endif
