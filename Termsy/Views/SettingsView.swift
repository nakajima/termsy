//
//  SettingsView.swift
//  Termsy
//

import SwiftUI

struct SettingsView: View {
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@AppStorage("cursorStyle") private var cursorStyle = "block"
	@AppStorage("cursorBlink") private var cursorBlink = true
	@AppStorage(TerminalScrollSettings.reverseVerticalScrollKey) private var reverseVerticalScroll = TerminalScrollSettings.defaultReverseVerticalScroll
	@AppStorage(TerminalScrollSettings.sensitivityKey) private var scrollSensitivity = TerminalScrollSettings.defaultSensitivity
	@Environment(\.appTheme) private var theme
	@Environment(\.dismiss) private var dismiss

	private var sensitivityLabel: String {
		"\(scrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Cursor") {
					Picker("Style", selection: $cursorStyle) {
						Text("Block").tag("block")
						Text("Bar").tag("bar")
						Text("Underline").tag("underline")
					}
					.listRowBackground(theme.cardBackground)
					.onChange(of: cursorStyle) { _, _ in
						GhosttyApp.shared.reloadConfig()
					}

					Toggle("Blink", isOn: $cursorBlink)
						.listRowBackground(theme.cardBackground)
						.onChange(of: cursorBlink) { _, _ in
							GhosttyApp.shared.reloadConfig()
						}
				}

				Section {
					Toggle("Reverse Vertical Scrolling", isOn: $reverseVerticalScroll)
						.listRowBackground(theme.cardBackground)

					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text("Sensitivity")
							Spacer()
							Text(sensitivityLabel)
								.foregroundStyle(theme.secondaryText)
								.monospacedDigit()
						}

						Slider(value: $scrollSensitivity, in: TerminalScrollSettings.minSensitivity...TerminalScrollSettings.maxSensitivity, step: 0.25)
							.tint(theme.accent)

						HStack {
							Text("Slower")
							Spacer()
							Text("Faster")
						}
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
					}
					.listRowBackground(theme.cardBackground)
				} header: {
					Text("Scrolling")
				} footer: {
					Text("Direction and sensitivity apply to two-finger touch, trackpad, and mouse-wheel scrolling.")
				}

				Section("Theme") {
					ForEach(TerminalTheme.allCases) { terminalTheme in
						Button {
							selectedTheme = terminalTheme.rawValue
							GhosttyApp.shared.applyTheme(terminalTheme)
						} label: {
							HStack {
								ThemePreview(theme: terminalTheme)
								Text(terminalTheme.displayName)
									.foregroundStyle(theme.primaryText)
								Spacer()
								if terminalTheme.rawValue == selectedTheme {
									Image(systemName: "checkmark")
										.foregroundStyle(theme.accent)
								}
							}
							.padding(.vertical, 4)
						}
						.listRowBackground(theme.cardBackground)
					}
				}
			}
			.scrollContentBackground(.hidden)
			.background(theme.background)
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
			.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
		}
	}
}

private struct ThemePreview: View {
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



#Preview {
	SettingsView()
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
