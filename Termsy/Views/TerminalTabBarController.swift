//
//  TerminalTabBarController.swift
//  Termsy
//
//  UIViewController that hosts a terminal session.
//  Manages the TerminalView lifecycle — creates on appear, tears down on background.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Bridge

struct TerminalHostRepresentable: UIViewControllerRepresentable {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab

	func makeUIViewController(context: Context) -> TerminalHostController {
		TerminalHostController(terminalTab: tab, theme: theme)
	}

	func updateUIViewController(_ controller: TerminalHostController, context: Context) {
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
		connectIfNeeded()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appWillResignActive),
			name: UIApplication.willResignActiveNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appDidBecomeActive),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if terminalView == nil {
			setupTerminal()
		}
		terminalTab.setDisplayActive(true)
		_ = terminalView?.becomeFirstResponder()
		_ = terminalView?.syncSizeAndReadBack()
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
		terminalTab.setDisplayActive(true)
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

	@objc private func appWillResignActive() {
		terminalTab.noteAppWillResignActive()
		terminalTab.setDisplayActive(false)
	}

	@objc private func appDidBecomeActive() {
		terminalTab.noteAppDidBecomeActive()
		terminalTab.setDisplayActive(true)
		if terminalTab.consumeReconnectOnActivation() {
			reconnectAfterBackgroundLoss()
			return
		}
		guard terminalTab.isConnected else {
			terminalTab.clearAppInactiveState()
			return
		}
		guard terminalTab.sshSession.connection.isActive else {
			reconnectAfterBackgroundLoss()
			return
		}
		syncTerminalSizeToSession()
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

// MARK: - Overlay (connecting / error states)

struct TerminalOverlay: View {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab
	var onReconnect: () -> Void
	var onRetryWithPassword: (String) -> Void

	@State private var password = ""

	private var errorDescription: String {
		guard let error = tab.connectionError else { return "" }
		if error.localizedCaseInsensitiveContains("tcpShutdown")
			|| error.localizedCaseInsensitiveContains("tcp shutdown")
		{
			return "The SSH connection was dropped while the app was inactive."
		}
		return error
	}

	var body: some View {
		ZStack {
			if !tab.isConnected, tab.connectionError == nil, !tab.needsPassword {
				theme.background
				ProgressView("Connecting to \(tab.session.hostname)…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if tab.isRestoring {
				theme.background
				ProgressView("Restoring session…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if tab.connectionError != nil {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(theme.error)
					Text("Connection Failed")
						.font(.headline)
						.foregroundStyle(theme.primaryText)
					Text(errorDescription)
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
						.multilineTextAlignment(.center)
					Button {
						onReconnect()
					} label: {
						Label("Reconnect", systemImage: "arrow.clockwise")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.tint(theme.accent)
				}
				.padding()
				.background(theme.cardBackground, in: .rect(cornerRadius: 12))
				.overlay {
					RoundedRectangle(cornerRadius: 12)
						.stroke(theme.divider, lineWidth: 1)
				}
			}
		}
		.allowsHitTesting(!tab.isConnected || tab.connectionError != nil || tab.isRestoring)
		.alert("Password Required", isPresented: .init(
			get: { tab.needsPassword },
			set: { if !$0 { tab.needsPassword = false } }
		)) {
			SecureField("Password", text: $password)
			Button("Connect") {
				let pw = password
				password = ""
				onRetryWithPassword(pw)
			}
			Button("Cancel", role: .cancel) {
				password = ""
				tab.connectionError = "Authentication cancelled"
			}
		} message: {
			Text("\(tab.session.username)@\(tab.session.hostname)")
		}
	}
}

#Preview("Terminal Overlay Error") {
	let tab = TerminalTab(session: Session(
		id: 1,
		hostname: "example.local",
		username: "pat",
		port: 22,
		createdAt: Date()
	))
	tab.connectionError = "Host key verification failed"
	return TerminalOverlay(tab: tab, onReconnect: {}, onRetryWithPassword: { _ in })
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
