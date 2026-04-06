//
//  TerminalFontSettings.swift
//  Termsy
//

import Foundation

enum TerminalFontSettings {
	static let familyKey = "terminalFontFamily"
	static let defaultSize: Float = 14

	static var family: String? {
		normalizedFamily(UserDefaults.standard.string(forKey: familyKey))
	}

	static func normalizedFamily(_ rawValue: String?) -> String? {
		guard let rawValue else { return nil }
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		return trimmed
	}
}
