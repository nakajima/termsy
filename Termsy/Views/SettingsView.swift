//
//  SettingsView.swift
//  Termsy
//

import SwiftUI

struct SettingsView: View {
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section("Theme") {
					ForEach(TerminalTheme.allCases) { theme in
						Button {
							selectedTheme = theme.rawValue
							GhosttyApp.shared.applyTheme(theme)
						} label: {
							HStack {
								ThemePreview(theme: theme)
								Text(theme.displayName)
									.foregroundStyle(.primary)
								Spacer()
								if theme.rawValue == selectedTheme {
									Image(systemName: "checkmark")
										.foregroundStyle(.tint)
								}
							}
						}
					}
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
		}
	}
}

private struct ThemePreview: View {
	let theme: TerminalTheme

	var body: some View {
		HStack(spacing: 2) {
			RoundedRectangle(cornerRadius: 3)
				.fill(Color(hex: theme.backgroundHex))
				.frame(width: 16, height: 24)
			RoundedRectangle(cornerRadius: 3)
				.fill(Color(hex: theme.foregroundHex))
				.frame(width: 16, height: 24)
		}
		.padding(2)
		.background(.quaternary, in: .rect(cornerRadius: 5))
	}
}

private extension Color {
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

#Preview {
	SettingsView()
}
