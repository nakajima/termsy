//
//  TerminalTabBarController.swift
//  Termsy
//
//  UITabBarController-based tab management for terminal sessions.
//  Gives us native Cmd+#, reorder, and top-bar styling on iPad for free.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Bridge

struct TerminalTabBarRepresentable: UIViewControllerRepresentable {
	@Environment(ViewCoordinator.self) var coordinator

	func makeUIViewController(context: Context) -> TerminalTabBarController {
		let controller = TerminalTabBarController()
		controller.coordinator = coordinator
		context.coordinator.coordinator = coordinator
		controller.delegate = context.coordinator
		return controller
	}

	func updateUIViewController(_ controller: TerminalTabBarController, context: Context) {
		context.coordinator.coordinator = coordinator
		controller.syncTabs()
	}

	func makeCoordinator() -> TabBarDelegate {
		TabBarDelegate()
	}

	class TabBarDelegate: NSObject, UITabBarControllerDelegate {
		weak var coordinator: ViewCoordinator?

		func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
			guard let coordinator else { return }
			guard let selectedID = (selectedTab.viewController as? TerminalHostController)?.terminalTab.session.id else { return }

			// Background the previous
			if let prevVC = previousTab?.viewController as? TerminalHostController,
			   prevVC.terminalTab.session.id != selectedID {
				prevVC.terminalTab.sshSession.enterBackground()
				prevVC.teardownTerminal()
			}

			// Foreground the new
			if let tab = coordinator.tabs.first(where: { $0.session.id == selectedID }) {
				tab.sshSession.enterForeground()
			}

			coordinator.selectedTabID = selectedID
		}
	}
}

// MARK: - Tab Bar Controller

@MainActor
final class TerminalTabBarController: UITabBarController {
	var coordinator: ViewCoordinator?
	private var tabsBySessionID: [Int64: UITab] = [:]

	func syncTabs() {
		guard let coordinator else { return }

		let currentIDs = Set(coordinator.tabs.compactMap(\.session.id))
		let existingIDs = Set(tabsBySessionID.keys)

		// Remove closed tabs
		for id in existingIDs.subtracting(currentIDs) {
			tabsBySessionID.removeValue(forKey: id)
		}

		// Add new tabs
		for terminalTab in coordinator.tabs {
			guard let id = terminalTab.session.id, tabsBySessionID[id] == nil else { continue }
			let vc = TerminalHostController(terminalTab: terminalTab, coordinator: coordinator)
			let uiTab = UITab(
				title: "\(terminalTab.session.username)@\(terminalTab.session.hostname)",
				image: UIImage(systemName: "terminal"),
				identifier: "session-\(id)",
				viewControllerProvider: { _ in vc }
			)
			tabsBySessionID[id] = uiTab
		}

		// Build ordered tabs array matching coordinator.tabs order
		let orderedTabs: [UITab] = coordinator.tabs.compactMap { terminalTab in
			guard let id = terminalTab.session.id else { return nil }
			return tabsBySessionID[id]
		}

		self.tabs = orderedTabs

		// Sync selection
		if let selectedID = coordinator.selectedTabID,
		   let id = selectedID,
		   let selectedUITab = tabsBySessionID[id] {
			self.selectedTab = selectedUITab
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		mode = .tabBar
		syncTabs()
	}
}

// MARK: - Per-Tab Host Controller

/// UIViewController that hosts a terminal session.
/// Manages the TerminalView lifecycle — creates it when visible, tears it down when backgrounded.
@MainActor
final class TerminalHostController: UIViewController {
	let terminalTab: TerminalTab
	weak var coordinator: ViewCoordinator?
	private var terminalView: TerminalView?
	private var overlayHostController: UIHostingController<AnyView>?
	private var connectTask: Task<Void, Never>?

	init(terminalTab: TerminalTab, coordinator: ViewCoordinator) {
		self.terminalTab = terminalTab
		self.coordinator = coordinator
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
		// If returning from background, set up terminal and replay
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

private struct TerminalOverlay: View {
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
