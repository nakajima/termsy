//
//  TerminalPointerSettings.swift
//  Termsy
//

import CoreGraphics

enum TerminalPointerSettings {
	static let bottomEdgeLiftEnabledKey = "terminalBottomEdgeLiftEnabled"
	static let defaultBottomEdgeLiftEnabled = false
	static let bottomEdgeActivationDistance: CGFloat = 20
	static let bottomEdgeLiftDistance: CGFloat = 20
	static let bottomEdgeReleaseDistance = bottomEdgeActivationDistance + bottomEdgeLiftDistance
}
