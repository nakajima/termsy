//
//  TerminalView.swift
//  Termsy
//
//  UIView hosting a ghostty_surface_t with host-managed I/O.
//  Keyboard input follows the libghostty API contract:
//  text field carries the unmodified character, NULL for C0/function keys.
//  The encoder derives ctrl/alt sequences from the logical key + mods.
//

import GhosttyKit
import UIKit

@MainActor
final class TerminalView: UIView, UIKeyInput {
	private var surface: ghostty_surface_t?
	private var displayLink: CADisplayLink?
	private var hardwareKeyHandled = false

	/// Called when the terminal produces bytes (user input, query responses).
	var onWrite: ((Data) -> Void)?

	/// Called when the terminal grid resizes.
	var onResize: ((UInt16, UInt16) -> Void)?

	/// Called when the user requests closing the current tab.
	var onCloseTabRequest: (() -> Void)?

	/// Called when the user requests opening a new tab.
	var onNewTabRequest: (() -> Void)?

	// MARK: - Lifecycle

	override init(frame: CGRect) {
		super.init(frame: frame)
		applyTheme(TerminalTheme.current.appTheme)
		isUserInteractionEnabled = true
		isMultipleTouchEnabled = false

		let touchScrollRecognizer = UIPanGestureRecognizer(
			target: self, action: #selector(handleScroll(_:)))
		touchScrollRecognizer.minimumNumberOfTouches = 2
		touchScrollRecognizer.maximumNumberOfTouches = 2
		addGestureRecognizer(touchScrollRecognizer)

		if #available(iOS 13.4, *) {
			let indirectScrollRecognizer = UIPanGestureRecognizer(
				target: self, action: #selector(handleScroll(_:)))
			indirectScrollRecognizer.allowedScrollTypesMask = [.continuous, .discrete]
			indirectScrollRecognizer.allowedTouchTypes = [
				NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
			]
			addGestureRecognizer(indirectScrollRecognizer)
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) { fatalError() }

	func applyTheme(_ theme: AppTheme) {
		backgroundColor = theme.backgroundUIColor
	}

	func start() {
		guard surface == nil, let app = GhosttyApp.shared.app else { return }

		var cfg = ghostty_surface_config_new()
		cfg.platform_tag = GHOSTTY_PLATFORM_IOS
		cfg.platform = ghostty_platform_u(
			ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
		)
		cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
		cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
		cfg.receive_userdata = Unmanaged.passUnretained(self).toOpaque()
		cfg.receive_buffer = { userdata, ptr, len in
			guard let userdata, let ptr else { return }
			let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
			let data = Data(bytes: ptr, count: len)
			view.onWrite?(data)
		}
		cfg.receive_resize = { userdata, cols, rows, _, _ in
			guard let userdata else { return }
			let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
			view.onResize?(cols, rows)
		}

		let scale = resolvedScale()
		cfg.scale_factor = Double(scale)
		cfg.font_size = 14

		surface = ghostty_surface_new(app, &cfg)
		guard surface != nil else { return }

		ghostty_surface_set_focus(surface, true)
		startDisplayLink()
	}

	func stop() {
		stopDisplayLink()
		if let s = surface {
			ghostty_surface_set_focus(s, false)
			ghostty_surface_free(s)
			surface = nil
		}
	}

	func feedData(_ data: Data) {
		guard let surface else { return }
		data.withUnsafeBytes { buf in
			guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			ghostty_surface_write_buffer(surface, ptr, UInt(buf.count))
		}
	}

	func processExited(code: UInt32 = 0, runtimeMs: UInt64 = 0) {
		guard let surface else { return }
		ghostty_surface_process_exit(surface, code, runtimeMs)
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
				self.becomeFirstResponder()
			}
		} else {
			stopDisplayLink()
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		updateSublayerFrames()
		syncSize()
	}

	private func resolvedScale() -> CGFloat {
		window?.screen.nativeScale ?? UIScreen.main.nativeScale
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
		guard let sublayers = layer.sublayers else { return }
		for sublayer in sublayers {
			sublayer.frame = bounds
			sublayer.contentsScale = scale
		}
	}

	/// Call from the parent when the view's bounds change externally.
	func forceSyncSize() {
		syncSize()
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
		let link = CADisplayLink(target: self, selector: #selector(tick))
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	private func stopDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
	}

	@objc private func tick() {
		GhosttyApp.shared.tick()
		guard let surface else { return }
		ghostty_surface_refresh(surface)
		ghostty_surface_draw(surface)
		updateSublayerFrames()
	}

	// MARK: - Touch / Mouse

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let surface, let touch = touches.first else {
			super.touchesBegan(touches, with: event)
			return
		}
		let pos = touch.location(in: self)
		ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
		ghostty_surface_mouse_button(
			surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let surface, let touch = touches.first else {
			super.touchesMoved(touches, with: event)
			return
		}
		let pos = touch.location(in: self)
		ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let surface, let touch = touches.first else {
			super.touchesEnded(touches, with: event)
			return
		}
		let pos = touch.location(in: self)
		ghostty_surface_mouse_pos(surface, pos.x, pos.y, GHOSTTY_MODS_NONE)
		ghostty_surface_mouse_button(
			surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let surface else {
			super.touchesCancelled(touches, with: event)
			return
		}
		ghostty_surface_mouse_button(
			surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	@objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
		guard let surface else { return }
		let delta = recognizer.translation(in: self)
		recognizer.setTranslation(.zero, in: self)
		guard delta != .zero else { return }
		let adjustedDelta = TerminalScrollSettings.adjustedDelta(from: delta)
		ghostty_surface_mouse_scroll(surface, adjustedDelta.x, adjustedDelta.y, 0)
	}

	// MARK: - First Responder

	override var canBecomeFirstResponder: Bool { true }
	var hasText: Bool { true }

	// MARK: - UIKeyInput

	func insertText(_ text: String) {
		guard let surface else { return }
		guard !hardwareKeyHandled else {
			hardwareKeyHandled = false
			return
		}
		// Software keyboard path — send text directly.
		text.withCString { ptr in
			ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
		}
	}

	func deleteBackward() {
		guard let surface else { return }
		guard !hardwareKeyHandled else {
			hardwareKeyHandled = false
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
			if key.modifierFlags.contains(.command) {
				if key.charactersIgnoringModifiers.compare("w", options: .caseInsensitive) == .orderedSame {
					onCloseTabRequest?()
					continue
				}
				if key.charactersIgnoringModifiers.compare("t", options: .caseInsensitive) == .orderedSame {
					onNewTabRequest?()
					continue
				}
			}
			// Suppress UIKit's insertText for all keys we handle here.
			// Enter, backspace, etc. would otherwise double-send.
			hardwareKeyHandled = true
			handleKey(key, action: GHOSTTY_ACTION_PRESS, surface: surface)
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key, let surface else { continue }
			if key.modifierFlags.contains(.command),
			   ["w", "t"].contains(where: {
				key.charactersIgnoringModifiers.compare($0, options: .caseInsensitive) == .orderedSame
			}) {
				continue
			}
			handleKey(key, action: GHOSTTY_ACTION_RELEASE, surface: surface)
		}
		hardwareKeyHandled = false
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
		let hasModifierShortcut = key.modifierFlags.intersection([.control, .alternate, .command]) != []
		let filteredText: String? = {
			if hasModifierShortcut { return nil }
			let chars = key.characters
			if chars.isEmpty || chars.hasPrefix("UIKeyInput") { return nil }
			if chars.count == 1, let scalar = chars.unicodeScalars.first {
				if scalar.value < 0x20 { return nil }  // control char
				if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }  // PUA
			}
			return chars
		}()

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
