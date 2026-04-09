#if canImport(UIKit)
//
//  TerminalView.swift
//  Termsy
//
//  UIView hosting a ghostty_surface_t with host-managed I/O.
//  Keyboard input follows the libghostty API contract:
//  text field carries the unmodified character, NULL for C0/function keys.
//  The encoder derives ctrl/alt sequences from the logical key + mods.
//

import TermsyGhosttyCore
import UIKit

@MainActor
final class TerminalView: UIView, UIKeyInput, UIContextMenuInteractionDelegate {
	nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
	private var hostManagedSurface: HostManagedSurface?
	private var ghosttySurfaceUserdata: GhosttySurfaceUserdata?
	private var displayLink: CADisplayLink?
	private var pendingClipboardConfirmations = [PendingClipboardConfirmation]()
	private var activeClipboardConfirmation: PendingClipboardConfirmation?
	private weak var clipboardAlertController: UIAlertController?
	private var activeHardwareKeyCodes = Set<UInt16>()
	private var keyRepeatTimer: DispatchSourceTimer?
	private var repeatingHardwareKey: UIKey?
	private var repeatingKeyCode: UInt16?
	private var suppressedKeyReleaseCodes = Set<UInt16>()
	private var lastMouseLocation: CGPoint?
	private var activePointerButton: ghostty_input_mouse_button_e?
	private weak var touchScrollRecognizer: UIPanGestureRecognizer?
	private weak var indirectScrollRecognizer: UIPanGestureRecognizer?
	private var lastScrollLocation: CGPoint?
	private var momentumVelocity = CGPoint.zero
	private var momentumInputKind: TerminalScrollSettings.InputKind?
	private var smoothScrollAccumulatedOffsetY: CGFloat = 0
	private var smoothScrollTargetOffsetY: CGFloat = 0
	private var smoothScrollPresentationOffsetY: CGFloat = 0
	private var smoothScrollSuppressedUntilNextScrollGesture = false
	private var isDisplayActive = false
	private var firstResponderTask: Task<Void, Never>?
	private let momentumVelocityThreshold: CGFloat = 50
	private let momentumDecelerationPerFrame: CGFloat = 0.92
	private let smoothScrollAnimationSpeed: CGFloat = 18

	/// Called when the terminal produces bytes (user input, query responses).
	var onWrite: ((Data) -> Void)?

	/// Called when the terminal grid resizes.
	var onResize: ((UInt16, UInt16) -> Void)?

	/// Called when the terminal updates its title.
	var onTitleChange: ((String) -> Void)?

	/// Called when the user requests closing the current tab.
	var onCloseTabRequest: (() -> Void)?

	/// Called when the user requests opening a new tab.
	var onNewTabRequest: (() -> Void)?

	/// Called when the user requests selecting a tab by 1-based index.
	var onSelectTabRequest: ((Int) -> Void)?

	/// Called when the user requests moving the current tab selection by a relative offset.
	var onMoveTabSelectionRequest: ((Int) -> Void)?

	/// Called when the user requests opening app settings.
	var onShowSettingsRequest: (() -> Void)?

	/// Called when Escape should dismiss auxiliary app UI instead of reaching the terminal.
	var onDismissAuxiliaryUIRequest: (() -> Bool)?

	private enum ClipboardConfirmationAction {
		case read(state: UnsafeMutableRawPointer, request: ghostty_clipboard_request_e)
		case write
	}

	private struct PendingClipboardConfirmation {
		let id = UUID()
		let kind: GhosttyClipboardConfirmationKind
		let text: String
		let action: ClipboardConfirmationAction
	}

	// MARK: - Lifecycle

	override init(frame: CGRect) {
		super.init(frame: frame)
		applyTheme(TerminalTheme.current.appTheme)
		isUserInteractionEnabled = false
		isMultipleTouchEnabled = false
		clipsToBounds = true

		let touchScrollRecognizer = UIPanGestureRecognizer(
			target: self, action: #selector(handleScroll(_:)))
		touchScrollRecognizer.minimumNumberOfTouches = 2
		touchScrollRecognizer.maximumNumberOfTouches = 2
		touchScrollRecognizer.allowedTouchTypes = [
			NSNumber(value: UITouch.TouchType.direct.rawValue)
		]
		touchScrollRecognizer.cancelsTouchesInView = false
		touchScrollRecognizer.delaysTouchesBegan = false
		touchScrollRecognizer.delaysTouchesEnded = false
		addGestureRecognizer(touchScrollRecognizer)
		self.touchScrollRecognizer = touchScrollRecognizer

		if #available(iOS 13.4, *) {
			let indirectScrollRecognizer = UIPanGestureRecognizer(
				target: self, action: #selector(handleScroll(_:)))
			indirectScrollRecognizer.allowedTouchTypes = []
			indirectScrollRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
			indirectScrollRecognizer.cancelsTouchesInView = false
			indirectScrollRecognizer.delaysTouchesBegan = false
			indirectScrollRecognizer.delaysTouchesEnded = false
			indirectScrollRecognizer.requiresExclusiveTouchType = false
			addGestureRecognizer(indirectScrollRecognizer)
			self.indirectScrollRecognizer = indirectScrollRecognizer
		}

		addInteraction(UIContextMenuInteraction(delegate: self))
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) { fatalError() }

	deinit {
		ClipboardAccessAuthorization.clear(for: self)
	}

	func applyTheme(_ theme: AppTheme) {
		backgroundColor = theme.backgroundUIColor
	}

	func start() {
		if surface == nil {
			guard let app = GhosttyApp.shared.app else { return }
			if hostManagedSurface == nil {
				hostManagedSurface = HostManagedSurface(
					onData: { [weak self] data in
						DispatchQueue.main.async {
							self?.onWrite?(data)
						}
					},
					onResize: { [weak self] resize in
						DispatchQueue.main.async {
							self?.onResize?(resize.columns, resize.rows)
						}
					}
				)
			}

			if ghosttySurfaceUserdata == nil {
				ghosttySurfaceUserdata = GhosttyApp.shared.makeSurfaceUserdata(
					payload: Unmanaged.passUnretained(self).toOpaque(),
					object: self
				)
			}

			let scale = resolvedScale()
			surface = hostManagedSurface?.start(
				app: app,
				surfaceUserdata: ghosttySurfaceUserdata?.opaquePointer,
				scaleFactor: Double(scale),
				fontSize: TerminalFontSettings.defaultSize
			) { cfg in
				cfg.platform_tag = GHOSTTY_PLATFORM_IOS
				cfg.platform = ghostty_platform_u(
					ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
				)
			}
		}

		applyDisplayActivity()
	}

	func stop() {
		cancelFirstResponderRequest()
		stopMomentumScrolling()
		snapSmoothScrollPresentationToTerminal()
		stopDisplayLink()
		stopKeyRepeat()
		activeHardwareKeyCodes.removeAll()
		suppressedKeyReleaseCodes.removeAll()
		ClipboardAccessAuthorization.clear(for: self)
		lastMouseLocation = nil
		lastScrollLocation = nil
		activePointerButton = nil
		denyOutstandingClipboardReadConfirmations()
		if let surface {
			ghostty_surface_set_focus(surface, false)
		}
		hostManagedSurface?.free()
		hostManagedSurface = nil
		surface = nil
	}

	func feedData(_ data: Data) {
		guard !data.isEmpty else { return }
		smoothScrollSuppressedUntilNextScrollGesture = true
		snapSmoothScrollPresentationToTerminal()
		hostManagedSurface?.write(data)
	}

	func processExited(code: UInt32 = 0, runtimeMs: UInt64 = 0) {
		hostManagedSurface?.processExit(code: code, runtimeMs: runtimeMs)
	}

	func handleTitleChange(_ title: String) {
		onTitleChange?(title)
	}

	func requestClipboardReadConfirmation(
		text: String,
		state: UnsafeMutableRawPointer,
		request: ghostty_clipboard_request_e
	) {
		guard let kind = GhosttyClipboardConfirmationKind(request: request) else {
			guard let surface else { return }
			"".withCString { cString in
				ghostty_surface_complete_clipboard_request(surface, cString, state, true)
			}
			return
		}

		pendingClipboardConfirmations.append(
			PendingClipboardConfirmation(
				kind: kind,
				text: text,
				action: .read(state: state, request: request)
			)
		)
		presentNextClipboardConfirmationIfNeeded()
	}

	func requestClipboardWriteConfirmation(text: String) {
		pendingClipboardConfirmations.append(
			PendingClipboardConfirmation(
				kind: .osc52Write,
				text: text,
				action: .write
			)
		)
		presentNextClipboardConfirmationIfNeeded()
	}

	var hasAttachedWindow: Bool {
		window != nil
	}

	func setDisplayActive(_ isActive: Bool) {
		isDisplayActive = isActive
		applyDisplayActivity()
	}

	private func presentNextClipboardConfirmationIfNeeded() {
		guard activeClipboardConfirmation == nil,
		      !pendingClipboardConfirmations.isEmpty
		else { return }

		let confirmation = pendingClipboardConfirmations.removeFirst()
		activeClipboardConfirmation = confirmation

		guard let presenter = topClipboardAlertPresenter() else {
			resolveClipboardConfirmation(confirmation, allowed: false)
			return
		}

		let alert = UIAlertController(
			title: confirmation.kind.title,
			message: confirmation.kind.formattedMessage(for: confirmation.text),
			preferredStyle: .alert
		)
		alert.addAction(
			UIAlertAction(title: confirmation.kind.denyButtonTitle, style: .cancel) { [weak self] _ in
				self?.resolveClipboardConfirmation(confirmation, allowed: false)
			}
		)
		alert.addAction(
			UIAlertAction(title: confirmation.kind.allowButtonTitle, style: .default) { [weak self] _ in
				self?.resolveClipboardConfirmation(confirmation, allowed: true)
			}
		)
		clipboardAlertController = alert
		presenter.present(alert, animated: true)
	}

	private func resolveClipboardConfirmation(_ confirmation: PendingClipboardConfirmation, allowed: Bool) {
		guard activeClipboardConfirmation?.id == confirmation.id else { return }

		switch confirmation.action {
		case let .read(state, _):
			guard let surface else {
				finishClipboardConfirmation(confirmation)
				return
			}
			let responseText = allowed ? confirmation.text : ""
			responseText.withCString { cString in
				ghostty_surface_complete_clipboard_request(surface, cString, state, true)
			}

		case .write:
			if allowed {
				UIPasteboard.general.string = confirmation.text
			}
		}

		finishClipboardConfirmation(confirmation)
	}

	private func finishClipboardConfirmation(_ confirmation: PendingClipboardConfirmation) {
		guard activeClipboardConfirmation?.id == confirmation.id else { return }
		activeClipboardConfirmation = nil
		clipboardAlertController = nil
		presentNextClipboardConfirmationIfNeeded()
	}

	private func denyOutstandingClipboardReadConfirmations() {
		let confirmations = [activeClipboardConfirmation].compactMap { $0 } + pendingClipboardConfirmations
		if let surface {
			for confirmation in confirmations {
				if case let .read(state, _) = confirmation.action {
					"".withCString { cString in
						ghostty_surface_complete_clipboard_request(surface, cString, state, true)
					}
				}
			}
		}
		activeClipboardConfirmation = nil
		pendingClipboardConfirmations.removeAll()
		clipboardAlertController?.dismiss(animated: false)
		clipboardAlertController = nil
	}

	private func topClipboardAlertPresenter() -> UIViewController? {
		topmostViewController(from: owningViewController() ?? window?.rootViewController)
	}

	private func owningViewController() -> UIViewController? {
		var responder: UIResponder? = self
		while let next = responder?.next {
			if let viewController = next as? UIViewController {
				return viewController
			}
			responder = next
		}
		return nil
	}

	private func topmostViewController(from root: UIViewController?) -> UIViewController? {
		if let navigationController = root as? UINavigationController {
			return topmostViewController(from: navigationController.visibleViewController) ?? navigationController
		}
		if let tabBarController = root as? UITabBarController {
			return topmostViewController(from: tabBarController.selectedViewController) ?? tabBarController
		}
		if let splitViewController = root as? UISplitViewController {
			return topmostViewController(from: splitViewController.viewControllers.last) ?? splitViewController
		}
		if let presented = root?.presentedViewController {
			return topmostViewController(from: presented) ?? presented
		}
		return root
	}

	private func applyDisplayActivity() {
		let shouldBeActive = isDisplayActive && window != nil
		isUserInteractionEnabled = shouldBeActive

		guard let surface else {
			if !shouldBeActive {
				stopDisplayActivity()
			}
			return
		}

		if shouldBeActive {
			startDisplayLink()
			ghostty_surface_set_focus(surface, true)
			requestFirstResponder()
			ghostty_surface_refresh(surface)
			ghostty_surface_draw(surface)
		} else {
			stopDisplayActivity()
			ghostty_surface_set_focus(surface, false)
		}
	}

	private var shouldHoldFirstResponder: Bool {
		isDisplayActive && window != nil && surface != nil
	}

	private func requestFirstResponder(retryCount: Int = 4) {
		cancelFirstResponderRequest()
		guard shouldHoldFirstResponder else { return }
		if isFirstResponder { return }

		_ = becomeFirstResponder()
		guard !isFirstResponder, retryCount > 0 else { return }

		firstResponderTask = Task { @MainActor [weak self] in
			guard let self else { return }
			for _ in 0 ..< retryCount {
				try? await Task.sleep(nanoseconds: 50_000_000)
				guard !Task.isCancelled else { return }
				guard self.shouldHoldFirstResponder else { return }
				if self.isFirstResponder { return }
				_ = self.becomeFirstResponder()
			}
		}
	}

	private func cancelFirstResponderRequest() {
		firstResponderTask?.cancel()
		firstResponderTask = nil
	}

	private func stopDisplayActivity() {
		cancelFirstResponderRequest()
		resignFirstResponder()
		stopMomentumScrolling()
		snapSmoothScrollPresentationToTerminal()
		stopDisplayLink()
		stopKeyRepeat()
		activeHardwareKeyCodes.removeAll()
		suppressedKeyReleaseCodes.removeAll()
		lastScrollLocation = nil
		activePointerButton = nil
	}

	// MARK: - Layout & Sublayers

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window != nil {
			updateDisplayScale()
			start()
			DispatchQueue.main.async { [weak self] in
				guard let self, self.window != nil else { return }
				self.syncSize()
				self.updateSublayerFrames()
				self.applyDisplayActivity()
			}
		} else {
			applyDisplayActivity()
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		updateDisplayScale()
		updateSublayerFrames()
		syncSize()
	}

	private func resolvedScale() -> CGFloat {
		window?.windowScene?.screen.nativeScale ?? window?.screen.nativeScale ?? 1
	}

	private func updateDisplayScale() {
		let scale = resolvedScale()
		contentScaleFactor = scale
		layer.contentsScale = scale
	}

	private func updateSublayerFrames() {
		let scale = resolvedScale()
		contentScaleFactor = scale
		layer.contentsScale = scale
		let presentationOffsetY = TerminalScrollSettings.smoothVisualScrollingEnabled
			? smoothScrollPresentationOffsetY : 0
		guard let sublayers = layer.sublayers else { return }
		for sublayer in sublayers {
			sublayer.frame = bounds
			sublayer.contentsScale = scale
			sublayer.transform = CATransform3DMakeTranslation(0, presentationOffsetY, 0)
		}
	}

	func syncSizeAndReadBack() -> TerminalWindowSize? {
		syncSize()
		return currentTerminalSize()
	}

	func currentTerminalSize() -> TerminalWindowSize? {
		guard let surface else { return nil }
		let size = ghostty_surface_size(surface)
		return TerminalWindowSize(
			columns: Int(size.columns),
			rows: Int(size.rows),
			pixelWidth: Int(size.width_px),
			pixelHeight: Int(size.height_px)
		)
	}

	private func syncSize() {
		guard let surface else { return }
		let scale = resolvedScale()
		let w = UInt32((bounds.width * scale).rounded(.down))
		let h = UInt32((bounds.height * scale).rounded(.down))
		guard w > 0, h > 0 else { return }
		ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
		ghostty_surface_set_size(surface, w, h)
	}

	// MARK: - Display Link

	private func startDisplayLink() {
		guard displayLink == nil else { return }
		let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	private func stopDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
	}

	@objc private func tick(_ link: CADisplayLink) {
		GhosttyApp.shared.tick()
		let deltaTime = max(CGFloat(link.targetTimestamp - link.timestamp), 1.0 / 120.0)
		updateMomentumScrolling(deltaTime: deltaTime)
		updateSmoothScrollPresentation(deltaTime: deltaTime)
		guard let surface else { return }
		ghostty_surface_refresh(surface)
		ghostty_surface_draw(surface)
		updateSublayerFrames()
	}

	// MARK: - Touch / Mouse

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)
		guard let surface, let touch = touches.first else {
			return
		}

		requestFirstResponder()
		cancelActiveScrollAnimationForInteraction()

		if touch.type == .indirectPointer {
			let pos = touch.location(in: self)
			sendMousePosition(pos)
			let button = pointerButton(from: event)
			activePointerButton = button
			ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, GHOSTTY_MODS_NONE)
			return
		}

		let pos = touch.location(in: self)
		sendMousePosition(pos)
		ghostty_surface_mouse_button(
			surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)
		guard let touch = touches.first else {
			return
		}
		sendMousePosition(touch.location(in: self))
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)
		guard let surface, let touch = touches.first else {
			return
		}
		sendMousePosition(touch.location(in: self))

		if touch.type == .indirectPointer {
			let button = activePointerButton ?? pointerButton(from: event)
			activePointerButton = nil
			ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, GHOSTTY_MODS_NONE)
			return
		}

		ghostty_surface_mouse_button(
			surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
		guard let surface else {
			return
		}
		let button = activePointerButton ?? GHOSTTY_MOUSE_LEFT
		activePointerButton = nil
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, GHOSTTY_MODS_NONE)
	}

	private func sendMousePosition(_ point: CGPoint) {
		guard let surface else { return }
		guard lastMouseLocation != point else { return }
		lastMouseLocation = point
		ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
	}

	private func pointerButton(from event: UIEvent?) -> ghostty_input_mouse_button_e {
		guard let event else { return GHOSTTY_MOUSE_LEFT }
		if event.buttonMask.contains(.secondary) {
			return GHOSTTY_MOUSE_RIGHT
		}
		if event.buttonMask.contains(.primary) {
			return GHOSTTY_MOUSE_LEFT
		}
		return GHOSTTY_MOUSE_LEFT
	}

	@objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
		guard surface != nil else { return }
		guard activePointerButton == nil else { return }
		let inputKind: TerminalScrollSettings.InputKind =
			recognizer === indirectScrollRecognizer ? .indirectPointer : .touch
		let location = recognizer.location(in: self)

		switch recognizer.state {
		case .began:
			smoothScrollSuppressedUntilNextScrollGesture = false
			cancelActiveScrollAnimationForInteraction()
			lastScrollLocation = location

		case .changed:
			lastScrollLocation = location
			sendScrollTranslation(recognizer.translation(in: self), inputKind: inputKind, location: location)
			recognizer.setTranslation(.zero, in: self)

		case .ended:
			lastScrollLocation = location
			sendScrollTranslation(recognizer.translation(in: self), inputKind: inputKind, location: location)
			recognizer.setTranslation(.zero, in: self)
			startMomentumScrolling(velocity: recognizer.velocity(in: self), inputKind: inputKind)

		case .cancelled, .failed:
			recognizer.setTranslation(.zero, in: self)
			stopMomentumScrolling()
			releaseSmoothScrollPresentation()

		default:
			break
		}
	}

	private func sendScrollTranslation(
		_ translation: CGPoint,
		inputKind: TerminalScrollSettings.InputKind,
		location: CGPoint?
	) {
		guard translation != .zero else { return }
		sendScrollDelta(translation, inputKind: inputKind, location: location, momentum: .none)
	}

	private func sendScrollDelta(
		_ rawDelta: CGPoint,
		inputKind: TerminalScrollSettings.InputKind,
		location: CGPoint?,
		momentum: TerminalScrollSettings.MomentumPhase
	) {
		guard let surface else { return }
		if let location {
			sendMousePosition(location)
		}
		let adjustedDelta = TerminalScrollSettings.adjustedDelta(from: rawDelta, inputKind: inputKind)
		let mods = TerminalScrollSettings.scrollMods(for: inputKind, momentum: momentum)
		ghostty_surface_mouse_scroll(surface, adjustedDelta.x, adjustedDelta.y, mods)
		if rawDelta != .zero {
			noteSmoothScrollDelta(adjustedDelta)
		}
	}

	private func startMomentumScrolling(
		velocity: CGPoint,
		inputKind: TerminalScrollSettings.InputKind
	) {
		guard TerminalScrollSettings.momentumScrollingEnabled else {
			releaseSmoothScrollPresentation()
			return
		}
		guard abs(velocity.x) > momentumVelocityThreshold || abs(velocity.y) > momentumVelocityThreshold else {
			releaseSmoothScrollPresentation()
			return
		}

		momentumVelocity = velocity
		momentumInputKind = inputKind
		sendScrollDelta(.zero, inputKind: inputKind, location: lastScrollLocation, momentum: .began)
	}

	private func stopMomentumScrolling() {
		guard let inputKind = momentumInputKind else { return }
		momentumVelocity = .zero
		momentumInputKind = nil
		sendScrollDelta(.zero, inputKind: inputKind, location: lastScrollLocation, momentum: .none)
	}

	private func updateMomentumScrolling(deltaTime: CGFloat) {
		guard let inputKind = momentumInputKind else { return }

		let frameScale = max(deltaTime * 60, 0)
		let deceleration = CGFloat(pow(Double(momentumDecelerationPerFrame), Double(frameScale)))
		momentumVelocity.x *= deceleration
		momentumVelocity.y *= deceleration

		if abs(momentumVelocity.x) < momentumVelocityThreshold,
			abs(momentumVelocity.y) < momentumVelocityThreshold
		{
			stopMomentumScrolling()
			releaseSmoothScrollPresentation()
			return
		}

		let delta = CGPoint(
			x: momentumVelocity.x * deltaTime,
			y: momentumVelocity.y * deltaTime
		)
		sendScrollDelta(delta, inputKind: inputKind, location: lastScrollLocation, momentum: .changed)
	}

	private func noteSmoothScrollDelta(_ adjustedDelta: CGPoint) {
		guard TerminalScrollSettings.smoothVisualScrollingEnabled else {
			snapSmoothScrollPresentationToTerminal()
			return
		}
		guard !smoothScrollSuppressedUntilNextScrollGesture else { return }
		guard let cellHeight = terminalCellHeightInPoints(), cellHeight > 0 else { return }
		smoothScrollAccumulatedOffsetY -= adjustedDelta.y
		smoothScrollTargetOffsetY = wrappedSmoothScrollOffset(
			for: smoothScrollAccumulatedOffsetY,
			cellHeight: cellHeight
		)
	}

	private func updateSmoothScrollPresentation(deltaTime: CGFloat) {
		guard TerminalScrollSettings.smoothVisualScrollingEnabled else {
			snapSmoothScrollPresentationToTerminal()
			return
		}

		let alpha = min(1, deltaTime * smoothScrollAnimationSpeed)
		smoothScrollPresentationOffsetY +=
			(smoothScrollTargetOffsetY - smoothScrollPresentationOffsetY) * alpha

		if abs(smoothScrollPresentationOffsetY - smoothScrollTargetOffsetY) < 0.1 {
			smoothScrollPresentationOffsetY = smoothScrollTargetOffsetY
		}
	}

	private func releaseSmoothScrollPresentation() {
		smoothScrollAccumulatedOffsetY = 0
		smoothScrollTargetOffsetY = 0
	}

	private func snapSmoothScrollPresentationToTerminal() {
		smoothScrollAccumulatedOffsetY = 0
		smoothScrollTargetOffsetY = 0
		smoothScrollPresentationOffsetY = 0
		updateSublayerFrames()
	}

	private func cancelActiveScrollAnimationForInteraction() {
		stopMomentumScrolling()
		snapSmoothScrollPresentationToTerminal()
	}

	private func terminalCellHeightInPoints() -> CGFloat? {
		guard let surface else { return nil }
		let size = ghostty_surface_size(surface)
		guard size.cell_height_px > 0 else { return nil }
		let scale = resolvedScale()
		guard scale > 0 else { return nil }
		return CGFloat(size.cell_height_px) / scale
	}

	private func wrappedSmoothScrollOffset(for value: CGFloat, cellHeight: CGFloat) -> CGFloat {
		guard cellHeight > 0 else { return 0 }
		var remainder = value.truncatingRemainder(dividingBy: cellHeight)
		let halfCellHeight = cellHeight / 2
		if remainder > halfCellHeight {
			remainder -= cellHeight
		} else if remainder < -halfCellHeight {
			remainder += cellHeight
		}
		return remainder
	}

	// MARK: - First Responder

	override var canBecomeFirstResponder: Bool { true }
	var hasText: Bool { true }

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		switch action {
		case #selector(copy(_:)):
			return hasTerminalSelection
		case #selector(paste(_:)):
			return canPasteFromClipboard
		case #selector(selectAll(_:)):
			return surface != nil
		default:
			return super.canPerformAction(action, withSender: sender)
		}
	}

	override func copy(_ sender: Any?) {
		_ = performCopyToClipboard()
	}

	override func paste(_ sender: Any?) {
		_ = performPasteFromClipboard()
	}

	override func selectAll(_ sender: Any?) {
		_ = performBindingAction("select_all")
	}

	// MARK: - UIKeyInput

	func insertText(_ text: String) {
		guard let surface else { return }
		guard activeHardwareKeyCodes.isEmpty else {
			return
		}
		// Software keyboard path — send text directly.
		text.withCString { ptr in
			ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
		}
	}

	func deleteBackward() {
		guard let surface else { return }
		guard activeHardwareKeyCodes.isEmpty else {
			return
		}
		// Software keyboard backspace: use mac virtual keycode 0x33
		var event = ghostty_input_key_s()
		event.action = GHOSTTY_ACTION_PRESS
		event.keycode = 0x0033  // mac vkeycode for Backspace
		event.mods = GHOSTTY_MODS_NONE
		event.consumed_mods = GHOSTTY_MODS_NONE
		event.text = nil  // control key — let ghostty encode it
		event.composing = false
		ghostty_surface_key(surface, event)
	}

	// MARK: - Hardware Keyboard

	override func pressesBegan(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key, let surface else { continue }
			let keyCode = UInt16(key.keyCode.rawValue)
			if handleAppShortcutIfNeeded(for: key) {
				suppressedKeyReleaseCodes.insert(keyCode)
				continue
			}
			// Suppress UIKit's UIKeyInput callbacks while the hardware key is down.
			// We send both the initial press and repeats through ghostty key events.
			activeHardwareKeyCodes.insert(keyCode)
			if handleKey(key, action: GHOSTTY_ACTION_PRESS, surface: surface) {
				startKeyRepeat(for: key)
			}
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key, let surface else { continue }
			let keyCode = UInt16(key.keyCode.rawValue)
			activeHardwareKeyCodes.remove(keyCode)
			if repeatingKeyCode == keyCode {
				stopKeyRepeat()
			}
			if suppressedKeyReleaseCodes.remove(keyCode) != nil {
				continue
			}
			handleKey(key, action: GHOSTTY_ACTION_RELEASE, surface: surface)
		}
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }
			let keyCode = UInt16(key.keyCode.rawValue)
			activeHardwareKeyCodes.remove(keyCode)
			if repeatingKeyCode == keyCode {
				stopKeyRepeat()
			}
			suppressedKeyReleaseCodes.remove(keyCode)
		}
	}

	private func handleAppShortcutIfNeeded(for key: UIKey) -> Bool {
		let modifiers = key.modifierFlags.intersection([.shift, .control, .alternate, .command])
		if key.keyCode == .keyboardEscape, modifiers.isEmpty {
			return onDismissAuxiliaryUIRequest?() == true
		}

		guard key.modifierFlags.contains(.command) else { return false }

		if key.charactersIgnoringModifiers == "," {
			onShowSettingsRequest?()
			return true
		}
		if key.charactersIgnoringModifiers.compare("w", options: .caseInsensitive) == .orderedSame {
			onCloseTabRequest?()
			return true
		}
		if key.charactersIgnoringModifiers.compare("t", options: .caseInsensitive) == .orderedSame {
			onNewTabRequest?()
			return true
		}
		if key.charactersIgnoringModifiers.compare("v", options: .caseInsensitive) == .orderedSame {
			return performPasteFromClipboard()
		}
		if key.charactersIgnoringModifiers.compare("a", options: .caseInsensitive) == .orderedSame {
			selectAll(nil)
			return true
		}
		if key.charactersIgnoringModifiers.compare("c", options: .caseInsensitive) == .orderedSame {
			return performCopyToClipboard()
		}
		if let tabSelectionOffset = tabSelectionOffset(for: key) {
			onMoveTabSelectionRequest?(tabSelectionOffset)
			return true
		}
		if let digit = Int(key.charactersIgnoringModifiers), (1 ... 9).contains(digit) {
			onSelectTabRequest?(digit)
			return true
		}

		return false
	}

	private var hasTerminalSelection: Bool {
		guard let surface else { return false }
		return ghostty_surface_has_selection(surface)
	}

	private var canPasteFromClipboard: Bool {
		guard surface != nil else { return false }
		return UIPasteboard.general.hasStrings
	}

	@discardableResult
	private func performCopyToClipboard() -> Bool {
		guard hasTerminalSelection else { return false }
		return performBindingAction("copy_to_clipboard")
	}

	@discardableResult
	private func performPasteFromClipboard() -> Bool {
		guard canPasteFromClipboard else { return false }
		ClipboardAccessAuthorization.noteUserInitiatedPaste(for: self)
		let didStartPaste = performBindingAction("paste_from_clipboard")
		if !didStartPaste {
			ClipboardAccessAuthorization.clear(for: self)
		}
		return didStartPaste
	}

	@discardableResult
	private func performBindingAction(_ action: String) -> Bool {
		guard let surface else { return false }
		return action.withCString { cString in
			ghostty_surface_binding_action(surface, cString, UInt(action.utf8.count))
		}
	}

	func contextMenuInteraction(
		_ interaction: UIContextMenuInteraction,
		configurationForMenuAtLocation location: CGPoint
	) -> UIContextMenuConfiguration? {
		guard surface != nil else { return nil }
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
			self?.makeClipboardContextMenu()
		}
	}

	private func makeClipboardContextMenu() -> UIMenu {
		let copy = UIAction(
			title: "Copy",
			image: UIImage(systemName: "doc.on.doc")
		) { [weak self] _ in
			guard let self else { return }
			self.becomeFirstResponder()
			self.copy(nil)
		}
		copy.attributes = hasTerminalSelection ? [] : [.disabled]

		let paste = UIAction(
			title: "Paste",
			image: UIImage(systemName: "doc.on.clipboard")
		) { [weak self] _ in
			guard let self else { return }
			self.becomeFirstResponder()
			self.paste(nil)
		}
		paste.attributes = canPasteFromClipboard ? [] : [.disabled]

		let selectAll = UIAction(
			title: "Select All",
			image: UIImage(systemName: "selection.pin.in.out")
		) { [weak self] _ in
			guard let self else { return }
			self.becomeFirstResponder()
			self.selectAll(nil)
		}
		selectAll.attributes = surface == nil ? [.disabled] : []

		return UIMenu(children: [copy, paste, selectAll])
	}

	private func tabSelectionOffset(for key: UIKey) -> Int? {
		guard key.modifierFlags.contains(.command), key.modifierFlags.contains(.shift) else { return nil }
		switch key.charactersIgnoringModifiers {
		case "[":
			return -1
		case "]":
			return 1
		default:
			return nil
		}
	}

	private func shouldRepeatHardwareKey(_ key: UIKey) -> Bool {
		switch key.keyCode {
		case .keyboardDeleteOrBackspace,
		     .keyboardDeleteForward,
		     .keyboardReturnOrEnter,
		     .keyboardTab,
		     .keyboardUpArrow,
		     .keyboardDownArrow,
		     .keyboardLeftArrow,
		     .keyboardRightArrow,
		     .keyboardHome,
		     .keyboardEnd,
		     .keyboardPageUp,
		     .keyboardPageDown:
			return true
		default:
			return hardwareKeyText(for: key) != nil
		}
	}

	private func startKeyRepeat(for key: UIKey) {
		guard surface != nil else { return }
		guard shouldRepeatHardwareKey(key) else { return }
		let blockedModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
		guard key.modifierFlags.intersection(blockedModifiers).isEmpty else { return }

		stopKeyRepeat()
		repeatingHardwareKey = key
		repeatingKeyCode = UInt16(key.keyCode.rawValue)

		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
		timer.setEventHandler { [weak self] in
			guard let self,
			      let repeatKey = self.repeatingHardwareKey,
			      let surface = self.surface
			else { return }
			_ = self.handleKey(repeatKey, action: GHOSTTY_ACTION_REPEAT, surface: surface)
		}
		keyRepeatTimer = timer
		timer.resume()
	}

	private func stopKeyRepeat() {
		keyRepeatTimer?.cancel()
		keyRepeatTimer = nil
		repeatingHardwareKey = nil
		repeatingKeyCode = nil
	}

	private func hardwareKeyText(for key: UIKey) -> String? {
		let hasModifierShortcut = key.modifierFlags.intersection([.control, .alternate, .command]) != []
		if hasModifierShortcut { return nil }
		let chars = key.characters
		if chars.isEmpty || chars.hasPrefix("UIKeyInput") { return nil }
		if chars.count == 1, let scalar = chars.unicodeScalars.first {
			if scalar.value < 0x20 { return nil }  // control char
			if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }  // PUA
		}
		return chars
	}

	@discardableResult
	private func handleKey(_ key: UIKey, action: ghostty_input_action_e, surface: ghostty_surface_t)
		-> Bool
	{
		let mods = ghosttyMods(from: key.modifierFlags)
		let macKeycode = macVirtualKeycode(for: key)

		var event = ghostty_input_key_s()
		event.action = action
		event.keycode = macKeycode
		event.mods = mods
		event.composing = false

		// consumed_mods: everything except control and command (matches official ghostty)
		let consumedRaw = mods.rawValue & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
		event.consumed_mods = ghostty_input_mods_e(rawValue: consumedRaw)

		// unshifted_codepoint: codepoint with no modifiers applied
		let unshiftedChars = key.charactersIgnoringModifiers
		if !unshiftedChars.hasPrefix("UIKeyInput"),
		   let scalar = unshiftedChars.unicodeScalars.first,
		   scalar.value >= 0x20,
		   !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)
		{
			event.unshifted_codepoint = scalar.value
		} else {
			event.unshifted_codepoint = 0
		}

		// Release events never carry text
		guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
			event.text = nil
			return ghostty_surface_key(surface, event)
		}

		// Determine text to send.
		// For modifier shortcuts (ctrl/alt/cmd), don't send text — let ghostty encode.
		// For normal keys, send characters but filter out control chars and PUA range.
		let filteredText = hardwareKeyText(for: key)

		if let text = filteredText {
			return text.withCString { ptr in
				event.text = ptr
				return ghostty_surface_key(surface, event)
			}
		} else {
			event.text = nil
			return ghostty_surface_key(surface, event)
		}
	}

	// MARK: - Key Mapping

	private func ghosttyMods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
		var raw: UInt32 = 0
		if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
		if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
		if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
		if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
		return ghostty_input_mods_e(rawValue: raw)
	}

	/// Returns the macOS virtual keycode for a UIKey's HID usage, or 0xFFFF if unmapped.
	private func macVirtualKeycode(for key: UIKey) -> UInt32 {
		let usage = UInt16(key.keyCode.rawValue)
		return Self.hidToMacKeycode[usage] ?? 0xFFFF
	}

	// HID usage page → macOS virtual keycode, from ghostty's keycodes.zig (mac column).
	// Format: HID usage : mac vkeycode
	private nonisolated static let hidToMacKeycode: [UInt16: UInt32] = [
		// Letters (HID 0x04–0x1D)
		0x04: 0x0000,  // A
		0x05: 0x000B,  // B
		0x06: 0x0008,  // C
		0x07: 0x0002,  // D
		0x08: 0x000E,  // E
		0x09: 0x0003,  // F
		0x0A: 0x0005,  // G
		0x0B: 0x0004,  // H
		0x0C: 0x0022,  // I
		0x0D: 0x0026,  // J
		0x0E: 0x0028,  // K
		0x0F: 0x0025,  // L
		0x10: 0x002E,  // M
		0x11: 0x002D,  // N
		0x12: 0x001F,  // O
		0x13: 0x0023,  // P
		0x14: 0x000C,  // Q
		0x15: 0x000F,  // R
		0x16: 0x0001,  // S
		0x17: 0x0011,  // T
		0x18: 0x0020,  // U
		0x19: 0x0009,  // V
		0x1A: 0x000D,  // W
		0x1B: 0x0007,  // X
		0x1C: 0x0010,  // Y
		0x1D: 0x0006,  // Z

		// Digits (HID 0x1E–0x27)
		0x1E: 0x0012,  // 1
		0x1F: 0x0013,  // 2
		0x20: 0x0014,  // 3
		0x21: 0x0015,  // 4
		0x22: 0x0017,  // 5
		0x23: 0x0016,  // 6
		0x24: 0x001A,  // 7
		0x25: 0x001C,  // 8
		0x26: 0x0019,  // 9
		0x27: 0x001D,  // 0

		// Control keys
		0x28: 0x0024,  // Enter
		0x29: 0x0035,  // Escape
		0x2A: 0x0033,  // Backspace
		0x2B: 0x0030,  // Tab
		0x2C: 0x0031,  // Space
		0x2D: 0x001B,  // Minus
		0x2E: 0x0018,  // Equal
		0x2F: 0x0021,  // BracketLeft
		0x30: 0x001E,  // BracketRight
		0x31: 0x002A,  // Backslash
		0x33: 0x0029,  // Semicolon
		0x34: 0x0027,  // Quote
		0x35: 0x0032,  // Backquote
		0x36: 0x002B,  // Comma
		0x37: 0x002F,  // Period
		0x38: 0x002C,  // Slash
		0x39: 0x0039,  // CapsLock

		// Function keys (HID 0x3A–0x45)
		0x3A: 0x007A,  // F1
		0x3B: 0x0078,  // F2
		0x3C: 0x0063,  // F3
		0x3D: 0x0076,  // F4
		0x3E: 0x0060,  // F5
		0x3F: 0x0061,  // F6
		0x40: 0x0062,  // F7
		0x41: 0x0064,  // F8
		0x42: 0x0065,  // F9
		0x43: 0x006D,  // F10
		0x44: 0x0067,  // F11
		0x45: 0x006F,  // F12

		// Navigation
		0x49: 0x0072,  // Insert
		0x4A: 0x0073,  // Home
		0x4B: 0x0074,  // PageUp
		0x4C: 0x0075,  // Delete (Forward)
		0x4D: 0x0077,  // End
		0x4E: 0x0079,  // PageDown
		0x4F: 0x007C,  // ArrowRight
		0x50: 0x007B,  // ArrowLeft
		0x51: 0x007D,  // ArrowDown
		0x52: 0x007E,  // ArrowUp

		// Numpad
		0x53: 0x0047,  // NumLock
		0x54: 0x004B,  // NumpadDivide
		0x55: 0x0043,  // NumpadMultiply
		0x56: 0x004E,  // NumpadSubtract
		0x57: 0x0045,  // NumpadAdd
		0x58: 0x004C,  // NumpadEnter
		0x59: 0x0053,  // Numpad1
		0x5A: 0x0054,  // Numpad2
		0x5B: 0x0055,  // Numpad3
		0x5C: 0x0056,  // Numpad4
		0x5D: 0x0057,  // Numpad5
		0x5E: 0x0058,  // Numpad6
		0x5F: 0x0059,  // Numpad7
		0x60: 0x005B,  // Numpad8
		0x61: 0x005C,  // Numpad9
		0x62: 0x0052,  // Numpad0
		0x63: 0x0041,  // NumpadDecimal
		0x67: 0x0051,  // NumpadEqual

		// Modifiers
		0xE0: 0x003B,  // ControlLeft
		0xE1: 0x0038,  // ShiftLeft
		0xE2: 0x003A,  // AltLeft
		0xE3: 0x0037,  // MetaLeft (Command)
		0xE4: 0x003E,  // ControlRight
		0xE5: 0x003C,  // ShiftRight
		0xE6: 0x003D,  // AltRight
		0xE7: 0x0036,  // MetaRight (Command)

		// International
		0x64: 0x000A,  // IntlBackslash
		0x87: 0x005E,  // IntlRo
		0x89: 0x005D,  // IntlYen

		// Media
		0x7F: 0x004A,  // AudioVolumeMute
		0x80: 0x0048,  // AudioVolumeUp
		0x81: 0x0049,  // AudioVolumeDown
	]
}

enum ClipboardAccessAuthorization {
	private static let lock = NSLock()
	private static var pendingUserInitiatedPastes = [UnsafeMutableRawPointer: Date]()
	private static let lifetime: TimeInterval = 2

	static func noteUserInitiatedPaste(for view: TerminalView) {
		let pointer = Unmanaged.passUnretained(view).toOpaque()
		lock.lock()
		pendingUserInitiatedPastes[pointer] = Date().addingTimeInterval(lifetime)
		lock.unlock()
	}

	static func consumeUserInitiatedPaste(for pointer: UnsafeMutableRawPointer) -> Bool {
		lock.lock()
		defer { lock.unlock() }

		let now = Date()
		pendingUserInitiatedPastes = pendingUserInitiatedPastes.filter { $0.value > now }
		guard let expiry = pendingUserInitiatedPastes[pointer], expiry > now else {
			pendingUserInitiatedPastes.removeValue(forKey: pointer)
			return false
		}
		pendingUserInitiatedPastes.removeValue(forKey: pointer)
		return true
	}

	static func clear(for view: TerminalView) {
		let pointer = Unmanaged.passUnretained(view).toOpaque()
		lock.lock()
		pendingUserInitiatedPastes.removeValue(forKey: pointer)
		lock.unlock()
	}
}
#endif
