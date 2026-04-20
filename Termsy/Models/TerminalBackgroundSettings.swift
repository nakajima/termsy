import Foundation

enum TerminalBackgroundSettings {
	static let opacityKey = "backgroundOpacity"
	static let defaultOpacity = 1.0
	static let minOpacity = 0.05
	static let maxOpacity = 1.0

	static func normalizedOpacity(_ value: Double) -> Double {
		min(max(value, minOpacity), maxOpacity)
	}

	static func storedOpacity(defaults: UserDefaults = .standard) -> Double {
		normalizedOpacity(
			defaults.object(forKey: opacityKey) as? Double
				?? defaultOpacity
		)
	}

	static func effectiveOpacity(_ value: Double, blurMode: TerminalBackgroundBlurSettings) -> Double {
		let opacity = normalizedOpacity(value)
		guard blurMode.requiresTransparency, opacity >= 0.999 else { return opacity }
		return TerminalBackgroundBlurSettings.recommendedOpacityWhenEnabled
	}

	static func storedEffectiveOpacity(defaults: UserDefaults = .standard) -> Double {
		let blurMode = TerminalBackgroundBlurSettings(
			rawValue: defaults.string(forKey: TerminalBackgroundBlurSettings.key) ?? ""
		) ?? .default
		return effectiveOpacity(storedOpacity(defaults: defaults), blurMode: blurMode)
	}
}
