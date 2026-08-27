import Foundation
import TermsyGhosttyCore
import Testing
import UIKit

extension TermsyTests {
	@MainActor
	@Test func labeledOSC8LinkEmitsOpenURLActionForTouchActivation() async throws {
		let capturedURL = LockedURL()
		let runtime = GhosttyRuntime(
			initialConfigText: "font-size = 14",
			handlers: .init(action: { _, action in
				guard action.tag == GHOSTTY_ACTION_OPEN_URL else { return false }
				let value = action.action.open_url
				guard value.len > 0, let pointer = value.url else { return false }
				let data = Data(bytes: pointer, count: Int(value.len))
				guard let string = String(data: data, encoding: .utf8),
				      let url = URL(string: string)
				else { return false }
				capturedURL.set(url)
				return true
			})
		)
		let app = try #require(runtime.app)
		let view = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
		let host = HostManagedSurface(onData: { _ in }, onResize: { _ in })
		let userdata = runtime.makeSurfaceUserdata(payload: nil, object: view)
		let surface = try #require(host.start(
			app: app,
			surfaceUserdata: userdata.opaquePointer,
			scaleFactor: 1,
			fontSize: 14
		) { config in
			config.platform_tag = GHOSTTY_PLATFORM_IOS
			config.platform = ghostty_platform_u(
				ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque())
			)
		})
		defer { host.free() }

		ghostty_surface_set_content_scale(surface, 1, 1)
		ghostty_surface_set_size(surface, 800, 600)
		let expectedURL = try #require(URL(string: "https://example.com/osc8-destination"))
		let text = "\u{1B}]8;;\(expectedURL.absoluteString)\u{1B}\\Open labeled link\u{1B}]8;;\u{1B}\\"
		host.write(Data(text.utf8))

		for _ in 0 ..< 20 {
			runtime.tick()
			ghostty_surface_refresh(surface)
			try await Task.sleep(for: .milliseconds(10))
		}

		let size = ghostty_surface_size(surface)
		let point = CGPoint(
			x: CGFloat(size.cell_width_px) * 2,
			y: CGFloat(size.cell_height_px) / 2
		)
		ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_SUPER)
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)

		#expect(capturedURL.get() == expectedURL)
	}
}

private final class LockedURL: @unchecked Sendable {
	private let lock = NSLock()
	private var value: URL?

	func set(_ value: URL) {
		lock.lock()
		self.value = value
		lock.unlock()
	}

	func get() -> URL? {
		lock.lock()
		defer { lock.unlock() }
		return value
	}
}
