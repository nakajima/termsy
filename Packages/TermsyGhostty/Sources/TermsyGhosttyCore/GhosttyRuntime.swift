import Foundation

private final class GhosttyRuntimeCallbackBox {
	let handlers: GhosttyRuntime.Handlers

	init(handlers: GhosttyRuntime.Handlers) {
		self.handlers = handlers
	}
}

public final class GhosttyRuntime {
	public struct Handlers {
		public var wakeup: () -> Void
		public var action: (ghostty_target_s, ghostty_action_s) -> Void
		public var closeSurface: (UnsafeMutableRawPointer?, Bool) -> Void
		public var writeClipboard: (ghostty_clipboard_e, String, Bool) -> Void
		public var readClipboard: (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool

		public init(
			wakeup: @escaping () -> Void = {},
			action: @escaping (ghostty_target_s, ghostty_action_s) -> Void = { _, _ in },
			closeSurface: @escaping (UnsafeMutableRawPointer?, Bool) -> Void = { _, _ in },
			writeClipboard: @escaping (ghostty_clipboard_e, String, Bool) -> Void = { _, _, _ in },
			readClipboard: @escaping (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool = { _, _, _ in false }
		) {
			self.wakeup = wakeup
			self.action = action
			self.closeSurface = closeSurface
			self.writeClipboard = writeClipboard
			self.readClipboard = readClipboard
		}
	}

	public private(set) var app: ghostty_app_t?
	private var config: ghostty_config_t?
	private let callbackBox: GhosttyRuntimeCallbackBox
	private let configURL: URL

	public init(
		initialConfigText: String,
		supportsSelectionClipboard: Bool = false,
		handlers: Handlers = .init(),
		configURL: URL? = nil
	) {
		ghostty_init(0, nil)

		self.callbackBox = GhosttyRuntimeCallbackBox(handlers: handlers)
		self.configURL = configURL ?? FileManager.default.temporaryDirectory
			.appendingPathComponent("termsy-ghostty-\(UUID().uuidString).conf")

		guard let cfg = Self.loadConfig(text: initialConfigText, url: self.configURL) else {
			return
		}
		self.config = cfg

		let callbackBox = self.callbackBox
		var runtimeConfig = ghostty_runtime_config_s()
		runtimeConfig.userdata = Unmanaged.passUnretained(callbackBox).toOpaque()
		runtimeConfig.supports_selection_clipboard = supportsSelectionClipboard
		runtimeConfig.wakeup_cb = { userdata in
			guard let userdata else { return }
			let callbackBox = Unmanaged<GhosttyRuntimeCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
			callbackBox.handlers.wakeup()
		}
		// action_cb receives the app pointer, not runtimeConfig.userdata.
		runtimeConfig.action_cb = { appPtr, target, action in
			guard let appPtr,
			      let userdata = ghostty_app_userdata(appPtr)
			else { return false }
			let callbackBox = Unmanaged<GhosttyRuntimeCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
			callbackBox.handlers.action(target, action)
			return false
		}
		runtimeConfig.close_surface_cb = { userdata, processAlive in
			guard let userdata else { return }
			let callbackBox = Unmanaged<GhosttyRuntimeCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
			callbackBox.handlers.closeSurface(userdata, processAlive)
		}
		runtimeConfig.write_clipboard_cb = { userdata, clipboard, contents, contentsLen, confirm in
			guard let userdata, contentsLen > 0, let content = contents?.pointee,
			      let data = content.data
			else { return }
			let callbackBox = Unmanaged<GhosttyRuntimeCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
			let string = String(cString: data)
			callbackBox.handlers.writeClipboard(clipboard, string, confirm)
		}
		runtimeConfig.read_clipboard_cb = { userdata, clipboard, opaquePtr in
			guard let userdata else { return false }
			let callbackBox = Unmanaged<GhosttyRuntimeCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
			return callbackBox.handlers.readClipboard(userdata, clipboard, opaquePtr)
		}

		self.app = ghostty_app_new(&runtimeConfig, cfg)
	}

	deinit {
		if let app {
			ghostty_app_free(app)
		}
		if let config {
			ghostty_config_free(config)
		}
		try? FileManager.default.removeItem(at: configURL)
	}

	public func tick() {
		guard let app else { return }
		ghostty_app_tick(app)
	}

	@discardableResult
	public func updateConfig(text: String) -> Bool {
		guard let app else { return false }
		guard let nextConfig = Self.loadConfig(text: text, url: configURL) else { return false }
		if let config {
			ghostty_config_free(config)
		}
		config = nextConfig
		ghostty_app_update_config(app, nextConfig)
		return true
	}

	private static func loadConfig(text: String, url: URL) -> ghostty_config_t? {
		guard let cfg = ghostty_config_new() else { return nil }
		do {
			try text.write(to: url, atomically: true, encoding: .utf8)
		} catch {
			ghostty_config_free(cfg)
			return nil
		}
		ghostty_config_load_file(cfg, url.path)
		ghostty_config_finalize(cfg)
		return cfg
	}
}
