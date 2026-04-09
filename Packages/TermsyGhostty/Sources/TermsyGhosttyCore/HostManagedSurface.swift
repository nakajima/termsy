import Foundation

public struct HostManagedSurfaceResize: Sendable, Equatable {
	public let columns: UInt16
	public let rows: UInt16
	public let pixelWidth: UInt32
	public let pixelHeight: UInt32

	public init(columns: UInt16, rows: UInt16, pixelWidth: UInt32, pixelHeight: UInt32) {
		self.columns = columns
		self.rows = rows
		self.pixelWidth = pixelWidth
		self.pixelHeight = pixelHeight
	}
}

private final class HostManagedSurfaceCallbackBox {
	let onData: (Data) -> Void
	let onResize: (HostManagedSurfaceResize) -> Void

	init(
		onData: @escaping (Data) -> Void,
		onResize: @escaping (HostManagedSurfaceResize) -> Void
	) {
		self.onData = onData
		self.onResize = onResize
	}
}

public final class HostManagedSurface {
	public private(set) var rawValue: ghostty_surface_t?
	private let callbackBox: HostManagedSurfaceCallbackBox

	public init(
		onData: @escaping (Data) -> Void,
		onResize: @escaping (HostManagedSurfaceResize) -> Void
	) {
		self.callbackBox = HostManagedSurfaceCallbackBox(
			onData: onData,
			onResize: onResize
		)
	}

	@discardableResult
	public func start(
		app: ghostty_app_t,
		surfaceUserdata: UnsafeMutableRawPointer?,
		scaleFactor: Double,
		fontSize: Float,
		configure: (inout ghostty_surface_config_s) -> Void
	) -> ghostty_surface_t? {
		if let rawValue {
			return rawValue
		}

		var config = ghostty_surface_config_new()
		configure(&config)
		config.userdata = surfaceUserdata
		config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
		config.receive_userdata = Unmanaged.passUnretained(callbackBox).toOpaque()
		config.receive_buffer = Self.receiveBufferCallback
		config.receive_resize = Self.receiveResizeCallback
		config.scale_factor = scaleFactor
		config.font_size = fontSize

		let surface = ghostty_surface_new(app, &config)
		rawValue = surface
		return surface
	}

	public func write(_ data: Data) {
		guard let rawValue, !data.isEmpty else { return }
		data.withUnsafeBytes { buffer in
			guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			ghostty_surface_write_buffer(rawValue, ptr, UInt(buffer.count))
		}
	}

	public func processExit(code: UInt32 = 0, runtimeMs: UInt64 = 0) {
		guard let rawValue else { return }
		ghostty_surface_process_exit(rawValue, code, runtimeMs)
	}

	public func free() {
		guard let rawValue else { return }
		ghostty_surface_free(rawValue)
		self.rawValue = nil
	}

	private static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
		guard let userdata, let ptr else { return }
		let callbackBox = Unmanaged<HostManagedSurfaceCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
		let data = Data(bytes: ptr, count: len)
		callbackBox.onData(data)
	}

	private static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
		guard let userdata else { return }
		let callbackBox = Unmanaged<HostManagedSurfaceCallbackBox>.fromOpaque(userdata).takeUnretainedValue()
		let resize = HostManagedSurfaceResize(
			columns: cols,
			rows: rows,
			pixelWidth: widthPx,
			pixelHeight: heightPx
		)
		callbackBox.onResize(resize)
	}
}
