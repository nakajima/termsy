#if canImport(UIKit)
//
//  TerminalKeyRepeatController.swift
//  Termsy
//
//  Tracks held hardware keys and runs the repeating key timer.
//  Owns enough state to gate UIKeyInput callbacks while a hardware key is down
//  and to swallow release events that were consumed by an app shortcut.
//

import UIKit

@MainActor
final class TerminalKeyRepeatController {
	private var activeKeyCodes = Set<UInt16>()
	private var suppressedReleaseCodes = Set<UInt16>()
	private var timer: DispatchSourceTimer?
	private var repeatingKey: UIKey?
	private var repeatingKeyCode: UInt16?

	private let onRepeat: (UIKey) -> Void

	init(onRepeat: @escaping (UIKey) -> Void) {
		self.onRepeat = onRepeat
	}

	var hasActiveKey: Bool { !activeKeyCodes.isEmpty }

	/// Mark the release for this key as already consumed (e.g. by an app shortcut),
	/// so the eventual `pressesEnded` for the same key code is swallowed.
	func suppressRelease(_ keyCode: UInt16) {
		suppressedReleaseCodes.insert(keyCode)
	}

	func notePressed(_ keyCode: UInt16) {
		activeKeyCodes.insert(keyCode)
	}

	func startRepeat(for key: UIKey) {
		stop()
		repeatingKey = key
		repeatingKeyCode = UInt16(key.keyCode.rawValue)

		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
		timer.setEventHandler { [weak self] in
			guard let self, let repeatKey = self.repeatingKey else { return }
			self.onRepeat(repeatKey)
		}
		self.timer = timer
		timer.resume()
	}

	/// Returns true if the caller should forward the release event to ghostty.
	/// Returns false if this release was suppressed by a prior `suppressRelease(_:)`.
	@discardableResult
	func noteReleased(_ keyCode: UInt16) -> Bool {
		activeKeyCodes.remove(keyCode)
		if repeatingKeyCode == keyCode {
			stop()
		}
		return suppressedReleaseCodes.remove(keyCode) == nil
	}

	func noteCancelled(_ keyCode: UInt16) {
		activeKeyCodes.remove(keyCode)
		if repeatingKeyCode == keyCode {
			stop()
		}
		suppressedReleaseCodes.remove(keyCode)
	}

	func stop() {
		timer?.cancel()
		timer = nil
		repeatingKey = nil
		repeatingKeyCode = nil
	}

	func reset() {
		stop()
		activeKeyCodes.removeAll()
		suppressedReleaseCodes.removeAll()
	}
}
#endif
