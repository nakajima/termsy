//
//  TerminalPointerSettings.swift
//  Termsy
//

import CoreGraphics

enum TerminalPointerSettings {
	static let bottomEdgeLiftEnabledKey = "terminalBottomEdgeLiftEnabled"
	static let bottomEdgeLiftDistanceKey = "terminalBottomEdgeLiftDistance"
	static let defaultBottomEdgeLiftEnabled = false
	static let defaultBottomEdgeLiftDistance = 20.0
	static let minBottomEdgeLiftDistance = 20.0
	static let maxBottomEdgeLiftDistance = 100.0
	static let bottomEdgeActivationDistance: CGFloat = 20

	static func clampedBottomEdgeLiftDistance(_ rawValue: Double) -> CGFloat {
		CGFloat(min(max(rawValue, minBottomEdgeLiftDistance), maxBottomEdgeLiftDistance))
	}
}
