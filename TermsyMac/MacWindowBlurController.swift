#if os(macOS)
import AppKit
import Darwin

@MainActor
final class MacWindowBlurController {
	static let shared = MacWindowBlurController()

	private typealias DefaultConnectionFunction = @convention(c) () -> UnsafeMutableRawPointer?
	private typealias SetBlurRadiusFunction = @convention(c) (UnsafeMutableRawPointer?, Int, Int32) -> Int32

	private let skyLightHandle: UnsafeMutableRawPointer?
	private let defaultConnectionForThread: DefaultConnectionFunction?
	private let setWindowBackgroundBlurRadius: SetBlurRadiusFunction?

	private init() {
		skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

		if let skyLightHandle,
		   let symbol = dlsym(skyLightHandle, "CGSDefaultConnectionForThread") {
			defaultConnectionForThread = unsafeBitCast(symbol, to: DefaultConnectionFunction.self)
		} else {
			defaultConnectionForThread = nil
		}

		if let skyLightHandle,
		   let symbol = dlsym(skyLightHandle, "CGSSetWindowBackgroundBlurRadius") {
			setWindowBackgroundBlurRadius = unsafeBitCast(symbol, to: SetBlurRadiusFunction.self)
		} else {
			setWindowBackgroundBlurRadius = nil
		}
	}

	func applyBlur(mode: TerminalBackgroundBlurSettings, opacity: Double, to window: NSWindow) {
		guard let defaultConnectionForThread, let setWindowBackgroundBlurRadius else { return }
		guard window.windowNumber > 0 else { return }

		let radius = opacity < 0.999 ? mode.blurRadius : 0
		let connection = defaultConnectionForThread()
		_ = setWindowBackgroundBlurRadius(connection, window.windowNumber, Int32(radius))
	}
}
#endif
