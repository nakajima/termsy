//
//  WhatsNew.swift
//  Termsy
//

import Foundation

struct WhatsNewContent: Equatable {
	let title: String
	let summary: String?
	let changes: [String]

	static let fallback = Self(
		title: "What's New",
		summary: nil,
		changes: []
	)

	var hasChanges: Bool {
		!changes.isEmpty
	}

	var previewChange: String? {
		changes.first
	}
}

enum AppReleaseInfo {
	static var currentVersionDisplay: String {
		let shortVersion = sanitizedInfoValue(for: "CFBundleShortVersionString")
		let buildNumber = sanitizedInfoValue(for: "CFBundleVersion")

		return switch (shortVersion, buildNumber) {
		case let (version?, build?) where version != build:
			"\(version) (\(build))"
		case let (version?, _):
			version
		case let (_, build?):
			"Build \(build)"
		default:
			"Current build"
		}
	}

	private static func sanitizedInfoValue(for key: String) -> String? {
		guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
			return nil
		}

		let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmedValue.isEmpty ? nil : trimmedValue
	}
}
