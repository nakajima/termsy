//
//  GhosttyConfigBuilder.swift
//  Termsy
//

import Foundation

enum GhosttyConfigBuilder {
	private static func quotedConfigValue(_ value: String) -> String {
		let escaped = value
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		return "\"\(escaped)\""
	}

	static func buildConfigText(theme: TerminalTheme, fontSize: Float? = nil) -> String {
		let cursorStyle = UserDefaults.standard.string(forKey: "cursorStyle") ?? "block"
		let cursorBlink = UserDefaults.standard.object(forKey: "cursorBlink") as? Bool ?? true
		let backgroundOpacity = TerminalBackgroundSettings.storedEffectiveOpacity()
		let resolvedFontSize = TerminalFontSettings.clampedSize(fontSize ?? TerminalFontSettings.size)
		var lines = [
			"font-size = \(Int(resolvedFontSize))",
			"cursor-style = \(cursorStyle)",
			"cursor-style-blink = \(cursorBlink)",
			"background-opacity = \(backgroundOpacity.formatted(.number.precision(.fractionLength(0 ... 3))))",
			"term = \(GhosttyTerminfo.terminalName)",
		]
		if let fontFamily = TerminalFontSettings.family {
			lines.append("font-family = \(quotedConfigValue(fontFamily))")
		}
		lines.append(theme.ghosttyConfig)
		return lines.joined(separator: "\n")
	}
}
