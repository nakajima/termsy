#if canImport(UIKit)
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

		func makeUIViewController(context _: Context) -> TerminalHostController {
			tab.onConnectionEstablished = onConnectionEstablished
			return TerminalHostController(terminalTab: tab, theme: theme)
		}

		func updateUIViewController(_ controller: TerminalHostController, context _: Context) {
			tab.onConnectionEstablished = onConnectionEstablished
			controller.applyTheme(theme)
		}

		static func dismantleUIViewController(_ controller: TerminalHostController, coordinator _: ()) {
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
		private var activeConnectTaskID: UUID?
		private var connectionWatchdogTask: Task<Void, Never>?
		private let activationReconnectDelayNanoseconds: UInt64 = 750_000_000

		init(terminalTab: TerminalTab, theme: AppTheme) {
			self.terminalTab = terminalTab
			self.theme = theme
			super.init(nibName: nil, bundle: nil)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) { fatalError() }

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
			terminalTab.renderPendingPreviewIfNeeded()
			updateOverlay()
		}

		func teardownTerminal() {
			terminalTab.setDisplayActive(false)
			connectTask?.cancel()
			activeConnectTaskID = nil
			connectionWatchdogTask?.cancel()
			connectionWatchdogTask = nil
			terminalView?.removeFromSuperview()
			terminalView = nil
		}

		private func connectIfNeeded() {
			terminalTab.renderPendingPreviewIfNeeded()
			startConnectTask(after: 0)
		}

		private func startConnectTask(after delayNanoseconds: UInt64) {
			guard !terminalTab.isConnected,
			      terminalTab.connectionError == nil,
			      !terminalTab.needsPassword,
			      activeConnectTaskID == nil,
			      !terminalTab.connectionIsActive
			else { return }

			let taskID = UUID()
			activeConnectTaskID = taskID
			connectTask = Task { [weak self] in
				guard let self else { return }
				defer {
					if self.activeConnectTaskID == taskID {
						self.activeConnectTaskID = nil
						self.connectTask = nil
						self.updateOverlay()
					}
				}
				if delayNanoseconds > 0 {
					try? await Task.sleep(nanoseconds: delayNanoseconds)
					guard !Task.isCancelled else { return }
				}
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
			updateConnectionWatchdog()
		}

		private var showsConnectingOverlay: Bool {
			!terminalTab.isConnected
				&& terminalTab.connectionError == nil
				&& !terminalTab.needsPassword
				&& !terminalTab.isRestoring
		}

		private func updateConnectionWatchdog() {
			guard showsConnectingOverlay else {
				connectionWatchdogTask?.cancel()
				connectionWatchdogTask = nil
				return
			}
			guard connectionWatchdogTask == nil else { return }
			connectionWatchdogTask = Task { [weak self] in
				defer {
					self?.connectionWatchdogTask = nil
				}
				while !Task.isCancelled {
					try? await Task.sleep(nanoseconds: 1_000_000_000)
					guard let self else { return }
					guard self.showsConnectingOverlay else { return }
					guard self.activeConnectTaskID == nil, !self.terminalTab.connectionIsActive else { continue }
					self.terminalTab.noteConnectingOverlayWithoutActiveAttempt()
					self.connectIfNeeded()
				}
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
			connectTask = nil
			activeConnectTaskID = nil
			terminalTab.prepareForReconnectAfterBackgroundLoss()
			terminalView = nil
			setupTerminal()
			startConnectTask(after: activationReconnectDelayNanoseconds)
		}

		deinit {
			connectTask?.cancel()
			connectionWatchdogTask?.cancel()
		}
	}
#endif
