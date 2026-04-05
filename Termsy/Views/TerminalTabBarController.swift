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

	static func dismantleUIViewcontroller(_ controller: TerminalHostController, coordinator: ()) {
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
		applyTheme(theme)
		setupTerminal()
		connectIfNeeded()

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
		if terminalTab.sshSession.isForeground {
			Task { await terminalTab.sshSession.replayIfNeeded() }
		}
		terminalView?.becomeFirstResponder()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		terminalView?.frame = view.bounds
		terminalView?.forceSyncSize()
	}

	func applyTheme(_ theme: AppTheme) {
		self.theme = theme
		view.backgroundColor = theme.backgroundUIColor
		terminalView?.applyTheme(theme)
		updateOverlay()
	}

	func setupTerminal() {
		guard terminalView == nil else { return }

		let tv = TerminalView(frame: view.bounds)
		tv.applyTheme(theme)
		tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		tv.onCloseTabRequest = { [weak self] in
			self?.terminalTab.requestClose()
		}
		tv.onNewTabRequest = { [weak self] in
			self?.terminalTab.requestNewTab()
		}
		tv.onWrite = { [weak self] data in
			self?.terminalTab.sshSession.connection.send(data)
		}
		tv.onResize = { [weak self] cols, rows in
			guard let self else { return }
			let c = Int(cols), r = Int(rows)
			self.terminalTab.sshSession.lastCols = c
			self.terminalTab.sshSession.lastRows = r
			self.terminalTab.sshSession.connection.resize(cols: c, rows: r)
		}
		view.addSubview(tv)
		terminalTab.sshSession.terminalView = tv
		terminalView = tv
		updateOverlay()
	}

	func teardownTerminal() {
		terminalView?.stop()
		terminalView?.removeFromSuperview()
		terminalView = nil
		terminalTab.sshSession.terminalView = nil
	}

	private func connectIfNeeded() {
		guard !terminalTab.isConnected, terminalTab.connectionError == nil, !terminalTab.needsPassword else { return }
		connectTask = Task { [weak self] in
			guard let self else { return }
			await self.terminalTab.connect()
			self.updateOverlay()
		}
	}

	private func updateOverlay() {
		let overlayView = TerminalOverlay(tab: terminalTab, onRetryWithPassword: { [weak self] password in
			guard let self else { return }
			Task {
				await self.terminalTab.connectWithPassword(password)
				self.updateOverlay()
			}
		})
		.environment(\.appTheme, theme)

		if let existing = overlayHostController {
			existing.rootView = AnyView(overlayView)
		} else {
			let host = UIHostingController(rootView: AnyView(overlayView))
			host.view.backgroundColor = .clear
			host.view.frame = view.bounds
			host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			addChild(host)
			view.addSubview(host.view)
			host.didMove(toParent: self)
			overlayHostController = host
		}
	}

	@objc private func appDidBecomeActive() {
		guard terminalTab.isConnected, !terminalTab.sshSession.connection.isActive else { return }
		print("[SSH] connection lost while backgrounded, reconnecting...")
		terminalTab.isConnected = false
		terminalTab.connectionError = nil
		teardownTerminal()
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
	var onRetryWithPassword: (String) -> Void

	@State private var password = ""

	var body: some View {
		ZStack {
			if !tab.isConnected, tab.connectionError == nil, !tab.needsPassword {
				theme.background
				ProgressView("Connecting to \(tab.session.hostname)…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if tab.sshSession.isReplaying {
				theme.background
				ProgressView("Restoring session…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if let error = tab.connectionError {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(theme.error)
					Text("Connection Failed")
						.font(.headline)
						.foregroundStyle(theme.primaryText)
					Text(error)
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
						.multilineTextAlignment(.center)
				}
				.padding()
				.background(theme.cardBackground, in: .rect(cornerRadius: 12))
				.overlay {
					RoundedRectangle(cornerRadius: 12)
						.stroke(theme.divider, lineWidth: 1)
				}
			}
		}
		.allowsHitTesting(!tab.isConnected || tab.connectionError != nil || tab.sshSession.isReplaying)
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
	return TerminalOverlay(tab: tab, onRetryWithPassword: { _ in })
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
