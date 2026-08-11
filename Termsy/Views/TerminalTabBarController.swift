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
		@AppStorage(TerminalPointerSettings.bottomEdgeLiftEnabledKey) private var bottomEdgeLiftEnabled = TerminalPointerSettings.defaultBottomEdgeLiftEnabled
		@AppStorage(TerminalPointerSettings.bottomEdgeLiftDistanceKey) private var bottomEdgeLiftDistance = TerminalPointerSettings.defaultBottomEdgeLiftDistance
		let tab: TerminalTab

		func makeUIViewController(context _: Context) -> TerminalHostController {
			TerminalHostController(
				terminalTab: tab,
				theme: theme,
				bottomEdgeLiftEnabled: bottomEdgeLiftEnabled,
				bottomEdgeLiftDistance: bottomEdgeLiftDistance
			)
		}

		func updateUIViewController(_ controller: TerminalHostController, context _: Context) {
			controller.applyTheme(theme)
			controller.setBottomEdgeLiftEnabled(bottomEdgeLiftEnabled)
			controller.setBottomEdgeLiftDistance(bottomEdgeLiftDistance)
		}

		static func dismantleUIViewController(_ controller: TerminalHostController, coordinator _: ()) {
			controller.teardownTerminal()
		}
	}

	// MARK: - Per-Tab Host Controller

	@MainActor
	final class TerminalHostController: UIViewController, UIGestureRecognizerDelegate {
		let terminalTab: TerminalTab
		private var theme: AppTheme
		private var terminalView: TerminalView?
		private var terminalLayoutConstraints: [NSLayoutConstraint] = []
		private var terminalTopConstraint: NSLayoutConstraint?
		private var terminalBottomConstraint: NSLayoutConstraint?
		private weak var bottomEdgeHoverRecognizer: UIHoverGestureRecognizer?
		private var bottomEdgeLiftEnabled: Bool
		private var bottomEdgeLiftDistance: CGFloat
		private var isTerminalLifted = false
		private var overlayHostController: UIHostingController<AnyView>?
		private var recordingBadgeHostController: UIHostingController<AnyView>?

		override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
			[.bottom]
		}

		init(
			terminalTab: TerminalTab,
			theme: AppTheme,
			bottomEdgeLiftEnabled: Bool,
			bottomEdgeLiftDistance: Double
		) {
			self.terminalTab = terminalTab
			self.theme = theme
			self.bottomEdgeLiftEnabled = bottomEdgeLiftEnabled
			self.bottomEdgeLiftDistance = TerminalPointerSettings.clampedBottomEdgeLiftDistance(bottomEdgeLiftDistance)
			super.init(nibName: nil, bundle: nil)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) { fatalError() }

		override func viewDidLoad() {
			super.viewDidLoad()
			view.clipsToBounds = true
			setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
			setupBottomEdgeHoverRecognizer()
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
			tv.translatesAutoresizingMaskIntoConstraints = false
			tv.applyTheme(theme)
			tv.removeFromSuperview()
			if let overlayView = overlayHostController?.view {
				view.insertSubview(tv, belowSubview: overlayView)
			} else {
				view.addSubview(tv)
			}
			let verticalOffset = isTerminalLifted ? -bottomEdgeLiftDistance : 0
			let topConstraint = tv.topAnchor.constraint(equalTo: view.topAnchor, constant: verticalOffset)
			let bottomConstraint = tv.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: verticalOffset)
			terminalTopConstraint = topConstraint
			terminalBottomConstraint = bottomConstraint
			terminalLayoutConstraints = [
				topConstraint,
				bottomConstraint,
				tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
				tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			]
			NSLayoutConstraint.activate(terminalLayoutConstraints)
			terminalView = tv
			view.layoutIfNeeded()
			syncTerminalSizeToSession()
			terminalTab.renderPendingPreviewIfNeeded()
			updateOverlay()
		}

		func teardownTerminal() {
			terminalTab.setDisplayActive(false)
			terminalTab.onOverlayStateChange = nil
			terminalTab.onTerminalViewReplacementRequested = nil
			NSLayoutConstraint.deactivate(terminalLayoutConstraints)
			terminalLayoutConstraints = []
			terminalTopConstraint = nil
			terminalBottomConstraint = nil
			terminalView?.removeFromSuperview()
			terminalView = nil
		}

		private func reloadTerminalView() {
			guard isViewLoaded else { return }
			NSLayoutConstraint.deactivate(terminalLayoutConstraints)
			terminalLayoutConstraints = []
			terminalTopConstraint = nil
			terminalBottomConstraint = nil
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
			terminalView?.setKeyboardFocusSuspended(overlayNeedsInteraction)

			if let existing = overlayHostController {
				existing.rootView = AnyView(overlayView)
				existing.view.isHidden = !overlayNeedsInteraction
				existing.view.isUserInteractionEnabled = overlayNeedsInteraction
			} else {
				let host = UIHostingController(rootView: AnyView(overlayView))
				host.view.backgroundColor = .clear
				host.view.clipsToBounds = true
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

		func setBottomEdgeLiftEnabled(_ isEnabled: Bool) {
			guard bottomEdgeLiftEnabled != isEnabled else { return }
			bottomEdgeLiftEnabled = isEnabled
			if !isEnabled {
				setTerminalLifted(false)
			}
		}

		func setBottomEdgeLiftDistance(_ rawValue: Double) {
			let distance = TerminalPointerSettings.clampedBottomEdgeLiftDistance(rawValue)
			guard bottomEdgeLiftDistance != distance else { return }
			bottomEdgeLiftDistance = distance
			if isTerminalLifted {
				updateTerminalPosition()
			}
		}

		private func setupBottomEdgeHoverRecognizer() {
			guard UIDevice.current.userInterfaceIdiom == .pad else { return }
			let recognizer = UIHoverGestureRecognizer(
				target: self,
				action: #selector(handleBottomEdgeHover(_:))
			)
			recognizer.allowedTouchTypes = [
				NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
			]
			recognizer.cancelsTouchesInView = false
			recognizer.delegate = self
			view.addGestureRecognizer(recognizer)
			bottomEdgeHoverRecognizer = recognizer
		}

		@objc private func handleBottomEdgeHover(_ recognizer: UIHoverGestureRecognizer) {
			guard bottomEdgeLiftEnabled else {
				setTerminalLifted(false)
				return
			}

			switch recognizer.state {
			case .began, .changed:
				let location = recognizer.location(in: view)
				let distanceFromBottom = distanceFromScreenBottom(for: location)
				let threshold = isTerminalLifted
					? TerminalPointerSettings.bottomEdgeActivationDistance + bottomEdgeLiftDistance
					: TerminalPointerSettings.bottomEdgeActivationDistance
				setTerminalLifted(distanceFromBottom <= threshold)
			case .ended, .cancelled, .failed:
				setTerminalLifted(false)
			default:
				break
			}
		}

		private func distanceFromScreenBottom(for locationInView: CGPoint) -> CGFloat {
			guard let window = view.window else {
				return max(view.bounds.maxY - locationInView.y, 0)
			}
			let locationInWindow = view.convert(locationInView, to: window)
			let screenCoordinateSpace = window.screen.coordinateSpace
			let locationInScreen = screenCoordinateSpace.convert(locationInWindow, from: window)
			return max(screenCoordinateSpace.bounds.maxY - locationInScreen.y, 0)
		}

		private func setTerminalLifted(_ isLifted: Bool, animated: Bool = true) {
			guard isTerminalLifted != isLifted else { return }
			isTerminalLifted = isLifted
			updateTerminalPosition(animated: animated)
		}

		private func updateTerminalPosition(animated: Bool = true) {
			guard let terminalTopConstraint, let terminalBottomConstraint else { return }
			let verticalOffset = isTerminalLifted ? -bottomEdgeLiftDistance : 0
			terminalTopConstraint.constant = verticalOffset
			terminalBottomConstraint.constant = verticalOffset

			let animations = { [weak self] in
				_ = self?.view.layoutIfNeeded()
			}
			guard animated, !UIAccessibility.isReduceMotionEnabled else {
				animations()
				return
			}
			UIView.animate(
				withDuration: 0.2,
				delay: 0,
				options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
				animations: animations
			)
		}

		func gestureRecognizer(
			_ gestureRecognizer: UIGestureRecognizer,
			shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
		) -> Bool {
			gestureRecognizer === bottomEdgeHoverRecognizer || otherGestureRecognizer === bottomEdgeHoverRecognizer
		}

		private func syncTerminalSizeToSession() {
			guard let terminalView else { return }
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
		TerminalRecordingBadgeContent(isRecording: true, dataByteCount: 18432)
			.padding()
			.background(TerminalTheme.mocha.appTheme.background)
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
#endif
