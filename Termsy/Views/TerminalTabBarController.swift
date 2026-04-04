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
	let tab: TerminalTab

	func makeUIViewController(context: Context) -> TerminalHostController {
		TerminalHostController(terminalTab: tab)
	}

	func updateUIViewController(_ controller: TerminalHostController, context: Context) {}

	static func dismantleUIViewcontroller(_ controller: TerminalHostController, coordinator: ()) {
		controller.teardownTerminal()
	}
}

// MARK: - Per-Tab Host Controller

@MainActor
final class TerminalHostController: UIViewController {
	let terminalTab: TerminalTab
	private var terminalView: TerminalView?
	private var overlayHostController: UIHostingController<AnyView>?
	private var connectTask: Task<Void, Never>?

	init(terminalTab: TerminalTab) {
		self.terminalTab = terminalTab
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		setupTerminal()
		connectIfNeeded()
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

	func setupTerminal() {
		guard terminalView == nil else { return }

		let tv = TerminalView(frame: view.bounds)
		tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		tv.onWrite = { [weak self] data in
			self?.terminalTab.sshSession.connection.send(data)
		}
		tv.onResize = { [weak self] cols, rows in
			self?.terminalTab.sshSession.connection.resize(cols: Int(cols), rows: Int(rows))
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

	deinit {
		connectTask?.cancel()
	}
}

// MARK: - Overlay (connecting / error states)

struct TerminalOverlay: View {
	let tab: TerminalTab
	var onRetryWithPassword: (String) -> Void

	@State private var password = ""

	var body: some View {
		ZStack {
			if !tab.isConnected, tab.connectionError == nil, !tab.needsPassword {
				Color.black
				ProgressView("Connecting to \(tab.session.hostname)…")
					.tint(.white)
					.foregroundStyle(.white)
			}

			if tab.sshSession.isReplaying {
				Color.black
				ProgressView("Restoring session…")
					.tint(.white)
					.foregroundStyle(.white)
			}

			if let error = tab.connectionError {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(.red)
					Text("Connection Failed")
						.font(.headline)
					Text(error)
						.font(.caption)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.padding()
				.background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
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
