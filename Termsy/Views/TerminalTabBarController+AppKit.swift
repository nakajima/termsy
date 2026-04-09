#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI

struct TerminalHostRepresentable: NSViewControllerRepresentable {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab
	let onConnectionEstablished: (Session) -> Void

	func makeNSViewController(context: Context) -> TerminalHostController {
		tab.onConnectionEstablished = onConnectionEstablished
		return TerminalHostController(terminalTab: tab, theme: theme)
	}

	func updateNSViewController(_ controller: TerminalHostController, context: Context) {
		tab.onConnectionEstablished = onConnectionEstablished
		controller.applyTheme(theme)
	}

	static func dismantleNSViewController(_ controller: TerminalHostController, coordinator: ()) {
		controller.teardownTerminal()
	}
}

@MainActor
final class TerminalHostController: NSViewController {
	let terminalTab: TerminalTab
	private var theme: AppTheme
	private var terminalView: TerminalView?
	private var overlayHostController: NSHostingController<AnyView>?
	private var connectTask: Task<Void, Never>?
	private var activeConnectTaskID: UUID?
	private var connectionWatchdogTask: Task<Void, Never>?

	init(terminalTab: TerminalTab, theme: AppTheme) {
		self.terminalTab = terminalTab
		self.theme = theme
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func loadView() {
		view = NSView()
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		terminalTab.onRequestReconnect = { [weak self] in
			self?.reconnectAfterBackgroundLoss()
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
		restoreConnectionIfNeeded()
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
		guard !terminalTab.isConnected,
		      terminalTab.connectionError == nil,
		      !terminalTab.needsPassword,
		      !terminalTab.isRestoring,
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
		terminalTab.updateTerminalSize(size)
	}

	private func restoreConnectionIfNeeded() {
		if terminalTab.consumeReconnectOnActivation() {
			reconnectAfterBackgroundLoss()
			return
		}
		if terminalTab.isConnected {
			guard terminalTab.connectionIsActive else {
				reconnectAfterBackgroundLoss()
				return
			}
			syncTerminalSizeToSession()
			return
		}
		connectIfNeeded()
	}

	private func reconnectAfterBackgroundLoss() {
		connectTask?.cancel()
		connectTask = nil
		activeConnectTaskID = nil
		terminalTab.prepareForReconnectAfterBackgroundLoss()
		terminalView = nil
		setupTerminal()
		connectIfNeeded()
	}

	deinit {
		connectTask?.cancel()
		connectionWatchdogTask?.cancel()
	}
}
#endif
