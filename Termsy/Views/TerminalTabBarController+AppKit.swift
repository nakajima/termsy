#if canImport(AppKit) && !canImport(UIKit)
	import AppKit
	import SwiftUI

	struct TerminalHostRepresentable: NSViewControllerRepresentable {
		@Environment(\.appTheme) private var theme
		let tab: TerminalTab

		func makeNSViewController(context _: Context) -> TerminalHostController {
			TerminalHostController(terminalTab: tab, theme: theme)
		}

		func updateNSViewController(_ controller: TerminalHostController, context _: Context) {
			controller.applyTheme(theme)
		}

		static func dismantleNSViewController(_ controller: TerminalHostController, coordinator _: ()) {
			controller.teardownTerminal()
		}
	}

	@MainActor
	final class TerminalHostController: NSViewController {
		let terminalTab: TerminalTab
		private var theme: AppTheme
		private var terminalView: TerminalView?
		private var overlayHostController: NSHostingController<AnyView>?

		init(terminalTab: TerminalTab, theme: AppTheme) {
			self.terminalTab = terminalTab
			self.theme = theme
			super.init(nibName: nil, bundle: nil)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) { fatalError() }

		override func loadView() {
			view = NSView()
		}

		override func viewDidLoad() {
			super.viewDidLoad()
			terminalTab.onOverlayStateChange = { [weak self] in
				self?.updateOverlay()
			}
			terminalTab.onTerminalViewReplacementRequested = { [weak self] in
				self?.reloadTerminalView()
			}
			applyTheme(theme)
			setupTerminal()
		}

		override func viewDidAppear() {
			super.viewDidAppear()
			if terminalView == nil {
				setupTerminal()
			}
			_ = terminalView?.syncSizeAndReadBack()
			terminalTab.hostDidAppear()
		}

		override func viewDidLayout() {
			super.viewDidLayout()
			syncTerminalSizeToSession()
		}

		func applyTheme(_ theme: AppTheme) {
			self.theme = theme
			view.wantsLayer = true
			view.layer?.backgroundColor = theme.backgroundUIColor.cgColor
			terminalTab.applyTheme(theme)
			updateOverlay()
		}

		func setupTerminal() {
			guard terminalView == nil else { return }

			let tv = terminalTab.terminalView
			tv.frame = view.bounds
			tv.autoresizingMask = [.width, .height]
			tv.applyTheme(theme)
			tv.removeFromSuperview()
			if let overlayView = overlayHostController?.view {
				view.addSubview(tv, positioned: .below, relativeTo: overlayView)
			} else {
				view.addSubview(tv)
			}
			terminalView = tv
			syncTerminalSizeToSession()
			terminalTab.renderPendingPreviewIfNeeded()
			updateOverlay()
		}

		func teardownTerminal() {
			terminalTab.setDisplayActive(false)
			terminalTab.onOverlayStateChange = nil
			terminalTab.onTerminalViewReplacementRequested = nil
			terminalView?.removeFromSuperview()
			terminalView = nil
		}

		private func reloadTerminalView() {
			guard isViewLoaded else { return }
			terminalView?.removeFromSuperview()
			terminalView = nil
			setupTerminal()
			_ = terminalView?.syncSizeAndReadBack()
			terminalTab.hostDidAppear()
		}

		private func updateOverlay() {
			let overlayView = TerminalOverlay(
				tab: terminalTab,
				onReconnect: { [weak terminalTab] in
					terminalTab?.retryConnection()
				},
				onRetryWithPassword: { [weak self] password in
					guard let self else { return }
					Task {
						await self.terminalTab.connectWithPassword(password)
						self.syncTerminalSizeToSession()
						self.updateOverlay()
					}
				}
			)
			.environment(\.appTheme, theme)

			let overlayNeedsInteraction = terminalTab.showsOverlay

			if let existing = overlayHostController {
				existing.rootView = AnyView(overlayView)
				existing.view.isHidden = !overlayNeedsInteraction
			} else {
				let host = NSHostingController(rootView: AnyView(overlayView))
				host.view.wantsLayer = true
				host.view.layer?.backgroundColor = NSColor.clear.cgColor
				host.view.frame = view.bounds
				host.view.autoresizingMask = [.width, .height]
				host.view.isHidden = !overlayNeedsInteraction
				addChild(host)
				view.addSubview(host.view)
				overlayHostController = host
			}
		}

		private func syncTerminalSizeToSession() {
			guard let terminalView else { return }
			terminalView.frame = view.bounds
			guard let size = terminalView.syncSizeAndReadBack() else { return }
			terminalTab.updateTerminalSize(size)
		}
	}
#endif
