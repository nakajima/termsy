//
//  SettingsView.swift
//  Termsy
//

import SwiftUI

struct SettingsView: View {
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@AppStorage("cursorStyle") private var cursorStyle = "block"
	@AppStorage("cursorBlink") private var cursorBlink = true
	@AppStorage(TerminalFontSettings.familyKey) private var terminalFontFamily = ""
	@AppStorage(TerminalScrollSettings.reverseVerticalScrollKey) private var reverseVerticalScroll = TerminalScrollSettings.defaultReverseVerticalScroll
	@AppStorage(TerminalScrollSettings.touchSensitivityKey) private var touchScrollSensitivity = TerminalScrollSettings.defaultTouchSensitivity
	@AppStorage(TerminalScrollSettings.indirectSensitivityKey) private var indirectScrollSensitivity = TerminalScrollSettings.defaultIndirectSensitivity
	@AppStorage(TerminalScrollSettings.momentumScrollingEnabledKey) private var momentumScrollingEnabled = TerminalScrollSettings.defaultMomentumScrollingEnabled
	@AppStorage(TerminalScrollSettings.smoothVisualScrollingEnabledKey) private var smoothVisualScrollingEnabled = TerminalScrollSettings.defaultSmoothVisualScrollingEnabled
	@Environment(\.appTheme) private var theme
	@Environment(\.dismiss) private var dismiss
	@State private var isShowingInstalledFontPicker = false
	@State private var fontSelectionMessage: String?

	private var touchSensitivityLabel: String {
		"\(touchScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
	}

	private var indirectSensitivityLabel: String {
		"\(indirectScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
	}

	private var whatsNewContent: WhatsNewContent {
		WhatsNewGenerated.current
	}

	private var terminalFontDisplayName: String {
		TerminalFontSettings.normalizedFamily(terminalFontFamily) ?? "System Default"
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
					HStack {
						Text("Current Font")
							.foregroundStyle(theme.primaryText)
						Spacer()
						Text(terminalFontDisplayName)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
					.listRowBackground(theme.cardBackground)

					NavigationLink {
						SystemMonospacedFontListView(selectedFontFamily: $terminalFontFamily)
							.environment(\.appTheme, theme)
					} label: {
						Text("System Monospaced Fonts")
							.foregroundStyle(theme.primaryText)
					}
					.listRowBackground(theme.cardBackground)

					Button {
						isShowingInstalledFontPicker = true
					} label: {
						Text("Installed / Custom Fonts…")
							.foregroundStyle(theme.primaryText)
					}
					.listRowBackground(theme.cardBackground)

					if TerminalFontSettings.normalizedFamily(terminalFontFamily) != nil {
						Button("Use Default") {
							terminalFontFamily = ""
							GhosttyApp.shared.reloadConfig()
						}
						.listRowBackground(theme.cardBackground)
					}
				} header: {
					Text("Font")
				} footer: {
					Text("System fonts stay limited to monospaced families. Use Installed / Custom Fonts for Fontcase or other provider fonts that may not advertise the monospace trait correctly on iOS.")
				}

				Section {
					Toggle("Momentum Scrolling", isOn: $momentumScrollingEnabled)
						.listRowBackground(theme.cardBackground)

					Toggle("Smooth Visual Scrolling", isOn: $smoothVisualScrollingEnabled)
						.listRowBackground(theme.cardBackground)

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

						Slider(value: $touchScrollSensitivity, in: TerminalScrollSettings.minTouchSensitivity...TerminalScrollSettings.maxTouchSensitivity, step: 0.1)
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

						Slider(value: $indirectScrollSensitivity, in: TerminalScrollSettings.minIndirectSensitivity...TerminalScrollSettings.maxIndirectSensitivity, step: 0.05)
							.tint(theme.accent)
					}
					.listRowBackground(theme.cardBackground)
				} header: {
					Text("Scrolling")
				} footer: {
					Text("Momentum applies to touch and indirect scrolling. Smooth visual scrolling only animates user-driven scrolling and momentum, and snaps back to the real terminal state when live output changes the terminal.")
				}

				if let whatsNewPreview = whatsNewContent.previewChange {
					Section("What's New") {
						NavigationLink {
							WhatsNewView(content: whatsNewContent)
						} label: {
							VStack(alignment: .leading, spacing: 6) {
								HStack {
									Label("Latest changes", systemImage: "sparkles")
										.foregroundStyle(theme.primaryText)
									Spacer()
									Text(AppReleaseInfo.currentVersionDisplay)
										.font(.subheadline)
										.foregroundStyle(theme.secondaryText)
								}

								Text(whatsNewPreview)
									.font(.subheadline)
									.foregroundStyle(theme.secondaryText)
									.lineLimit(2)
							}
							.padding(.vertical, 2)
						}
						.listRowBackground(theme.cardBackground)
					}
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
		.sheet(isPresented: $isShowingInstalledFontPicker) {
			InstalledTerminalFontPickerSheet(
				selectedFontFamily: $terminalFontFamily,
				onSelectionMessage: { message in
					fontSelectionMessage = message
				},
				onDismiss: {
					isShowingInstalledFontPicker = false
				}
			)
		}
		.alert("Font Selection", isPresented: .init(
			get: { fontSelectionMessage != nil },
			set: { isPresented in
				if !isPresented {
					fontSelectionMessage = nil
				}
			}
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(fontSelectionMessage ?? "")
		}
	}
}

#Preview {
	SettingsView()
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
