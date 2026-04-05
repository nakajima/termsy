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
	@AppStorage(TerminalScrollSettings.touchSensitivityKey) private var touchScrollSensitivity = TerminalScrollSettings.defaultTouchSensitivity
	@AppStorage(TerminalScrollSettings.indirectSensitivityKey) private var indirectScrollSensitivity = TerminalScrollSettings.defaultIndirectSensitivity
	@Environment(\.appTheme) private var theme
	@Environment(\.dismiss) private var dismiss

	private var touchSensitivityLabel: String {
		"\(touchScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
	}

	private var indirectSensitivityLabel: String {
		"\(indirectScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
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
							Text("Touch Sensitivity")
							Spacer()
							Text(touchSensitivityLabel)
								.foregroundStyle(theme.secondaryText)
								.monospacedDigit()
						}

						Slider(value: $touchScrollSensitivity, in: TerminalScrollSettings.minTouchSensitivity...TerminalScrollSettings.maxTouchSensitivity, step: 0.25)
							.tint(theme.accent)
					}
					.listRowBackground(theme.cardBackground)

					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text("Trackpad / Mouse Sensitivity")
							Spacer()
							Text(indirectSensitivityLabel)
								.foregroundStyle(theme.secondaryText)
								.monospacedDigit()
						}

						Slider(value: $indirectScrollSensitivity, in: TerminalScrollSettings.minIndirectSensitivity...TerminalScrollSettings.maxIndirectSensitivity, step: 0.01)
							.tint(theme.accent)
					}
					.listRowBackground(theme.cardBackground)
				} header: {
					Text("Scrolling")
				} footer: {
					Text("Touch and trackpad/mouse scrolling are tuned separately. Trackpad and mouse wheel use precise scrolling and target the pointer location.")
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
