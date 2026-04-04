//
//  TerminalTheme.swift
//  Termsy
//

import Foundation
import UIKit

enum TerminalTheme: String, CaseIterable, Identifiable {
	case mocha
	case macchiato
	case frappe
	case latte

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .mocha: "Mocha"
		case .macchiato: "Macchiato"
		case .frappe: "Frappé"
		case .latte: "Latte"
		}
	}

	/// The background hex (without #) for use in SwiftUI previews, etc.
	var backgroundHex: String {
		switch self {
		case .mocha: "1e1e2e"
		case .macchiato: "24273a"
		case .frappe: "303446"
		case .latte: "eff1f5"
		}
	}

	var foregroundHex: String {
		switch self {
		case .mocha: "cdd6f4"
		case .macchiato: "cad3f5"
		case .frappe: "c6d0f5"
		case .latte: "4c4f69"
		}
	}

	var isLight: Bool { self == .latte }

	/// The current saved theme.
	static var current: TerminalTheme {
		TerminalTheme(rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? "") ?? .mocha
	}

	var backgroundUIColor: UIColor {
		UIColor(hex: backgroundHex)
	}

	/// Ghostty config lines for this theme's colors.
	var ghosttyConfig: String {
		switch self {
		case .mocha:
			"""
			palette = 0=#45475a
			palette = 1=#f38ba8
			palette = 2=#a6e3a1
			palette = 3=#f9e2af
			palette = 4=#89b4fa
			palette = 5=#f5c2e7
			palette = 6=#94e2d5
			palette = 7=#a6adc8
			palette = 8=#585b70
			palette = 9=#f38ba8
			palette = 10=#a6e3a1
			palette = 11=#f9e2af
			palette = 12=#89b4fa
			palette = 13=#f5c2e7
			palette = 14=#94e2d5
			palette = 15=#bac2de
			background = 1e1e2e
			foreground = cdd6f4
			cursor-color = f5e0dc
			cursor-text = 11111b
			selection-background = 353749
			selection-foreground = cdd6f4
			"""
		case .macchiato:
			"""
			palette = 0=#494d64
			palette = 1=#ed8796
			palette = 2=#a6da95
			palette = 3=#eed49f
			palette = 4=#8aadf4
			palette = 5=#f5bde6
			palette = 6=#8bd5ca
			palette = 7=#a5adcb
			palette = 8=#5b6078
			palette = 9=#ed8796
			palette = 10=#a6da95
			palette = 11=#eed49f
			palette = 12=#8aadf4
			palette = 13=#f5bde6
			palette = 14=#8bd5ca
			palette = 15=#b8c0e0
			background = 24273a
			foreground = cad3f5
			cursor-color = f4dbd6
			cursor-text = 181926
			selection-background = 3a3e53
			selection-foreground = cad3f5
			"""
		case .frappe:
			"""
			palette = 0=#51576d
			palette = 1=#e78284
			palette = 2=#a6d189
			palette = 3=#e5c890
			palette = 4=#8caaee
			palette = 5=#f4b8e4
			palette = 6=#81c8be
			palette = 7=#a5adce
			palette = 8=#626880
			palette = 9=#e78284
			palette = 10=#a6d189
			palette = 11=#e5c890
			palette = 12=#8caaee
			palette = 13=#f4b8e4
			palette = 14=#81c8be
			palette = 15=#b5bfe2
			background = 303446
			foreground = c6d0f5
			cursor-color = f2d5cf
			cursor-text = 232634
			selection-background = 44495d
			selection-foreground = c6d0f5
			"""
		case .latte:
			"""
			palette = 0=#5c5f77
			palette = 1=#d20f39
			palette = 2=#40a02b
			palette = 3=#df8e1d
			palette = 4=#1e66f5
			palette = 5=#ea76cb
			palette = 6=#179299
			palette = 7=#acb0be
			palette = 8=#6c6f85
			palette = 9=#d20f39
			palette = 10=#40a02b
			palette = 11=#df8e1d
			palette = 12=#1e66f5
			palette = 13=#ea76cb
			palette = 14=#179299
			palette = 15=#bcc0cc
			background = eff1f5
			foreground = 4c4f69
			cursor-color = dc8a78
			cursor-text = eff1f5
			selection-background = d8dae1
			selection-foreground = 4c4f69
			"""
		}
	}
}

extension UIColor {
	convenience init(hex: String) {
		var rgb: UInt64 = 0
		Scanner(string: hex).scanHexInt64(&rgb)
		self.init(
			red: CGFloat((rgb >> 16) & 0xFF) / 255,
			green: CGFloat((rgb >> 8) & 0xFF) / 255,
			blue: CGFloat(rgb & 0xFF) / 255,
			alpha: 1
		)
	}
}
