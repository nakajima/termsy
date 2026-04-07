//
//  TerminalTabBarController.swift
//  Termsy
//
//  UIViewController that hosts a terminal session.
//  Keeps a per-tab TerminalView mounted while the tab remains open.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Bridge

struct TerminalHostRepresentable: UIViewControllerRepresentable {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab
	let onConnectionEstablished: (Session) -> Void

	func makeUIViewController(context: Context) -> TerminalHostController {
		tab.onConnectionEstablished = onConnectionEstablished
		return TerminalHostController(terminalTab: tab, theme: theme)
	}

	func updateUIViewController(_ controller: TerminalHostController, context: Context) {
		tab.onConnectionEstablished = onConnectionEstablished
		controller.applyTheme(theme)
	}

	static func dismantleUIViewController(_ controller: TerminalHostController, coordinator: ()) {
		controller.teardownTerminal()
	}
}

// MARK: - Per-Tab Host Controller

@MainActor
final class TerminalHostController: UIViewController {
	let terminalTab: TerminalTab
	private var theme: AppTheme
	private var terminalView: TerminalView?
	private var overlayHostController: UIHostingController<AnyView>?
	private var connectTask: Task<Void, Never>?

	init(terminalTab: TerminalTab, theme: AppTheme) {
		self.terminalTab = terminalTab
		self.theme = theme
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()
		terminalTab.onRequestReconnect = { [weak self] in
			self?.reconnectAfterBackgroundLoss()
		}
		applyTheme(theme)
		setupTerminal()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if terminalView == nil {
			setupTerminal()
		}
		_ = terminalView?.syncSizeAndReadBack()
		restoreConnectionIfNeeded()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		syncTerminalSizeToSession()
	}

	func applyTheme(_ theme: AppTheme) {
		self.theme = theme
		view.backgroundColor = theme.backgroundUIColor
		terminalTab.applyTheme(theme)
		updateOverlay()
	}

	func setupTerminal() {
		guard terminalView == nil else { return }

		let tv = terminalTab.terminalView
		tv.frame = view.bounds
		tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		tv.applyTheme(theme)
		tv.removeFromSuperview()
		if let overlayView = overlayHostController?.view {
			view.insertSubview(tv, belowSubview: overlayView)
		} else {
			view.addSubview(tv)
		}
		terminalView = tv
		syncTerminalSizeToSession()
		updateOverlay()
	}

	func teardownTerminal() {
		terminalTab.setDisplayActive(false)
		terminalView?.removeFromSuperview()
		terminalView = nil
	}

	private func connectIfNeeded() {
		guard !terminalTab.isConnected, terminalTab.connectionError == nil, !terminalTab.needsPassword else { return }
		connectTask?.cancel()
		connectTask = Task { [weak self] in
			guard let self else { return }
			await self.terminalTab.connect()
			self.syncTerminalSizeToSession()
			self.updateOverlay()
		}
	}

	private func updateOverlay() {
		let overlayView = TerminalOverlay(
			tab: terminalTab,
			onReconnect: { [weak self] in
				self?.reconnectAfterBackgroundLoss()
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

		let overlayNeedsInteraction = !terminalTab.isConnected
			|| terminalTab.connectionError != nil
			|| terminalTab.isRestoring
			|| terminalTab.needsPassword

		if let existing = overlayHostController {
			existing.rootView = AnyView(overlayView)
			existing.view.isUserInteractionEnabled = overlayNeedsInteraction
		} else {
			let host = UIHostingController(rootView: AnyView(overlayView))
			host.view.backgroundColor = .clear
			host.view.frame = view.bounds
			host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			host.view.isUserInteractionEnabled = overlayNeedsInteraction
			addChild(host)
			view.addSubview(host.view)
			host.didMove(toParent: self)
			overlayHostController = host
		}
	}

	private func syncTerminalSizeToSession() {
		guard let terminalView else { return }
		terminalView.frame = view.bounds
		guard let size = terminalView.syncSizeAndReadBack() else { return }
		terminalTab.sshSession.updateTerminalSize(size)
	}

	private func restoreConnectionIfNeeded() {
		if terminalTab.consumeReconnectOnActivation() {
			reconnectAfterBackgroundLoss()
			return
		}
		if terminalTab.isConnected {
			guard terminalTab.sshSession.connection.isActive else {
				reconnectAfterBackgroundLoss()
				return
			}
			syncTerminalSizeToSession()
			return
		}
		connectIfNeeded()
	}

	private func reconnectAfterBackgroundLoss() {
		print("[SSH] reconnecting after app switch/background...")
		connectTask?.cancel()
		terminalTab.prepareForReconnectAfterBackgroundLoss()
		terminalView = nil
		setupTerminal()
		connectIfNeeded()
	}

	deinit {
		connectTask?.cancel()
	}
}

