//
//  WhatsNewView.swift
//  Termsy
//

import SwiftUI

struct WhatsNewView: View {
	@Environment(\.appTheme) private var theme

	let content: WhatsNewContent
	let versionDisplay: String

	init(
		content: WhatsNewContent = WhatsNewGenerated.current,
		versionDisplay: String = AppReleaseInfo.currentVersionDisplay
	) {
		self.content = content
		self.versionDisplay = versionDisplay
	}

	var body: some View {
		List {
			Section {
				VStack(alignment: .leading, spacing: 12) {
					HStack(alignment: .firstTextBaseline) {
						Text("Termsy")
							.font(.headline)
							.foregroundStyle(theme.primaryText)

						Spacer()

						Text(versionDisplay)
							.font(.subheadline)
							.foregroundStyle(theme.secondaryText)
					}

					if let summary = content.summary {
						Text(summary)
							.font(.body)
							.foregroundStyle(theme.secondaryText)
					}
				}
				.padding(.vertical, 4)
				.listRowBackground(theme.cardBackground)
			}

			Section("Changes") {
				ForEach(Array(content.changes.enumerated()), id: \.offset) { _, change in
					HStack(alignment: .top, spacing: 12) {
						Image(systemName: "sparkles")
							.foregroundStyle(theme.accent)
							.padding(.top, 2)

						Text(change)
							.foregroundStyle(theme.primaryText)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.vertical, 4)
					.listRowBackground(theme.cardBackground)
				}
			}
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle(content.title)
		.navigationBarTitleDisplayMode(.inline)
	}
}

#Preview {
	NavigationStack {
		WhatsNewView(
			content: WhatsNewContent(
				title: "What's New",
				summary: "A quick summary of the latest improvements in Termsy.",
				changes: [
					"Fix tab resume behavior when returning to the app.",
					"Improve touch scrolling and pointer input in terminal sessions.",
					"Make reconnection handling more reliable after backgrounding."
				]
			),
			versionDisplay: "1.0 (1)"
		)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
}
