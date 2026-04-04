//
//  GhosttyApp.swift
//  Termsy
//
//  Manages the ghostty_app_t lifecycle. One instance per process.
//

import GhosttyKit
import UIKit

@MainActor
final class GhosttyApp {
	static let shared = GhosttyApp()

	private(set) var app: ghostty_app_t?
	private var config: ghostty_config_t?

	private static let configURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("termsy-ghostty.conf")

	private static func buildConfigText(theme: TerminalTheme) -> String {
		let cursorStyle = UserDefaults.standard.string(forKey: "cursorStyle") ?? "block"
		let cursorBlink = UserDefaults.standard.object(forKey: "cursorBlink") as? Bool ?? true
		return """
		font-size = 14
		cursor-style = \(cursorStyle)
		cursor-style-blink = \(cursorBlink)
		term = xterm-256color
		\(theme.ghosttyConfig)
		"""
	}

	private static func loadConfig(theme: TerminalTheme) -> ghostty_config_t? {
		guard let cfg = ghostty_config_new() else { return nil }
		let text = buildConfigText(theme: theme)
		try? text.write(to: configURL, atomically: true, encoding: .utf8)
		ghostty_config_load_file(cfg, configURL.path)
		ghostty_config_finalize(cfg)
		return cfg
	}

	private init() {
		ghostty_init(0, nil)

		let savedTheme = TerminalTheme(rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? "") ?? .mocha
		guard let cfg = Self.loadConfig(theme: savedTheme) else { return }
		self.config = cfg

		let userdata = Unmanaged.passUnretained(self).toOpaque()

		var rt = ghostty_runtime_config_s()
		rt.userdata = userdata
		rt.supports_selection_clipboard = false

		// Wakeup: Ghostty signals from its thread that a frame is ready.
		// Dispatch tick to main thread (same pattern as GhosttyTerminal).
		rt.wakeup_cb = { userdata in
			guard let userdata else { return }
			DispatchQueue.main.async {
				let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
				app.tick()
			}
		}

		// Action: route to the surface's userdata (our TermsyTerminalView).
		rt.action_cb = { _, target, _ in
			guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
			// We could handle SET_TITLE, CELL_SIZE etc. here if needed.
			return false
		}

		// Close surface callback — userdata is the surface's userdata (our view).
		rt.close_surface_cb = { _, _ in
			// No-op for now; SSH disconnect handles cleanup.
		}

		// Clipboard
		rt.write_clipboard_cb = { _, _, contents, contentsLen, _ in
			guard contentsLen > 0, let content = contents?.pointee,
			      let data = content.data
			else { return }
			UIPasteboard.general.string = String(cString: data)
		}
		rt.read_clipboard_cb = { userdata, _, opaquePtr in
			guard let userdata, let opaquePtr else { return false }
			guard let surfacePtr = ghostty_surface_userdata(
				Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue().app!
			) else { return false }
			// Simplified: not implementing full clipboard read for now.
			return false
		}

		self.app = ghostty_app_new(&rt, cfg)
	}

	func tick() {
		guard let app else { return }
		ghostty_app_tick(app)
	}

	func applyTheme(_ theme: TerminalTheme) {
		reloadConfig(theme: theme)
	}

	/// Reloads the full config from current UserDefaults + the given theme.
	func reloadConfig(theme: TerminalTheme? = nil) {
		guard let app else { return }
		let theme = theme ?? TerminalTheme.current
		guard let cfg = Self.loadConfig(theme: theme) else { return }
		if let old = config { ghostty_config_free(old) }
		config = cfg
		ghostty_app_update_config(app, cfg)
	}
}
