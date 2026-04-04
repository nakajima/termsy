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

	// MARK: - Lifecycle

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .black
		isUserInteractionEnabled = true
		isMultipleTouchEnabled = false

		let scrollRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
		scrollRecognizer.minimumNumberOfTouches = 2
		scrollRecognizer.maximumNumberOfTouches = 2
		addGestureRecognizer(scrollRecognizer)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) { fatalError() }

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
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
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
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let surface else {
			super.touchesCancelled(touches, with: event)
			return
		}
		ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
	}

	@objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
		guard let surface else { return }
		let velocity = recognizer.translation(in: self)
		recognizer.setTranslation(.zero, in: self)
		// Negate Y so swiping up scrolls up (positive dy = scroll up in ghostty)
		ghostty_surface_mouse_scroll(surface, velocity.x, -velocity.y, 0)
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
		var event = ghostty_input_key_s()
		event.action = GHOSTTY_ACTION_PRESS
		event.keycode = GHOSTTY_KEY_BACKSPACE.rawValue
		event.mods = GHOSTTY_MODS_NONE
		"\u{7F}".withCString { ptr in
			event.text = ptr
			ghostty_surface_key(surface, event)
		}
	}

	// MARK: - Hardware Keyboard

	override func pressesBegan(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key, let surface else { continue }
			// Suppress UIKit's insertText for all keys we handle here.
			// Enter, backspace, etc. would otherwise double-send.
			hardwareKeyHandled = true
			handleKey(key, action: GHOSTTY_ACTION_PRESS, surface: surface)
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key, let surface else { continue }
			handleKey(key, action: GHOSTTY_ACTION_RELEASE, surface: surface)
		}
		hardwareKeyHandled = false
	}

	@discardableResult
	private func handleKey(_ key: UIKey, action: ghostty_input_action_e, surface: ghostty_surface_t) -> Bool {
		let mods = ghosttyMods(from: key.modifierFlags)
		let ghosttyKey = ghosttyKeyCode(for: key)
		if action == GHOSTTY_ACTION_PRESS {
			print("[KEY] hid=0x\(String(key.keyCode.rawValue, radix: 16)) ghostty=\(ghosttyKey.rawValue) chars=\(key.characters.debugDescription) charsIM=\(key.charactersIgnoringModifiers.debugDescription)")
		}

		var event = ghostty_input_key_s()
		event.action = action
		event.keycode = ghosttyKey.rawValue
		event.mods = mods
		event.consumed_mods = GHOSTTY_MODS_NONE
		event.composing = false

		// Set unshifted_codepoint from the character without modifiers
		if let scalar = key.charactersIgnoringModifiers.unicodeScalars.first {
			event.unshifted_codepoint = scalar.value
		}

		guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
			return ghostty_surface_key(surface, event)
		}

		// Use charactersIgnoringModifiers for ctrl/alt/cmd so the encoder
		// sees the unmodified letter (e.g. "a" not "\x01" for ctrl-a).
		// For unmodified keys, use characters directly (includes "\r" for
		// enter, "\u{08}" for backspace, etc.).
		let hasModifier = key.modifierFlags.intersection([.control, .alternate, .command]) != []
		let chars = hasModifier ? key.charactersIgnoringModifiers : key.characters

		// Only filter UIKit's synthetic function key names ("UIKeyInputLeftArrow" etc.)
		if chars.hasPrefix("UIKeyInput") || chars.isEmpty {
			event.text = nil
			return ghostty_surface_key(surface, event)
		} else {
			return chars.withCString { ptr in
				event.text = ptr
				return ghostty_surface_key(surface, event)
			}
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

	private func ghosttyKeyCode(for key: UIKey) -> ghostty_input_key_e {
		let usage = UInt16(key.keyCode.rawValue)
		return Self.hidToGhostty[usage] ?? GHOSTTY_KEY_UNIDENTIFIED
	}

	private nonisolated static let hidToGhostty: [UInt16: ghostty_input_key_e] = {
		var m: [UInt16: ghostty_input_key_e] = [:]
		let letters: [ghostty_input_key_e] = [
			GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D,
			GHOSTTY_KEY_E, GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H,
			GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
			GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P,
			GHOSTTY_KEY_Q, GHOSTTY_KEY_R, GHOSTTY_KEY_S, GHOSTTY_KEY_T,
			GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
			GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
		]
		for (i, k) in letters.enumerated() {
			m[UInt16(0x04 + i)] = k
		}
		let digits: [ghostty_input_key_e] = [
			GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3,
			GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6,
			GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9,
			GHOSTTY_KEY_DIGIT_0,
		]
		for (i, k) in digits.enumerated() {
			m[UInt16(0x1E + i)] = k
		}
		let fkeys: [ghostty_input_key_e] = [
			GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4,
			GHOSTTY_KEY_F5, GHOSTTY_KEY_F6, GHOSTTY_KEY_F7, GHOSTTY_KEY_F8,
			GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
		]
		for (i, k) in fkeys.enumerated() {
			m[UInt16(0x3A + i)] = k
		}
		m[0x28] = GHOSTTY_KEY_ENTER
		m[0x29] = GHOSTTY_KEY_ESCAPE
		m[0x2A] = GHOSTTY_KEY_BACKSPACE
		m[0x2B] = GHOSTTY_KEY_TAB
		m[0x2C] = GHOSTTY_KEY_SPACE
		m[0x2D] = GHOSTTY_KEY_MINUS
		m[0x2E] = GHOSTTY_KEY_EQUAL
		m[0x2F] = GHOSTTY_KEY_BRACKET_LEFT
		m[0x30] = GHOSTTY_KEY_BRACKET_RIGHT
		m[0x31] = GHOSTTY_KEY_BACKSLASH
		m[0x33] = GHOSTTY_KEY_SEMICOLON
		m[0x34] = GHOSTTY_KEY_QUOTE
		m[0x35] = GHOSTTY_KEY_BACKQUOTE
		m[0x36] = GHOSTTY_KEY_COMMA
		m[0x37] = GHOSTTY_KEY_PERIOD
		m[0x38] = GHOSTTY_KEY_SLASH
		m[0x49] = GHOSTTY_KEY_INSERT
		m[0x4A] = GHOSTTY_KEY_HOME
		m[0x4B] = GHOSTTY_KEY_PAGE_UP
		m[0x4C] = GHOSTTY_KEY_DELETE
		m[0x4D] = GHOSTTY_KEY_END
		m[0x4E] = GHOSTTY_KEY_PAGE_DOWN
		m[0x4F] = GHOSTTY_KEY_ARROW_RIGHT
		m[0x50] = GHOSTTY_KEY_ARROW_LEFT
		m[0x51] = GHOSTTY_KEY_ARROW_DOWN
		m[0x52] = GHOSTTY_KEY_ARROW_UP
		return m
	}()
}
