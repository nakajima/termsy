//
//  GhosttyApp.swift
//  Termsy
//
//  Manages shared Ghostty configuration state.
//

#if canImport(UIKit)
	import TermsyGhosttyCore
	import UIKit

	@MainActor
	final class GhosttyApp {
		static let shared = GhosttyApp()

		private var runtime: GhosttyRuntime?

		private static func buildConfigText(theme: TerminalTheme) -> String {
			GhosttyConfigBuilder.buildConfigText(theme: theme)
		}

		var app: ghostty_app_t? {
			runtime?.app
		}

		private init() {
			let savedTheme = TerminalTheme(rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? "") ?? .mocha
			self.runtime = GhosttyRuntime(
				initialConfigText: Self.buildConfigText(theme: savedTheme),
				supportsSelectionClipboard: false,
				handlers: .init(
					wakeup: { [weak self] in
						DispatchQueue.main.async {
							self?.tick()
						}
					},
					action: { target, action in
						guard target.tag == GHOSTTY_TARGET_SURFACE,
						      let surface = target.target.surface,
						      let view = GhosttySurfaceUserdata.object(fromOpaque: ghostty_surface_userdata(surface), as: TerminalView.self),
						      action.tag == GHOSTTY_ACTION_SET_TITLE,
						      let cTitle = action.action.set_title.title
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
						      let view = GhosttySurfaceUserdata.object(fromOpaque: userdata, as: TerminalView.self)
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
							DispatchQueue.main.async {
								UIPasteboard.general.string = string
							}
							return
						}
						guard let userdata,
						      let view = GhosttySurfaceUserdata.object(fromOpaque: userdata, as: TerminalView.self)
						else { return }
						Task { @MainActor [weak view] in
							view?.requestClipboardWriteConfirmation(text: string)
						}
					},
					readClipboard: { userdata, clipboard, opaquePtr in
						guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return false }
						guard let userdata, let opaquePtr else { return false }
						guard ClipboardAccessAuthorization.consumeUserInitiatedPaste(for: userdata) else {
							return false
						}
						let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
						guard let surface = view.surface,
						      let string = UIPasteboard.general.string,
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

		func tick() {
			runtime?.tick()
		}

		func setFocused(_ isFocused: Bool) {
			guard let app else {
				DiagnosticLogStore.shared.record("ghosttyApp.setFocused.skipped", metadata: ["focused": isFocused])
				return
			}
			DiagnosticLogStore.shared.record("ghosttyApp.setFocused", metadata: ["focused": isFocused])
			ghostty_app_set_focus(app, isFocused)
		}

		func makeSurfaceUserdata(payload: UnsafeMutableRawPointer?, object: AnyObject? = nil) -> GhosttySurfaceUserdata? {
			runtime?.makeSurfaceUserdata(payload: payload, object: object)
		}

		func applyTheme(_ theme: TerminalTheme) {
			reloadConfig(theme: theme)
		}

		func reloadConfig(theme: TerminalTheme? = nil) {
			let theme = theme ?? TerminalTheme.current
			_ = runtime?.updateConfig(text: Self.buildConfigText(theme: theme))
		}
	}
#endif
