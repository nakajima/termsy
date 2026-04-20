#if os(macOS)
	import SwiftUI

	struct MacSettingsView: View {
		@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
		@AppStorage("cursorStyle") private var cursorStyle = "block"
		@AppStorage("cursorBlink") private var cursorBlink = true
		@AppStorage(TerminalFontSettings.familyKey) private var terminalFontFamily = ""
		@AppStorage(TerminalBackgroundSettings.opacityKey) private var backgroundOpacity = TerminalBackgroundSettings.defaultOpacity
		@AppStorage(TerminalBackgroundBlurSettings.key) private var backgroundBlurMode = TerminalBackgroundBlurSettings.default.rawValue
		@AppStorage(TerminalScrollSettings.reverseVerticalScrollKey) private var reverseVerticalScroll = TerminalScrollSettings.defaultReverseVerticalScroll
		@AppStorage(TerminalScrollSettings.touchSensitivityKey) private var touchScrollSensitivity = TerminalScrollSettings.defaultTouchSensitivity
		@AppStorage(TerminalScrollSettings.indirectSensitivityKey) private var indirectScrollSensitivity = TerminalScrollSettings.defaultIndirectSensitivity
		@AppStorage(TerminalScrollSettings.momentumScrollingEnabledKey) private var momentumScrollingEnabled = TerminalScrollSettings.defaultMomentumScrollingEnabled
		@AppStorage(TerminalScrollSettings.smoothVisualScrollingEnabledKey) private var smoothVisualScrollingEnabled = TerminalScrollSettings.defaultSmoothVisualScrollingEnabled
		@StateObject private var fontPanelController = MacFontPanelController()

		private var currentTheme: AppTheme {
			(TerminalTheme(rawValue: selectedTheme) ?? .mocha).appTheme
		}

		private var touchSensitivityLabel: String {
			"\(touchScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
		}

		private var indirectSensitivityLabel: String {
			"\(indirectScrollSensitivity.formatted(.number.precision(.fractionLength(2))))×"
		}

		private var backgroundOpacityLabel: String {
			TerminalBackgroundSettings.normalizedOpacity(backgroundOpacity)
				.formatted(.percent.precision(.fractionLength(0)))
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

						Toggle("Blink", isOn: $cursorBlink)
					}

					Section {
						HStack {
							Text("Current Font")
							Spacer()
							Text(terminalFontDisplayName)
								.foregroundStyle(currentTheme.secondaryText)
								.lineLimit(1)
						}

						NavigationLink {
							SystemMonospacedFontListView(selectedFontFamily: $terminalFontFamily)
								.environment(\.appTheme, currentTheme)
						} label: {
							Text("System Monospaced Fonts")
						}

						Button("Choose Font…") {
							fontPanelController.present(selectedFontFamily: terminalFontFamily) { family in
								terminalFontFamily = family
							}
						}

						if TerminalFontSettings.normalizedFamily(terminalFontFamily) != nil {
							Button("Use Default") {
								terminalFontFamily = ""
							}
						}
					} header: {
						Text("Font")
					} footer: {
						Text("System Monospaced Fonts shows curated built-in choices. Choose Font opens the standard macOS font panel.")
					}

					Section("Background") {
						Picker("Blur", selection: $backgroundBlurMode) {
							ForEach(TerminalBackgroundBlurSettings.allCases) { mode in
								Text(mode.displayName).tag(mode.rawValue)
							}
						}

						Text("Uses the macOS window blur effect.")
							.font(.caption)
							.foregroundStyle(currentTheme.secondaryText)

						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text("Opacity")
								Spacer()
								Text(backgroundOpacityLabel)
									.foregroundStyle(currentTheme.secondaryText)
									.monospacedDigit()
							}

							Slider(
								value: $backgroundOpacity,
								in: TerminalBackgroundSettings.minOpacity ... TerminalBackgroundSettings.maxOpacity,
								step: 0.05
							)
							.tint(currentTheme.accent)
						}
					}

					Section("Scrolling") {
						Toggle("Momentum Scrolling", isOn: $momentumScrollingEnabled)
						Toggle("Smooth Visual Scrolling", isOn: $smoothVisualScrollingEnabled)
						Toggle("Reverse Vertical Scrolling", isOn: $reverseVerticalScroll)

						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text("Touch Sensitivity")
								Spacer()
								Text(touchSensitivityLabel)
									.foregroundStyle(currentTheme.secondaryText)
									.monospacedDigit()
							}

							Slider(
								value: $touchScrollSensitivity,
								in: TerminalScrollSettings.minTouchSensitivity ... TerminalScrollSettings.maxTouchSensitivity,
								step: 0.1
							)
							.tint(currentTheme.accent)
						}

						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text("Trackpad / Mouse Sensitivity")
								Spacer()
								Text(indirectSensitivityLabel)
									.foregroundStyle(currentTheme.secondaryText)
									.monospacedDigit()
							}

							Slider(
								value: $indirectScrollSensitivity,
								in: TerminalScrollSettings.minIndirectSensitivity ... TerminalScrollSettings.maxIndirectSensitivity,
								step: 0.05
							)
							.tint(currentTheme.accent)
						}
					}

					Section("Theme") {
						Picker("Theme", selection: $selectedTheme) {
							ForEach(TerminalTheme.allCases) { terminalTheme in
								Text(terminalTheme.displayName)
									.tag(terminalTheme.rawValue)
							}
						}
					}
				}
				.formStyle(.grouped)
				.scrollContentBackground(.hidden)
				.background(currentTheme.background)
				.frame(minWidth: 520, minHeight: 420)
				.navigationTitle("Settings")
			}
		}
	}

	#Preview {
		MacSettingsView()
	}
#endif
