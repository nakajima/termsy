import Foundation

private final class GhosttyRuntimeCallbackBox {
	let handlers: GhosttyRuntime.Handlers

	init(handlers: GhosttyRuntime.Handlers) {
		self.handlers = handlers
	}
}

public final class GhosttySurfaceUserdata {
	public let payload: UnsafeMutableRawPointer?
	fileprivate weak var payloadObject: AnyObject?
	fileprivate let callbackBox: GhosttyRuntimeCallbackBox

	fileprivate init(
		payload: UnsafeMutableRawPointer?,
		payloadObject: AnyObject?,
		callbackBox: GhosttyRuntimeCallbackBox
	) {
		self.payload = payload
		self.payloadObject = payloadObject
		self.callbackBox = callbackBox
	}

	public var opaquePointer: UnsafeMutableRawPointer {
		Unmanaged.passUnretained(self).toOpaque()
	}

	public static func payload(fromOpaque userdata: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
		guard let userdata else { return nil }
		return Unmanaged<GhosttySurfaceUserdata>.fromOpaque(userdata).takeUnretainedValue().payload
	}

	public static func object<T: AnyObject>(fromOpaque userdata: UnsafeMutableRawPointer?, as _: T.Type = T.self) -> T? {
		guard let userdata else { return nil }
		return Unmanaged<GhosttySurfaceUserdata>.fromOpaque(userdata).takeUnretainedValue().payloadObject as? T
	}

	fileprivate static func callbackBox(fromOpaque userdata: UnsafeMutableRawPointer?) -> GhosttyRuntimeCallbackBox? {
		guard let userdata else { return nil }
		return Unmanaged<GhosttySurfaceUserdata>.fromOpaque(userdata).takeUnretainedValue().callbackBox
	}
}

public final class GhosttyRuntime {
	public struct Handlers {
		public var wakeup: () -> Void
		public var action: (ghostty_target_s, ghostty_action_s) -> Void
		public var closeSurface: (UnsafeMutableRawPointer?, Bool) -> Void
		public var confirmReadClipboard: (UnsafeMutableRawPointer?, String, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void
		public var writeClipboard: (UnsafeMutableRawPointer?, ghostty_clipboard_e, String, Bool) -> Void
		public var readClipboard: (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool

		public init(
			wakeup: @escaping () -> Void = {},
			action: @escaping (ghostty_target_s, ghostty_action_s) -> Void = { _, _ in },
			closeSurface: @escaping (UnsafeMutableRawPointer?, Bool) -> Void = { _, _ in },
			confirmReadClipboard: @escaping (UnsafeMutableRawPointer?, String, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void = { _, _, _, _ in },
			writeClipboard: @escaping (UnsafeMutableRawPointer?, ghostty_clipboard_e, String, Bool) -> Void = { _, _, _, _ in },
			readClipboard: @escaping (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool = { _, _, _ in false }
		) {
			self.wakeup = wakeup
			self.action = action
			self.closeSurface = closeSurface
			self.confirmReadClipboard = confirmReadClipboard
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
			guard let callbackBox = GhosttySurfaceUserdata.callbackBox(fromOpaque: userdata) else { return }
			callbackBox.handlers.closeSurface(
				GhosttySurfaceUserdata.payload(fromOpaque: userdata),
				processAlive
			)
		}
		runtimeConfig.confirm_read_clipboard_cb = { userdata, string, opaquePtr, request in
			guard let callbackBox = GhosttySurfaceUserdata.callbackBox(fromOpaque: userdata),
			      let string,
			      let value = String(validatingUTF8: string)
			else { return }
			callbackBox.handlers.confirmReadClipboard(
				GhosttySurfaceUserdata.payload(fromOpaque: userdata),
				value,
				opaquePtr,
				request
			)
		}
		runtimeConfig.write_clipboard_cb = { userdata, clipboard, contents, contentsLen, confirm in
			guard let callbackBox = GhosttySurfaceUserdata.callbackBox(fromOpaque: userdata),
			      contentsLen > 0,
			      let content = contents?.pointee,
			      let data = content.data
			else { return }
			let string = String(cString: data)
			callbackBox.handlers.writeClipboard(
				GhosttySurfaceUserdata.payload(fromOpaque: userdata),
				clipboard,
				string,
				confirm
			)
		}
		runtimeConfig.read_clipboard_cb = { userdata, clipboard, opaquePtr in
			guard let callbackBox = GhosttySurfaceUserdata.callbackBox(fromOpaque: userdata) else {
				return false
			}
			return callbackBox.handlers.readClipboard(
				GhosttySurfaceUserdata.payload(fromOpaque: userdata),
				clipboard,
				opaquePtr
			)
		}

		self.app = ghostty_app_new(&runtimeConfig, cfg)
	}

	public func makeSurfaceUserdata(
		payload: UnsafeMutableRawPointer?,
		object: AnyObject? = nil
	) -> GhosttySurfaceUserdata {
		GhosttySurfaceUserdata(payload: payload, payloadObject: object, callbackBox: callbackBox)
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
