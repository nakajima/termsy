#if os(macOS)
	import AppKit
	import TermsyGhosttyCore

	@MainActor
	final class MacTerminalView: NSView {
		private(set) nonisolated(unsafe) var surface: ghostty_surface_t?
		private var ghosttySurfaceUserdata: GhosttySurfaceUserdata?

		var onWrite: ((Data) -> Void)?
		var onResize: ((UInt16, UInt16) -> Void)?
		var onTitleChange: ((String) -> Void)?
		var onRenameTabRequest: (() -> Void)?

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

		private var hostManagedSurface: HostManagedSurface?
		private var displayTimer: Timer?
		private var pendingClipboardConfirmations = [PendingClipboardConfirmation]()
		private var activeClipboardConfirmation: PendingClipboardConfirmation?
		private var clipboardAlert: NSAlert?
		private var trackingAreaRef: NSTrackingArea?
		private var bufferedTerminalData = Data()
		private var pendingProcessExit: (code: UInt32, runtimeMs: UInt64)?
		private var keyTextAccumulator: [String]?
		private var markedTextState = MacMarkedTextState()
		private var handledMarkedTextCommand = false
		private var isDisplayActive = false
		private var lastMouseLocation: CGPoint?

		override var acceptsFirstResponder: Bool { true }
		override var canBecomeKeyView: Bool { true }

		override init(frame frameRect: NSRect) {
			super.init(frame: frameRect)
			wantsLayer = true
			applyTheme(TerminalTheme.current.appTheme)
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) { fatalError() }

		deinit {
			displayTimer?.invalidate()
		}

		func applyTheme(_ theme: AppTheme) {
			let opacity = TerminalBackgroundSettings.storedEffectiveOpacity()
			layer?.backgroundColor = theme.backgroundUIColor.withAlphaComponent(CGFloat(opacity)).cgColor
		}

		func start() {
			if surface == nil {
				guard let app = MacGhosttyApp.shared.app else { return }
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
					ghosttySurfaceUserdata = MacGhosttyApp.shared.makeSurfaceUserdata(
						payload: Unmanaged.passUnretained(self).toOpaque(),
						object: self
					)
				}

				let scale = resolvedScale()
				surface = hostManagedSurface?.start(
					app: app,
					surfaceUserdata: ghosttySurfaceUserdata?.opaquePointer,
					scaleFactor: Double(scale),
					fontSize: TerminalFontSettings.size
				) { cfg in
					cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
					cfg.platform = ghostty_platform_u(
						macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
					)
				}
			}

			syncSize()
			flushBufferedTerminalStateIfNeeded()
			applyDisplayActivity()
		}

		func stop() {
			stopDisplayTimer()
			markedTextState.clear()
			handledMarkedTextCommand = false
			keyTextAccumulator = nil
			lastMouseLocation = nil
			denyOutstandingClipboardReadConfirmations()
			if let surface {
				ghostty_surface_set_focus(surface, false)
			}
			hostManagedSurface?.free()
			hostManagedSurface = nil
			surface = nil
			bufferedTerminalData.removeAll(keepingCapacity: false)
			pendingProcessExit = nil
		}

		func feedData(_ data: Data) {
			guard !data.isEmpty else { return }
			guard surface != nil else {
				bufferedTerminalData.append(data)
				return
			}
			hostManagedSurface?.write(data)
		}

		func processExited(code: UInt32 = 0, runtimeMs: UInt64 = 0) {
			guard surface != nil else {
				pendingProcessExit = (code, runtimeMs)
				return
			}
			hostManagedSurface?.processExit(code: code, runtimeMs: runtimeMs)
		}

		var needsCloseConfirmation: Bool {
			guard let surface else { return false }
			return ghostty_surface_needs_confirm_quit(surface)
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

			guard let window else {
				resolveClipboardConfirmation(confirmation, allowed: false)
				return
			}

			let alert = NSAlert()
			alert.alertStyle = confirmation.kind == .paste ? .warning : .informational
			alert.messageText = confirmation.kind.title
			alert.informativeText = confirmation.kind.formattedMessage(for: confirmation.text)
			alert.addButton(withTitle: confirmation.kind.allowButtonTitle)
			alert.addButton(withTitle: confirmation.kind.denyButtonTitle)
			clipboardAlert = alert
			alert.beginSheetModal(for: window) { [weak self] response in
				self?.resolveClipboardConfirmation(confirmation, allowed: response == .alertFirstButtonReturn)
			}
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
					let pasteboard = NSPasteboard.general
					pasteboard.clearContents()
					pasteboard.setString(confirmation.text, forType: .string)
				}
			}

			finishClipboardConfirmation(confirmation)
		}

		private func finishClipboardConfirmation(_ confirmation: PendingClipboardConfirmation) {
			guard activeClipboardConfirmation?.id == confirmation.id else { return }
			activeClipboardConfirmation = nil
			clipboardAlert = nil
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
			if let alert = clipboardAlert,
			   let sheetParent = alert.window.sheetParent
			{
				sheetParent.endSheet(alert.window, returnCode: .cancel)
			}
			activeClipboardConfirmation = nil
			pendingClipboardConfirmations.removeAll()
			clipboardAlert = nil
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

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			updateTrackingAreas()
			if window != nil {
				window?.acceptsMouseMovedEvents = true
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

		override func viewDidChangeBackingProperties() {
			super.viewDidChangeBackingProperties()
			updateDisplayScale()
			syncSize()
		}

		override func layout() {
			super.layout()
			updateDisplayScale()
			updateSublayerFrames()
			syncSize()
		}

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			if let trackingAreaRef {
				removeTrackingArea(trackingAreaRef)
			}
			let trackingAreaRef = NSTrackingArea(
				rect: bounds,
				options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
				owner: self,
				userInfo: nil
			)
			addTrackingArea(trackingAreaRef)
			self.trackingAreaRef = trackingAreaRef
		}

		override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
			true
		}

		private func resolvedScale() -> CGFloat {
			window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
		}

		private func updateDisplayScale() {
			let scale = resolvedScale()
			layer?.contentsScale = scale
			for sublayer in layer?.sublayers ?? [] {
				sublayer.contentsScale = scale
			}
		}

		private func updateSublayerFrames() {
			let scale = resolvedScale()
			layer?.contentsScale = scale
			for sublayer in layer?.sublayers ?? [] {
				sublayer.frame = bounds
				sublayer.contentsScale = scale
			}
		}

		private func syncSize() {
			guard let surface else { return }
			let scale = resolvedScale()
			let width = UInt32((bounds.width * scale).rounded(.down))
			let height = UInt32((bounds.height * scale).rounded(.down))
			guard width > 0, height > 0 else { return }
			ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
			ghostty_surface_set_size(surface, width, height)
		}

		private func flushBufferedTerminalStateIfNeeded() {
			guard surface != nil else { return }
			if !bufferedTerminalData.isEmpty {
				let data = bufferedTerminalData
				bufferedTerminalData.removeAll(keepingCapacity: false)
				hostManagedSurface?.write(data)
			}
			if let pendingProcessExit {
				self.pendingProcessExit = nil
				hostManagedSurface?.processExit(code: pendingProcessExit.code, runtimeMs: pendingProcessExit.runtimeMs)
			}
		}

		private func applyDisplayActivity() {
			let shouldBeActive = isDisplayActive && window != nil

			guard let surface else {
				if !shouldBeActive {
					stopDisplayTimer()
				}
				return
			}

			if shouldBeActive {
				startDisplayTimer()
				ghostty_surface_set_focus(surface, true)
				if window?.firstResponder !== self {
					window?.makeFirstResponder(self)
				}
				ghostty_surface_refresh(surface)
				ghostty_surface_draw(surface)
			} else {
				stopDisplayTimer()
				ghostty_surface_set_focus(surface, false)
			}
		}

		private func startDisplayTimer() {
			guard displayTimer == nil else { return }
			let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.displayTick()
				}
			}
			RunLoop.main.add(timer, forMode: .common)
			displayTimer = timer
		}

		private func stopDisplayTimer() {
			displayTimer?.invalidate()
			displayTimer = nil
		}

		private func displayTick() {
			MacGhosttyApp.shared.tick()
			guard let surface else { return }
			ghostty_surface_refresh(surface)
			ghostty_surface_draw(surface)
			updateSublayerFrames()
		}

		private func sendPreedit(_ text: String) {
			guard let surface else { return }
			text.withCString { ptr in
				ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
			}
		}

		private func sendDirectText(_ text: String) {
			guard let surface else { return }
			text.withCString { ptr in
				ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
			}
		}

		private func sendKeyAction(
			_ action: ghostty_input_action_e,
			event: NSEvent,
			translationEvent: NSEvent? = nil,
			text: String? = nil,
			composing: Bool = false
		) -> Bool {
			guard let surface else { return false }

			var keyEvent = event.termsyGhosttyKeyEvent(
				action,
				translationMods: translationEvent?.modifierFlags
			)
			keyEvent.composing = composing

			if let text, text.count > 0,
			   let codepoint = text.utf8.first,
			   codepoint >= 0x20
			{
				return text.withCString { ptr in
					keyEvent.text = ptr
					return ghostty_surface_key(surface, keyEvent)
				}
			}

			return ghostty_surface_key(surface, keyEvent)
		}

		private func modifierAction(for event: NSEvent) -> ghostty_input_action_e? {
			let mod: UInt32
			switch event.keyCode {
			case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
			case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
			case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
			case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
			case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
			default: return nil
			}

			let mods = MacGhosttyInput.ghosttyMods(event.modifierFlags)
			if mods.rawValue & mod == 0 {
				return GHOSTTY_ACTION_RELEASE
			}

			let sidePressed: Bool
			switch event.keyCode {
			case 0x3C:
				sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
			case 0x3E:
				sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
			case 0x3D:
				sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
			case 0x36:
				sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
			default:
				sidePressed = true
			}

			return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
		}

		private func mousePoint(from event: NSEvent) -> CGPoint {
			let point = convert(event.locationInWindow, from: nil)
			return CGPoint(x: point.x, y: bounds.height - point.y)
		}

		private func sendMousePosition(_ point: CGPoint, event: NSEvent) {
			guard let surface else { return }
			guard lastMouseLocation != point else { return }
			lastMouseLocation = point
			ghostty_surface_mouse_pos(surface, point.x, point.y, MacGhosttyInput.ghosttyMods(event.modifierFlags))
		}

		private func sendMouseButton(
			_ state: ghostty_input_mouse_state_e,
			button: ghostty_input_mouse_button_e,
			event: NSEvent
		) {
			guard let surface else { return }
			let point = mousePoint(from: event)
			sendMousePosition(point, event: event)
			_ = ghostty_surface_mouse_button(
				surface,
				state,
				button,
				MacGhosttyInput.ghosttyMods(event.modifierFlags)
			)
		}

		private var hasTerminalSelection: Bool {
			guard let surface else { return false }
			return ghostty_surface_has_selection(surface)
		}

		private var canPasteFromClipboard: Bool {
			NSPasteboard.general.string(forType: .string)?.isEmpty == false
		}

		@discardableResult
		private func performBindingAction(_ action: String) -> Bool {
			guard let surface else { return false }
			return action.withCString { cString in
				ghostty_surface_binding_action(surface, cString, UInt(action.utf8.count))
			}
		}

		override func keyDown(with event: NSEvent) {
			guard let surface else {
				interpretKeyEvents([event])
				return
			}

			let translationModsGhostty = MacGhosttyInput.eventModifierFlags(
				mods: ghostty_surface_key_translation_mods(
					surface,
					MacGhosttyInput.ghosttyMods(event.modifierFlags)
				)
			)

			var translationMods = event.modifierFlags
			for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
				if translationModsGhostty.contains(flag) {
					translationMods.insert(flag)
				} else {
					translationMods.remove(flag)
				}
			}

			let translationEvent: NSEvent
			if translationMods == event.modifierFlags {
				translationEvent = event
			} else {
				translationEvent = NSEvent.keyEvent(
					with: event.type,
					location: event.locationInWindow,
					modifierFlags: translationMods,
					timestamp: event.timestamp,
					windowNumber: event.windowNumber,
					context: nil,
					characters: event.characters(byApplyingModifiers: translationMods) ?? "",
					charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
					isARepeat: event.isARepeat,
					keyCode: event.keyCode
				) ?? event
			}

			let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
			let markedTextBefore = markedTextState.hasMarkedText
			handledMarkedTextCommand = false
			keyTextAccumulator = []
			defer {
				keyTextAccumulator = nil
				handledMarkedTextCommand = false
			}

			interpretKeyEvents([translationEvent])

			if handledMarkedTextCommand {
				return
			}

			if let collected = keyTextAccumulator, !collected.isEmpty {
				for text in collected {
					_ = sendKeyAction(action, event: event, translationEvent: translationEvent, text: text)
				}
				return
			}

			_ = sendKeyAction(
				action,
				event: event,
				translationEvent: translationEvent,
				text: translationEvent.termsyCharacters,
				composing: markedTextState.hasMarkedText || markedTextBefore
			)
		}

		override func keyUp(with event: NSEvent) {
			_ = sendKeyAction(GHOSTTY_ACTION_RELEASE, event: event)
		}

		override func flagsChanged(with event: NSEvent) {
			guard !markedTextState.hasMarkedText else { return }
			guard let action = modifierAction(for: event) else { return }
			_ = sendKeyAction(action, event: event)
		}

		override func doCommand(by selector: Selector) {
			guard markedTextState.hasMarkedText else { return }

			switch selector {
			case #selector(NSResponder.deleteBackward(_:)):
				if markedTextState.deleteBackward() {
					sendPreedit(markedTextState.text ?? "")
					handledMarkedTextCommand = true
				}
			case #selector(NSResponder.cancelOperation(_:)):
				markedTextState.clear()
				sendPreedit("")
				handledMarkedTextCommand = true
			default:
				break
			}
		}

		override func mouseDown(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event)
		}

		override func mouseUp(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event)
		}

		override func rightMouseDown(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event)
		}

		override func rightMouseUp(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event)
		}

		override func otherMouseDown(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE, event: event)
		}

		override func otherMouseUp(with event: NSEvent) {
			sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE, event: event)
		}

		override func mouseMoved(with event: NSEvent) {
			sendMousePosition(mousePoint(from: event), event: event)
		}

		override func mouseDragged(with event: NSEvent) {
			mouseMoved(with: event)
		}

		override func rightMouseDragged(with event: NSEvent) {
			mouseMoved(with: event)
		}

		override func otherMouseDragged(with event: NSEvent) {
			mouseMoved(with: event)
		}

		override func scrollWheel(with event: NSEvent) {
			guard let surface else { return }
			let point = mousePoint(from: event)
			sendMousePosition(point, event: event)
			ghostty_surface_mouse_scroll(
				surface,
				event.scrollingDeltaX,
				event.scrollingDeltaY,
				MacGhosttyInput.scrollMods(
					precision: event.hasPreciseScrollingDeltas,
					momentumPhase: event.momentumPhase
				)
			)
		}

		func canPerformAction(_ action: Selector, withSender _: Any?) -> Bool {
			switch action {
			case #selector(copy(_:)):
				return hasTerminalSelection
			case #selector(paste(_:)):
				return canPasteFromClipboard
			case #selector(selectAll(_:)):
				return surface != nil
			case #selector(renameTab(_:)):
				return true
			default:
				return false
			}
		}

		@IBAction func copy(_: Any?) {
			_ = performBindingAction("copy_to_clipboard")
		}

		@IBAction func paste(_: Any?) {
			_ = performBindingAction("paste_from_clipboard")
		}

		@IBAction override func selectAll(_: Any?) {
			_ = performBindingAction("select_all")
		}

		@IBAction func renameTab(_: Any?) {
			onRenameTabRequest?()
		}

		override func menu(for _: NSEvent) -> NSMenu? {
			guard surface != nil else { return nil }
			let menu = NSMenu()
			let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
			copy.isEnabled = hasTerminalSelection
			copy.target = self
			let paste = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
			paste.isEnabled = canPasteFromClipboard
			paste.target = self
			menu.addItem(.separator())
			let selectAll = menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
			selectAll.target = self
			menu.addItem(.separator())
			let rename = menu.addItem(withTitle: "Rename Tab", action: #selector(renameTab(_:)), keyEquivalent: "")
			rename.target = self
			return menu
		}
	}

	extension MacTerminalView: @preconcurrency NSTextInputClient {
		func insertText(_ string: Any, replacementRange _: NSRange) {
			let text: String
			if let attributed = string as? NSAttributedString {
				text = attributed.string
			} else if let string = string as? String {
				text = string
			} else {
				return
			}

			markedTextState.clear()
			sendPreedit("")

			if keyTextAccumulator != nil {
				keyTextAccumulator?.append(text)
			} else {
				sendDirectText(text)
			}
		}

		func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
			let text: String
			if let attributed = string as? NSAttributedString {
				text = attributed.string
			} else if let string = string as? String {
				text = string
			} else {
				return
			}

			markedTextState.setMarkedText(text, selectedRange: selectedRange)
			sendPreedit(markedTextState.text ?? "")
		}

		func unmarkText() {
			markedTextState.clear()
			sendPreedit("")
		}

		func selectedRange() -> NSRange {
			markedTextState.currentSelectedRange
		}

		func markedRange() -> NSRange {
			markedTextState.markedRange
		}

		func hasMarkedText() -> Bool {
			markedTextState.hasMarkedText
		}

		func attributedSubstring(
			forProposedRange range: NSRange,
			actualRange: NSRangePointer?
		) -> NSAttributedString? {
			guard markedTextState.hasMarkedText else {
				actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
				return nil
			}

			let length = markedTextState.documentLength
			let location = min(max(range.location, 0), length)
			let end = min(max(range.location + range.length, location), length)
			let clampedRange = NSRange(location: location, length: end - location)
			actualRange?.pointee = clampedRange

			guard let text = markedTextState.text(in: clampedRange) else {
				return nil
			}
			return NSAttributedString(string: text)
		}

		func validAttributesForMarkedText() -> [NSAttributedString.Key] {
			[.underlineStyle, .backgroundColor]
		}

		func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
			guard let surface else { return .zero }
			actualRange?.pointee = range

			var x = 0.0
			var y = 0.0
			var width = 0.0
			var height = 0.0
			ghostty_surface_ime_point(surface, &x, &y, &width, &height)

			let viewRect = NSRect(
				x: x,
				y: bounds.height - y - height,
				width: width,
				height: height
			)

			guard let window else { return viewRect }
			let windowRect = convert(viewRect, to: nil)
			return window.convertToScreen(windowRect)
		}

		func characterIndex(for _: NSPoint) -> Int {
			NSNotFound
		}
	}

	private struct MacMarkedTextState {
		private(set) var text: String?
		private(set) var selectedRange = NSRange(location: 0, length: 0)

		var hasMarkedText: Bool {
			guard let text else { return false }
			return !text.isEmpty
		}

		var documentLength: Int {
			text?.utf16.count ?? 0
		}

		var markedRange: NSRange {
			guard hasMarkedText else {
				return NSRange(location: NSNotFound, length: 0)
			}
			return NSRange(location: 0, length: documentLength)
		}

		var currentSelectedRange: NSRange {
			guard hasMarkedText else {
				return NSRange(location: NSNotFound, length: 0)
			}
			return selectedRange
		}

		mutating func setMarkedText(_ text: String?, selectedRange: NSRange) {
			let normalizedText = text.flatMap { $0.isEmpty ? nil : $0 }
			self.text = normalizedText
			self.selectedRange = clampedSelectedRange(selectedRange, in: normalizedText)
		}

		mutating func clear() {
			text = nil
			selectedRange = NSRange(location: 0, length: 0)
		}

		mutating func deleteBackward() -> Bool {
			guard let text, !text.isEmpty else { return false }

			let mutableText = NSMutableString(string: text)
			if selectedRange.length > 0 {
				mutableText.deleteCharacters(in: selectedRange)
				selectedRange = NSRange(location: selectedRange.location, length: 0)
			} else if selectedRange.location > 0 {
				let deletionRange = NSRange(location: selectedRange.location - 1, length: 1)
				mutableText.deleteCharacters(in: deletionRange)
				selectedRange = NSRange(location: deletionRange.location, length: 0)
			} else {
				return true
			}

			let updatedText = mutableText as String
			self.text = updatedText.isEmpty ? nil : updatedText
			if self.text == nil {
				selectedRange = NSRange(location: 0, length: 0)
			}
			return true
		}

		func text(in range: NSRange) -> String? {
			guard let text else {
				return range.length == 0 ? "" : nil
			}

			let nsText = text as NSString
			guard range.location >= 0, range.length >= 0 else { return nil }
			guard range.location + range.length <= nsText.length else { return nil }
			return nsText.substring(with: range)
		}

		private func clampedSelectedRange(_ range: NSRange, in text: String?) -> NSRange {
			let length = text?.utf16.count ?? 0
			let location = min(max(range.location, 0), length)
			let end = min(max(range.location + range.length, location), length)
			return NSRange(location: location, length: end - location)
		}
	}

	private enum MacGhosttyInput {
		static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
			var flags = NSEvent.ModifierFlags(rawValue: 0)
			if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
			if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
			if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
			if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
			return flags
		}

		static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
			var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
			if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
			if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
			if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
			if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
			if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

			let rawFlags = flags.rawValue
			if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
			if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
			if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
			if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

			return ghostty_input_mods_e(mods)
		}

		static func scrollMods(
			precision: Bool,
			momentumPhase: NSEvent.Phase
		) -> ghostty_input_scroll_mods_t {
			var value: Int32 = 0
			if precision { value |= 1 }
			value |= momentum(for: momentumPhase).rawValue << 1
			return value
		}

		private static func momentum(for phase: NSEvent.Phase) -> Momentum {
			if phase.contains(.began) { return .began }
			if phase.contains(.stationary) { return .stationary }
			if phase.contains(.changed) { return .changed }
			return .none
		}

		private enum Momentum: Int32 {
			case none = 0
			case began = 1
			case stationary = 2
			case changed = 3
		}
	}

	private extension NSEvent {
		func termsyGhosttyKeyEvent(
			_ action: ghostty_input_action_e,
			translationMods: NSEvent.ModifierFlags? = nil
		) -> ghostty_input_key_s {
			var keyEvent = ghostty_input_key_s()
			keyEvent.action = action
			keyEvent.keycode = UInt32(keyCode)
			keyEvent.text = nil
			keyEvent.composing = false
			keyEvent.mods = MacGhosttyInput.ghosttyMods(modifierFlags)
			keyEvent.consumed_mods = MacGhosttyInput.ghosttyMods(
				(translationMods ?? modifierFlags).subtracting([.control, .command])
			)
			keyEvent.unshifted_codepoint = 0
			if type == .keyDown || type == .keyUp,
			   let chars = characters(byApplyingModifiers: []),
			   let codepoint = chars.unicodeScalars.first
			{
				keyEvent.unshifted_codepoint = codepoint.value
			}
			return keyEvent
		}

		var termsyCharacters: String? {
			guard let characters else { return nil }

			if characters.count == 1,
			   let scalar = characters.unicodeScalars.first
			{
				if scalar.value < 0x20 {
					return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
				}

				if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
					return nil
				}
			}

			return characters
		}
	}
#endif
