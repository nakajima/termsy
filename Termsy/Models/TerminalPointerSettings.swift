//
//  TerminalPointerSettings.swift
//  Termsy
//

import CoreGraphics

enum TerminalPointerSettings {
	static let bottomEdgeLiftEnabledKey = "terminalBottomEdgeLiftEnabled"
	static let bottomEdgeDetectionDistanceKey = "terminalBottomEdgeDetectionDistance"
	static let bottomEdgeLiftDistanceKey = "terminalBottomEdgeLiftDistance"
	static let defaultBottomEdgeLiftEnabled = false
	static let defaultBottomEdgeDetectionDistance = 20.0
	static let minBottomEdgeDetectionDistance = 20.0
	static let maxBottomEdgeDetectionDistance = 100.0
	static let defaultBottomEdgeLiftDistance = 20.0
	static let minBottomEdgeLiftDistance = 20.0
	static let maxBottomEdgeLiftDistance = 100.0

	static func clampedBottomEdgeDetectionDistance(_ rawValue: Double) -> CGFloat {
		CGFloat(min(max(rawValue, minBottomEdgeDetectionDistance), maxBottomEdgeDetectionDistance))
	}

	static func clampedBottomEdgeLiftDistance(_ rawValue: Double) -> CGFloat {
		CGFloat(min(max(rawValue, minBottomEdgeLiftDistance), maxBottomEdgeLiftDistance))
	}
}
