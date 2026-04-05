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
		summary: "A quick summary of the latest improvements in Termsy.",
		changes: [
			"Bug fixes and improvements."
		]
	)

	var previewChange: String {
		changes.first ?? Self.fallback.changes[0]
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
