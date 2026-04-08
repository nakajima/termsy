#if os(macOS)
import AppKit
import SwiftUI

extension Notification.Name {
	static let termsyPresentSSHSessionSheet = Notification.Name("TermsyPresentSSHSessionSheet")
}

struct MacWindowAccessor: NSViewRepresentable {
	@Binding var window: NSWindow?

	func makeNSView(context _: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			window = view.window
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context _: Context) {
		DispatchQueue.main.async {
			window = nsView.window
		}
	}
}
#endif
