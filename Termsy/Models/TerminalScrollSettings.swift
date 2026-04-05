//
//  TerminalScrollSettings.swift
//  Termsy
//

import CoreGraphics
import Foundation
import GhosttyKit

enum TerminalScrollSettings {
	enum InputKind {
		case touch
		case indirectPointer
	}

	static let reverseVerticalScrollKey = "terminalReverseVerticalScroll"
	static let touchSensitivityKey = "terminalScrollSensitivity"
	static let indirectSensitivityKey = "terminalIndirectScrollSensitivity"

	static let defaultReverseVerticalScroll = false
	static let sensitivityKey = touchSensitivityKey
	static let defaultSensitivity: Double = 1.0
	static let minSensitivity: Double = 0.25
	static let maxSensitivity: Double = 3.0
	static let defaultTouchSensitivity: Double = 1.0
	static let defaultIndirectSensitivity: Double = 1.0
	static let minTouchSensitivity: Double = 0.1
	static let maxTouchSensitivity: Double = 6.0
	static let minIndirectSensitivity: Double = 0.05
	static let maxIndirectSensitivity: Double = 4.0

	static var reverseVerticalScroll: Bool {
		UserDefaults.standard.object(forKey: reverseVerticalScrollKey) as? Bool ?? defaultReverseVerticalScroll
	}

	static var touchSensitivity: CGFloat {
		let raw = UserDefaults.standard.object(forKey: touchSensitivityKey) as? Double ?? defaultTouchSensitivity
		return CGFloat(min(max(raw, minTouchSensitivity), maxTouchSensitivity))
	}

	static var indirectSensitivity: CGFloat {
		let raw = UserDefaults.standard.object(forKey: indirectSensitivityKey) as? Double ?? defaultIndirectSensitivity
		return CGFloat(min(max(raw, minIndirectSensitivity), maxIndirectSensitivity))
	}

	static func adjustedDelta(from rawDelta: CGPoint, inputKind: InputKind) -> CGPoint {
		let multiplier: CGFloat = switch inputKind {
		case .touch: touchSensitivity
		case .indirectPointer: indirectSensitivity
		}
		let verticalDirection: CGFloat = reverseVerticalScroll ? 1 : -1
		return CGPoint(
			x: rawDelta.x * multiplier,
			y: rawDelta.y * multiplier * verticalDirection
		)
	}

	static func scrollMods(for inputKind: InputKind) -> ghostty_input_scroll_mods_t {
		switch inputKind {
		case .touch, .indirectPointer:
			1 // precision scrolling
		}
	}
}
