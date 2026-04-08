import Foundation

enum TerminalBackgroundBlurSettings: String, CaseIterable, Identifiable {
	case off
	case macosGlassRegular
	case macosGlassClear

	static let key = "backgroundBlurMode"
	static let `default` = TerminalBackgroundBlurSettings.off
	static let recommendedOpacityWhenEnabled = 0.85

	var id: String { rawValue }

	var requiresTransparency: Bool {
		self != .off
	}

	var displayName: String {
		switch self {
		case .off:
			return "Off"
		case .macosGlassRegular:
			return "Blur"
		case .macosGlassClear:
			return "Blur (Strong)"
		}
	}

	var blurRadius: Int {
		switch self {
		case .off:
			return 0
		case .macosGlassRegular:
			return 20
		case .macosGlassClear:
			return 35
		}
	}
}
