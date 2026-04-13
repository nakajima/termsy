//
//  TerminalFontSettings.swift
//  Termsy
//

import Foundation

enum TerminalFontSettings {
	static let familyKey = "terminalFontFamily"
	static let sizeKey = "terminalFontSize"
	static let defaultSize: Float = 14
	static let minimumSize: Float = 8
	static let maximumSize: Float = 36

	static var family: String? {
		normalizedFamily(UserDefaults.standard.string(forKey: familyKey))
	}

	static var size: Float {
		normalizedSize(UserDefaults.standard.object(forKey: sizeKey)) ?? defaultSize
	}

	static func normalizedFamily(_ rawValue: String?) -> String? {
		guard let rawValue else { return nil }
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		return trimmed
	}

	static func normalizedSize(_ rawValue: Any?) -> Float? {
		guard let rawValue else { return nil }
		let numericValue: Double
		switch rawValue {
		case let value as NSNumber:
			numericValue = value.doubleValue
		case let value as Double:
			numericValue = value
		case let value as Float:
			numericValue = Double(value)
		case let value as Int:
			numericValue = Double(value)
		default:
			return nil
		}
		guard numericValue.isFinite else { return nil }
		return clampedSize(Float(numericValue))
	}

	static func clampedSize(_ rawValue: Float) -> Float {
		min(max(rawValue.rounded(), minimumSize), maximumSize)
	}

	static func persistSize(_ rawValue: Float) {
		UserDefaults.standard.set(Double(clampedSize(rawValue)), forKey: sizeKey)
	}
}
