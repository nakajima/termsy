//
//  AppTheme.swift
//  Termsy
//

import SwiftUI

struct AppTheme {
	// MARK: - Base layers
	let crust: Color
	let mantle: Color
	let base: Color

	// MARK: - Surfaces
	let surface0: Color
	let surface1: Color
	let surface2: Color

	// MARK: - Overlays
	let overlay0: Color
	let overlay1: Color
	let overlay2: Color

	// MARK: - Text
	let subtext0: Color
	let subtext1: Color
	let text: Color

	// MARK: - Accents
	let rosewater: Color
	let flamingo: Color
	let pink: Color
	let mauve: Color
	let red: Color
	let maroon: Color
	let peach: Color
	let yellow: Color
	let green: Color
	let teal: Color
	let sky: Color
	let sapphire: Color
	let blue: Color
	let lavender: Color

	// MARK: - Meta
	let colorScheme: ColorScheme
}

extension AppTheme {
	var background: Color { base }
	var elevatedBackground: Color { mantle }
	var insetBackground: Color { crust }
	var cardBackground: Color { surface0 }
	var controlBackground: Color { surface1 }
	var selectedBackground: Color { surface2 }
	var primaryText: Color { text }
	var secondaryText: Color { subtext0 }
	var tertiaryText: Color { overlay1 }
	var accent: Color { blue }
	var success: Color { green }
	var warning: Color { yellow }
	var error: Color { red }
	var divider: Color { overlay0.opacity(0.35) }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
	static let defaultValue: AppTheme = TerminalTheme.mocha.appTheme
}

extension EnvironmentValues {
	var appTheme: AppTheme {
		get { self[AppThemeKey.self] }
		set { self[AppThemeKey.self] = newValue }
	}
}

#if canImport(UIKit) || canImport(AppKit)
extension AppTheme {
	var backgroundUIColor: PlatformColor { PlatformColor(background) }
	var elevatedBackgroundUIColor: PlatformColor { PlatformColor(elevatedBackground) }
	var cardBackgroundUIColor: PlatformColor { PlatformColor(cardBackground) }
	var selectedBackgroundUIColor: PlatformColor { PlatformColor(selectedBackground) }
	var primaryTextUIColor: PlatformColor { PlatformColor(primaryText) }
	var secondaryTextUIColor: PlatformColor { PlatformColor(secondaryText) }
	var tertiaryTextUIColor: PlatformColor { PlatformColor(tertiaryText) }
	var accentUIColor: PlatformColor { PlatformColor(accent) }
	var warningUIColor: PlatformColor { PlatformColor(warning) }
	var dividerUIColor: PlatformColor { PlatformColor(overlay0).withAlphaComponent(0.25) }
}
#endif

// MARK: - Color from hex

extension Color {
	init(hex: String) {
		let scanner = Scanner(string: hex)
		var rgb: UInt64 = 0
		scanner.scanHexInt64(&rgb)
		self.init(
			red: Double((rgb >> 16) & 0xFF) / 255,
			green: Double((rgb >> 8) & 0xFF) / 255,
			blue: Double(rgb & 0xFF) / 255
		)
	}
}

// MARK: - Theme palettes

extension TerminalTheme {
	var appTheme: AppTheme {
		switch self {
		case .mocha:
			AppTheme(
				crust: Color(hex: "11111b"),
				mantle: Color(hex: "181825"),
				base: Color(hex: "1e1e2e"),
				surface0: Color(hex: "313244"),
				surface1: Color(hex: "45475a"),
				surface2: Color(hex: "585b70"),
				overlay0: Color(hex: "6c7086"),
				overlay1: Color(hex: "7f849c"),
				overlay2: Color(hex: "9399b2"),
				subtext0: Color(hex: "a6adc8"),
				subtext1: Color(hex: "bac2de"),
				text: Color(hex: "cdd6f4"),
				rosewater: Color(hex: "f5e0dc"),
				flamingo: Color(hex: "f2cdcd"),
				pink: Color(hex: "f5c2e7"),
				mauve: Color(hex: "cba6f7"),
				red: Color(hex: "f38ba8"),
				maroon: Color(hex: "eba0ac"),
				peach: Color(hex: "fab387"),
				yellow: Color(hex: "f9e2af"),
				green: Color(hex: "a6e3a1"),
				teal: Color(hex: "94e2d5"),
				sky: Color(hex: "89dceb"),
				sapphire: Color(hex: "74c7ec"),
				blue: Color(hex: "89b4fa"),
				lavender: Color(hex: "b4befe"),
				colorScheme: .dark
			)
		case .macchiato:
			AppTheme(
				crust: Color(hex: "181926"),
				mantle: Color(hex: "1e2030"),
				base: Color(hex: "24273a"),
				surface0: Color(hex: "363a4f"),
				surface1: Color(hex: "494d64"),
				surface2: Color(hex: "5b6078"),
				overlay0: Color(hex: "6e738d"),
				overlay1: Color(hex: "8087a2"),
				overlay2: Color(hex: "939ab7"),
				subtext0: Color(hex: "a5adcb"),
				subtext1: Color(hex: "b8c0e0"),
				text: Color(hex: "cad3f5"),
				rosewater: Color(hex: "f4dbd6"),
				flamingo: Color(hex: "f0c6c6"),
				pink: Color(hex: "f5bde6"),
				mauve: Color(hex: "c6a0f6"),
				red: Color(hex: "ed8796"),
				maroon: Color(hex: "ee99a0"),
				peach: Color(hex: "f5a97f"),
				yellow: Color(hex: "eed49f"),
				green: Color(hex: "a6da95"),
				teal: Color(hex: "8bd5ca"),
				sky: Color(hex: "91d7e3"),
				sapphire: Color(hex: "7dc4e4"),
				blue: Color(hex: "8aadf4"),
				lavender: Color(hex: "b7bdf8"),
				colorScheme: .dark
			)
		case .frappe:
			AppTheme(
				crust: Color(hex: "232634"),
				mantle: Color(hex: "292c3c"),
				base: Color(hex: "303446"),
				surface0: Color(hex: "414559"),
				surface1: Color(hex: "51576d"),
				surface2: Color(hex: "626880"),
				overlay0: Color(hex: "737994"),
				overlay1: Color(hex: "838ba7"),
				overlay2: Color(hex: "949cbb"),
				subtext0: Color(hex: "a5adce"),
				subtext1: Color(hex: "b5bfe2"),
				text: Color(hex: "c6d0f5"),
				rosewater: Color(hex: "f2d5cf"),
				flamingo: Color(hex: "eebebe"),
				pink: Color(hex: "f4b8e4"),
				mauve: Color(hex: "ca9ee6"),
				red: Color(hex: "e78284"),
				maroon: Color(hex: "ea999c"),
				peach: Color(hex: "ef9f76"),
				yellow: Color(hex: "e5c890"),
				green: Color(hex: "a6d189"),
				teal: Color(hex: "81c8be"),
				sky: Color(hex: "99d1db"),
				sapphire: Color(hex: "85c1dc"),
				blue: Color(hex: "8caaee"),
				lavender: Color(hex: "babbf1"),
				colorScheme: .dark
			)
		case .latte:
			AppTheme(
				crust: Color(hex: "dce0e8"),
				mantle: Color(hex: "e6e9ef"),
				base: Color(hex: "eff1f5"),
				surface0: Color(hex: "ccd0da"),
				surface1: Color(hex: "bcc0cc"),
				surface2: Color(hex: "acb0be"),
				overlay0: Color(hex: "9ca0b0"),
				overlay1: Color(hex: "8c8fa1"),
				overlay2: Color(hex: "7c7f93"),
				subtext0: Color(hex: "6c6f85"),
				subtext1: Color(hex: "5c5f77"),
				text: Color(hex: "4c4f69"),
				rosewater: Color(hex: "dc8a78"),
				flamingo: Color(hex: "dd7878"),
				pink: Color(hex: "ea76cb"),
				mauve: Color(hex: "8839ef"),
				red: Color(hex: "d20f39"),
				maroon: Color(hex: "e64553"),
				peach: Color(hex: "fe640b"),
				yellow: Color(hex: "df8e1d"),
				green: Color(hex: "40a02b"),
				teal: Color(hex: "179299"),
				sky: Color(hex: "04a5e5"),
				sapphire: Color(hex: "209fb5"),
				blue: Color(hex: "1e66f5"),
				lavender: Color(hex: "7287fd"),
				colorScheme: .light
			)
		}
	}
}
