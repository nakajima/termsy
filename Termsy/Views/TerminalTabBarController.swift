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
		private var recordingBadgeHostController: UIHostingController<AnyView>?

		override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
			[.bottom]
		}

		override var keyCommands: [UIKeyCommand]? {
			[
				appShortcutCommand(input: "[", modifiers: [.command, .shift], action: #selector(selectPreviousTabFromKeyCommand(_:)), title: "Previous Tab"),
				appShortcutCommand(input: "]", modifiers: [.command, .shift], action: #selector(selectNextTabFromKeyCommand(_:)), title: "Next Tab"),
				appShortcutCommand(input: "{", modifiers: .command, action: #selector(selectPreviousTabFromKeyCommand(_:)), title: nil),
				appShortcutCommand(input: "}", modifiers: .command, action: #selector(selectNextTabFromKeyCommand(_:)), title: nil),
			]
		}

		init(terminalTab: TerminalTab, theme: AppTheme) {
			self.terminalTab = terminalTab
			self.theme = theme
			super.init(nibName: nil, bundle: nil)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) { fatalError() }

		private func appShortcutCommand(
			input: String,
			modifiers: UIKeyModifierFlags,
			action: Selector,
			title: String?
		) -> UIKeyCommand {
			let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
			command.wantsPriorityOverSystemBehavior = true
			command.discoverabilityTitle = title
			return command
		}

		@objc private func selectPreviousTabFromKeyCommand(_: UIKeyCommand) {
			terminalTab.requestMoveTabSelection(-1)
		}

		@objc private func selectNextTabFromKeyCommand(_: UIKeyCommand) {
			terminalTab.requestMoveTabSelection(1)
		}

		override func viewDidLoad() {
			super.viewDidLoad()
			setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
			terminalTab.onOverlayStateChange = { [weak self] in
				self?.updateOverlay()
			}
			terminalTab.onTerminalViewReplacementRequested = { [weak self] in
				self?.reloadTerminalView()
			}
			applyTheme(theme)
			setupTerminal()
			setupRecordingBadge()
		}

		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
			if terminalView == nil {
				setupTerminal()
			}
			_ = terminalView?.syncSizeAndReadBack()
			terminalTab.hostDidAppear()
			terminalView?.restoreKeyboardFocusIfNeeded(retryCount: 30)
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
			updateRecordingBadgeTheme()
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

		private func setupRecordingBadge() {
			guard recordingBadgeHostController == nil else { return }
			let host = UIHostingController(rootView: recordingBadgeView())
			host.view.backgroundColor = .clear
			host.view.translatesAutoresizingMaskIntoConstraints = false
			host.view.isUserInteractionEnabled = false
			addChild(host)
			view.addSubview(host.view)
			host.didMove(toParent: self)
			NSLayoutConstraint.activate([
				host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
				host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
			])
			recordingBadgeHostController = host
		}

		private func updateRecordingBadgeTheme() {
			recordingBadgeHostController?.rootView = recordingBadgeView()
		}

		private func recordingBadgeView() -> AnyView {
			AnyView(TerminalRecordingBadge(tab: terminalTab).environment(\.appTheme, theme))
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
				existing.view.isUserInteractionEnabled = overlayNeedsInteraction
			} else {
				let host = UIHostingController(rootView: AnyView(overlayView))
				host.view.backgroundColor = .clear
				host.view.frame = view.bounds
				host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
				host.view.isHidden = !overlayNeedsInteraction
				host.view.isUserInteractionEnabled = overlayNeedsInteraction
				addChild(host)
				view.addSubview(host.view)
				host.didMove(toParent: self)
				overlayHostController = host
			}
			if !overlayNeedsInteraction {
				terminalView?.restoreKeyboardFocusIfNeeded(retryCount: 30)
			}
		}

		private func syncTerminalSizeToSession() {
			guard let terminalView else { return }
			terminalView.frame = view.bounds
			guard let size = terminalView.syncSizeAndReadBack() else { return }
			terminalTab.updateTerminalSize(size)
		}
	}

	private struct TerminalRecordingBadge: View {
		let tab: TerminalTab

		var body: some View {
			TerminalRecordingBadgeContent(
				isRecording: tab.isRecording,
				dataByteCount: tab.recordingDataByteCount
			)
		}
	}

	private struct TerminalRecordingBadgeContent: View {
		@Environment(\.appTheme) private var theme
		let isRecording: Bool
		let dataByteCount: Int64
		@State private var pulse = false

		private var dataSizeText: String {
			TerminalRecordingByteCountFormatter.string(for: dataByteCount)
		}

		var body: some View {
			if isRecording {
				HStack(spacing: 6) {
					Image(systemName: "record.circle.fill")
						.foregroundStyle(theme.error)
						.opacity(pulse ? 0.35 : 1)
						.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

					Text("REC \(dataSizeText)")
						.font(.caption.monospacedDigit().weight(.semibold))
						.foregroundStyle(theme.primaryText)
				}
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(theme.cardBackground.opacity(0.92), in: Capsule())
				.overlay {
					Capsule()
						.stroke(theme.divider, lineWidth: 1)
				}
				.shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
				.onAppear {
					pulse = true
				}
				.onDisappear {
					pulse = false
				}
			}
		}
	}

	#Preview("Recording Badge") {
		TerminalRecordingBadgeContent(isRecording: true, dataByteCount: 18_432)
			.padding()
			.background(TerminalTheme.mocha.appTheme.background)
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
#endif
