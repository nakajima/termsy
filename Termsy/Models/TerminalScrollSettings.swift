//
//  TerminalScrollSettings.swift
//  Termsy
//

import CoreGraphics
import Foundation

enum TerminalScrollSettings {
	static let reverseVerticalScrollKey = "terminalReverseVerticalScroll"
	static let sensitivityKey = "terminalScrollSensitivity"

	static let defaultReverseVerticalScroll = false
	static let defaultSensitivity: Double = 1.0
	static let minSensitivity: Double = 0.25
	static let maxSensitivity: Double = 3.0

	static var reverseVerticalScroll: Bool {
		UserDefaults.standard.object(forKey: reverseVerticalScrollKey) as? Bool ?? defaultReverseVerticalScroll
	}

	static var sensitivity: CGFloat {
		let raw = UserDefaults.standard.object(forKey: sensitivityKey) as? Double ?? defaultSensitivity
		return CGFloat(min(max(raw, minSensitivity), maxSensitivity))
	}

	static func adjustedDelta(from rawDelta: CGPoint) -> CGPoint {
		let multiplier = sensitivity
		let verticalDirection: CGFloat = reverseVerticalScroll ? 1 : -1
		return CGPoint(
			x: rawDelta.x * multiplier,
			y: rawDelta.y * multiplier * verticalDirection
		)
	}
}
