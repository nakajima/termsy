#if os(macOS)
	import AppKit
	import TermsyGhosttyCore

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
						guard clipboard == GHOSTTY_CLIPBOARD_STANDARD,
						      let userdata,
						      let opaquePtr
						else { return false }

						let fulfillClipboardRequest = {
							let view = Unmanaged<MacTerminalView>.fromOpaque(userdata).takeUnretainedValue()
							guard let surface = view.surface,
							      let string = NSPasteboard.general.string(forType: .string),
							      !string.isEmpty
							else { return false }

							string.withCString { cString in
								ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, true)
							}
							return true
						}

						if Thread.isMainThread {
							return fulfillClipboardRequest()
						}

						return DispatchQueue.main.sync(execute: fulfillClipboardRequest)
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
