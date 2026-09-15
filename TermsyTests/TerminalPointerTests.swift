import Foundation
@testable import Termsy
import TermsyGhosttyCore
import Testing
import UIKit

extension TermsyTests {
	@MainActor
	@Test(arguments: [false, true], [false, true])
	func shiftPointerDragSelectsLocally(applicationCapturesShift: Bool, cancelled: Bool) async throws {
		let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
		let output = PointerOutputRecorder()
		view.delegate = output
		view.start()
		defer { view.stop() }
		let surface = try #require(view.surface)
		ghostty_surface_set_content_scale(surface, 1, 1)
		ghostty_surface_set_size(surface, 800, 600)
		view.feedData(Data("hello world\u{1B}[?1002h\u{1B}[?1006h\u{1B}[>\(applicationCapturesShift ? 1 : 0)s".utf8))
		try await waitForPointerIO(surface)
		#expect(ghostty_surface_mouse_captured(surface))
		output.data.removeAll()

		let size = ghostty_surface_size(surface)
		let touch = PointerTouch(point: CGPoint(x: CGFloat(size.cell_width_px) / 4, y: CGFloat(size.cell_height_px) / 2))
		let event = PointerEvent(modifiers: .shift)
		view.touchesBegan([touch], with: event)
		touch.point.x += CGFloat(size.cell_width_px) * 5
		view.touchesMoved([touch], with: event)
		if cancelled {
			view.touchesCancelled([touch], with: event)
		} else {
			view.touchesEnded([touch], with: event)
		}
		try await waitForPointerIO(surface)

		#expect(output.data.isEmpty)
		var selection = ghostty_text_s()
		try #require(ghostty_surface_read_selection(surface, &selection))
		defer { ghostty_surface_free_text(surface, &selection) }
		let text = try #require(selection.text)
		#expect(String(cString: text) == "hello")

		// Releasing Shift restores reporting to the terminal program.
		let unmodified = PointerEvent(modifiers: [])
		view.touchesBegan([touch], with: unmodified)
		touch.point.x += CGFloat(size.cell_width_px) * 2
		view.touchesMoved([touch], with: unmodified)
		view.touchesEnded([touch], with: unmodified)
		try await waitForPointerIO(surface)
		let reports = String(decoding: output.data, as: UTF8.self)
		#expect(reports.contains("\u{1B}[<0;"))
		#expect(reports.contains("\u{1B}[<32;"))
		#expect(reports.hasSuffix("m"))
		#expect(!ghostty_surface_has_selection(surface))
	}

	@MainActor
	private func waitForPointerIO(_ surface: ghostty_surface_t) async throws {
		for _ in 0 ..< 20 {
			GhosttyApp.shared.tick()
			ghostty_surface_refresh(surface)
			try await Task.sleep(for: .milliseconds(10))
		}
	}
}

private final class PointerTouch: UITouch {
	var point: CGPoint

	init(point: CGPoint) {
		self.point = point
		super.init()
	}

	override var type: UITouch.TouchType { .indirectPointer }
	override func location(in _: UIView?) -> CGPoint { point }
}

private final class PointerEvent: UIEvent {
	let modifiers: UIKeyModifierFlags

	init(modifiers: UIKeyModifierFlags) {
		self.modifiers = modifiers
		super.init()
	}

	override var modifierFlags: UIKeyModifierFlags { modifiers }
	override var buttonMask: UIEvent.ButtonMask { .primary }
}

@MainActor
private final class PointerOutputRecorder: TerminalViewDelegate {
	var data = Data()

	func terminalView(_: TerminalView, didWrite data: Data) { self.data.append(data) }
	func terminalViewDidResize(_: TerminalView) {}
	func terminalView(_: TerminalView, didReportTitle _: String) {}
	func terminalViewRequestsCloseTab(_: TerminalView) {}
	func terminalViewRequestsNewTab(_: TerminalView) {}
	func terminalView(_: TerminalView, requestsSelectTab _: Int) {}
	func terminalView(_: TerminalView, requestsMoveTabSelectionBy _: Int) {}
	func terminalViewRequestsShowSettings(_: TerminalView) {}
	func terminalViewShouldDismissAuxiliaryUI(_: TerminalView) -> Bool { false }
	func terminalView(_: TerminalView, didChangeFontSize _: Float) {}
	func terminalView(_: TerminalView, didReceiveFileDropURLs _: [URL]) {}
	func terminalView(_: TerminalView, didFailFileDropWithMessage _: String) {}
}
