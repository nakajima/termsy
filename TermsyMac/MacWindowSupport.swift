#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacNativeTabCoordinator {
	static let shared = MacNativeTabCoordinator()
	static let tabbingIdentifier = "fm.folder.Termsy.terminal"

	private weak var pendingHostWindow: NSWindow?

	private init() {}

	func prepareForNewTab(from window: NSWindow?) {
		pendingHostWindow = window
	}

	func attachIfNeeded(to window: NSWindow) {
		window.tabbingMode = .preferred
		window.tabbingIdentifier = Self.tabbingIdentifier

		guard let hostWindow = pendingHostWindow, hostWindow !== window else {
			pendingHostWindow = nil
			return
		}

		pendingHostWindow = nil
		hostWindow.tabbingMode = .preferred
		hostWindow.tabbingIdentifier = Self.tabbingIdentifier

		DispatchQueue.main.async {
			guard hostWindow !== window else { return }
			hostWindow.addTabbedWindow(window, ordered: .above)
			window.makeKeyAndOrderFront(nil)
		}
	}
}

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
