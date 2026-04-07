//
//  ThemePreview.swift
//  Termsy
//

import SwiftUI

struct ThemePreview: View {
	let theme: TerminalTheme

	var body: some View {
		let previewTheme = theme.appTheme
		HStack(spacing: 2) {
			RoundedRectangle(cornerRadius: 3)
				.fill(previewTheme.background)
				.frame(width: 16, height: 24)
			RoundedRectangle(cornerRadius: 3)
				.fill(previewTheme.accent)
				.frame(width: 16, height: 24)
			RoundedRectangle(cornerRadius: 3)
				.fill(previewTheme.text)
				.frame(width: 16, height: 24)
		}
		.padding(2)
		.background(previewTheme.cardBackground, in: .rect(cornerRadius: 5))
	}
}

#Preview("Theme Swatches") {
	VStack(alignment: .leading, spacing: 12) {
		ForEach(TerminalTheme.allCases) { terminalTheme in
			HStack(spacing: 12) {
				ThemePreview(theme: terminalTheme)
				Text(terminalTheme.displayName)
					.foregroundStyle(TerminalTheme.mocha.appTheme.primaryText)
			}
		}
	}
	.padding()
	.background(TerminalTheme.mocha.appTheme.background)
}
