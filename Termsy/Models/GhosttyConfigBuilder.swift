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

	static func buildConfigText(theme: TerminalTheme) -> String {
		let cursorStyle = UserDefaults.standard.string(forKey: "cursorStyle") ?? "block"
		let cursorBlink = UserDefaults.standard.object(forKey: "cursorBlink") as? Bool ?? true
		var lines = [
			"font-size = \(Int(TerminalFontSettings.defaultSize))",
			"cursor-style = \(cursorStyle)",
			"cursor-style-blink = \(cursorBlink)",
			"term = xterm-256color",
		]
		if let fontFamily = TerminalFontSettings.family {
			lines.append("font-family = \(quotedConfigValue(fontFamily))")
		}
		lines.append(theme.ghosttyConfig)
		return lines.joined(separator: "\n")
	}
}
