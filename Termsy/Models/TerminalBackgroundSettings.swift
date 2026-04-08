import Foundation

enum TerminalBackgroundSettings {
	static let opacityKey = "backgroundOpacity"
	static let defaultOpacity = 1.0
	static let minOpacity = 0.05
	static let maxOpacity = 1.0

	static func normalizedOpacity(_ value: Double) -> Double {
		min(max(value, minOpacity), maxOpacity)
	}
}
