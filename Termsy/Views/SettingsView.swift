//
//  SettingsView.swift
//  Termsy
//

import SwiftUI
import UIKit

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
	@State private var isShowingFontPicker = false

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
					Button {
						isShowingFontPicker = true
					} label: {
						HStack {
							Text("Terminal Font")
								.foregroundStyle(theme.primaryText)
							Spacer()
							Text(terminalFontDisplayName)
								.foregroundStyle(theme.secondaryText)
								.lineLimit(1)
						}
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
					Text("Uses the system font picker so installed iOS fonts can appear when available. Only monospaced fonts are shown.")
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
		.sheet(isPresented: $isShowingFontPicker) {
			TerminalFontPickerSheet(selectedFontFamily: $terminalFontFamily) {
				isShowingFontPicker = false
			}
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

private struct TerminalFontPickerSheet: UIViewControllerRepresentable {
	@Binding var selectedFontFamily: String
	let onDismiss: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(selectedFontFamily: $selectedFontFamily, onDismiss: onDismiss)
	}

	func makeUIViewController(context: Context) -> UIFontPickerViewController {
		let configuration = UIFontPickerViewController.Configuration()
		configuration.includeFaces = false
		configuration.filteredTraits = .traitMonoSpace

		let controller = UIFontPickerViewController(configuration: configuration)
		controller.delegate = context.coordinator
		return controller
	}

	func updateUIViewController(_: UIFontPickerViewController, context _: Context) {}

	final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
		private var selectedFontFamily: Binding<String>
		private let onDismiss: () -> Void

		init(selectedFontFamily: Binding<String>, onDismiss: @escaping () -> Void) {
			self.selectedFontFamily = selectedFontFamily
			self.onDismiss = onDismiss
		}

		func fontPickerViewControllerDidCancel(_: UIFontPickerViewController) {
			onDismiss()
		}

		func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
			if let fontFamily = TerminalFontSettings.normalizedFamily(
				viewController.selectedFontDescriptor?.object(forKey: .family) as? String
			) {
				selectedFontFamily.wrappedValue = fontFamily
				GhosttyApp.shared.reloadConfig()
			}
			onDismiss()
		}
	}
}

#Preview {
	SettingsView()
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
