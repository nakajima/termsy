//
//  TerminalScrollSettings.swift
//  Termsy
//

import CoreGraphics
import Foundation
import TermsyGhosttyKit

enum TerminalScrollSettings {
	enum InputKind {
		case touch
		case indirectPointer
	}

	enum MomentumPhase: Int32 {
		case none = 0
		case began = 1
		case stationary = 2
		case changed = 3
	}

	static let reverseVerticalScrollKey = "terminalReverseVerticalScroll"
	static let touchSensitivityKey = "terminalScrollSensitivity"
	static let indirectSensitivityKey = "terminalIndirectScrollSensitivity"
	static let momentumScrollingEnabledKey = "terminalMomentumScrollingEnabled"
	static let smoothVisualScrollingEnabledKey = "terminalSmoothVisualScrollingEnabled"

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
	static let defaultMomentumScrollingEnabled = true
	static let defaultSmoothVisualScrollingEnabled = true

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

	static var momentumScrollingEnabled: Bool {
		UserDefaults.standard.object(forKey: momentumScrollingEnabledKey) as? Bool ?? defaultMomentumScrollingEnabled
	}

	static var smoothVisualScrollingEnabled: Bool {
		UserDefaults.standard.object(forKey: smoothVisualScrollingEnabledKey) as? Bool ?? defaultSmoothVisualScrollingEnabled
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

	static func scrollRows(for adjustedDeltaY: CGFloat, cellHeight: CGFloat) -> Int {
		guard cellHeight > 0 else { return 0 }
		return Int(adjustedDeltaY / cellHeight)
	}

	static func scrollMods(
		for inputKind: InputKind,
		momentum: MomentumPhase = .none
	) -> ghostty_input_scroll_mods_t {
		var value: Int32 = 0
		switch inputKind {
		case .touch, .indirectPointer:
			value |= 1 // precision scrolling
		}
		value |= momentum.rawValue << 1
		return value
	}
}
