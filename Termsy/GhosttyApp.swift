//
//  GhosttyApp.swift
//  Termsy
//
//  Manages shared Ghostty configuration state.
//

#if canImport(UIKit)
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
		GhosttyConfigBuilder.buildConfigText(theme: theme)
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

		rt.wakeup_cb = { userdata in
			guard let userdata else { return }
			DispatchQueue.main.async {
				let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
				app.tick()
			}
		}

		rt.action_cb = { _, target, action in
			guard target.tag == GHOSTTY_TARGET_SURFACE,
			      let surface = target.target.surface,
			      let userdata = ghostty_surface_userdata(surface)
			else { return false }
			guard action.tag == GHOSTTY_ACTION_SET_TITLE,
			      let cTitle = action.action.set_title.title
			else { return false }
			let title = String(cString: cTitle)
			DispatchQueue.main.async {
				let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
				view.handleTitleChange(title)
			}
			return false
		}

		rt.close_surface_cb = { _, _ in }

		rt.write_clipboard_cb = { _, _, contents, contentsLen, _ in
			guard contentsLen > 0, let content = contents?.pointee,
			      let data = content.data
			else { return }
			let string = String(cString: data)
			DispatchQueue.main.async {
				UIPasteboard.general.string = string
			}
		}
		rt.read_clipboard_cb = { userdata, clipboard, opaquePtr in
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

		self.app = ghostty_app_new(&rt, cfg)
	}

	func tick() {
		guard let app else { return }
		ghostty_app_tick(app)
	}

	func applyTheme(_ theme: TerminalTheme) {
		reloadConfig(theme: theme)
	}

	func reloadConfig(theme: TerminalTheme? = nil) {
		guard let app else { return }
		let theme = theme ?? TerminalTheme.current
		guard let cfg = Self.loadConfig(theme: theme) else { return }
		if let old = config { ghostty_config_free(old) }
		config = cfg
		ghostty_app_update_config(app, cfg)
	}
}
#elseif canImport(AppKit) && canImport(GhosttyTerminal)
import Foundation
import GhosttyTerminal

@MainActor
final class GhosttyApp {
	static let shared = GhosttyApp()

	private let controllers = NSHashTable<TerminalController>.weakObjects()

	private init() {}

	static func buildConfigText(theme: TerminalTheme) -> String {
		GhosttyConfigBuilder.buildConfigText(theme: theme)
	}

	func register(_ controller: TerminalController) {
		controllers.add(controller)
		let source = TerminalController.ConfigSource.generated(Self.buildConfigText(theme: TerminalTheme.current))
		controller.updateConfigSource(source)
	}

	func unregister(_ controller: TerminalController) {
		controllers.remove(controller)
	}

	func applyTheme(_ theme: TerminalTheme) {
		reloadConfig(theme: theme)
	}

	func reloadConfig(theme: TerminalTheme? = nil) {
		let source = TerminalController.ConfigSource.generated(Self.buildConfigText(theme: theme ?? TerminalTheme.current))
		for controller in controllers.allObjects {
			controller.updateConfigSource(source)
		}
	}
}
#elseif canImport(AppKit)
import Foundation

@MainActor
final class GhosttyApp {
	static let shared = GhosttyApp()

	private init() {}

	static func buildConfigText(theme: TerminalTheme) -> String {
		GhosttyConfigBuilder.buildConfigText(theme: theme)
	}

	func applyTheme(_ theme: TerminalTheme) {}
	func reloadConfig(theme: TerminalTheme? = nil) {}
}
#endif
