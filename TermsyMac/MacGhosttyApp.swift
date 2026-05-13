#if os(macOS)
	import AppKit
	import TermsyGhosttyCore

	/// Bridges access to NSPasteboard for ghostty's `readClipboard` callback.
	/// Exposed (with `@testable`) so tests can exercise the threading behavior
	/// directly without spinning up a full ghostty surface.
	enum MacClipboardBridge {
		/// Reads the current pasteboard string. Safe to call from any thread.
		///
		/// We deliberately do NOT hop to main here: ghostty can invoke its
		/// `readClipboard` callback from a worker thread while the main thread
		/// is synchronously busy inside `ghostty_surface_binding_action` (e.g.
		/// during a paste). Dispatching back to main would deadlock the worker
		/// against the busy main thread, hanging the terminal until the tab is
		/// killed. NSPasteboard's read methods don't require main; the iOS
		/// equivalent (UIPasteboard) is also accessed without hopping.
		static func readClipboardStringMirroringProduction() -> String? {
			NSPasteboard.general.string(forType: .string)
		}
	}

	@MainActor
	final class MacGhosttyApp {
		static let shared = MacGhosttyApp()

		private var runtime: GhosttyRuntime?

		var app: ghostty_app_t? {
			runtime?.app
		}

		private init() {
			let savedTheme = TerminalTheme(
				rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? ""
			) ?? .mocha

			self.runtime = GhosttyRuntime(
				initialConfigText: Self.buildConfigText(theme: savedTheme),
				supportsSelectionClipboard: false,
				handlers: .init(
					wakeup: {
						if Thread.isMainThread {
							MacGhosttyApp.shared.tick()
						} else {
							DispatchQueue.main.async {
								MacGhosttyApp.shared.tick()
							}
						}
					},
					action: { target, action in
						guard target.tag == GHOSTTY_TARGET_SURFACE,
						      let surface = target.target.surface,
						      action.tag == GHOSTTY_ACTION_SET_TITLE,
						      let cTitle = action.action.set_title.title,
						      let view = GhosttySurfaceUserdata.object(fromOpaque: ghostty_surface_userdata(surface), as: MacTerminalView.self)
						else { return }

						let title = String(cString: cTitle)
						Task { @MainActor [weak view] in
							view?.handleTitleChange(title)
						}
					},
					closeSurface: { _, _ in },
					confirmReadClipboard: { userdata, string, opaquePtr, request in
						guard let userdata,
						      let opaquePtr,
						      let view = GhosttySurfaceUserdata.object(fromOpaque: userdata, as: MacTerminalView.self)
						else { return }
						Task { @MainActor [weak view] in
							view?.requestClipboardReadConfirmation(
								text: string,
								state: opaquePtr,
								request: request
							)
						}
					},
					writeClipboard: { userdata, _, string, confirm in
						guard confirm else {
							let write = {
								let pasteboard = NSPasteboard.general
								pasteboard.clearContents()
								pasteboard.setString(string, forType: .string)
							}
							if Thread.isMainThread {
								write()
							} else {
								DispatchQueue.main.async(execute: write)
							}
							return
						}
						guard let userdata,
						      let view = GhosttySurfaceUserdata.object(fromOpaque: userdata, as: MacTerminalView.self)
						else { return }
						Task { @MainActor [weak view] in
							view?.requestClipboardWriteConfirmation(text: string)
						}
					},
					readClipboard: { userdata, clipboard, opaquePtr in
						// Run on whatever thread ghostty called us from. See
						// MacClipboardBridge.readClipboardStringMirroringProduction for why
						// we don't hop to main: a sync hop deadlocks against ghostty's
						// own main-thread paste processing.
						guard clipboard == GHOSTTY_CLIPBOARD_STANDARD,
						      let userdata,
						      let opaquePtr
						else { return false }
						let view = Unmanaged<MacTerminalView>.fromOpaque(userdata).takeUnretainedValue()
						guard let surface = view.surface,
						      let string = MacClipboardBridge.readClipboardStringMirroringProduction(),
						      !string.isEmpty
						else { return false }
						string.withCString { cString in
							ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, true)
						}
						return true
					}
				)
			)
		}

		static func buildConfigText(theme: TerminalTheme) -> String {
			GhosttyConfigBuilder.buildConfigText(theme: theme)
		}

		func tick() {
			runtime?.tick()
		}

		func makeSurfaceUserdata(payload: UnsafeMutableRawPointer?, object: AnyObject? = nil) -> GhosttySurfaceUserdata? {
			runtime?.makeSurfaceUserdata(payload: payload, object: object)
		}

		func reloadConfig(theme: TerminalTheme? = nil) {
			let theme = theme ?? TerminalTheme.current
			_ = runtime?.updateConfig(text: Self.buildConfigText(theme: theme))
		}
	}
#endif
