//
//  SettingsView.swift
//  Termsy
//

import CoreText
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

private struct SystemMonospacedFontListView: View {
	@Binding var selectedFontFamily: String
	@Environment(\.appTheme) private var theme

	private var selectedFamily: String? {
		TerminalFontSettings.normalizedFamily(selectedFontFamily)
	}

	var body: some View {
		List(SystemFontCatalog.monospacedSystemFamilies, id: \.self) { family in
			Button {
				selectedFontFamily = family
				GhosttyApp.shared.reloadConfig()
			} label: {
				HStack {
					Text(family)
						.foregroundStyle(theme.primaryText)
					Spacer()
					if selectedFamily == family {
						Image(systemName: "checkmark")
							.foregroundStyle(theme.accent)
					}
				}
			}
			.listRowBackground(theme.cardBackground)
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("System Fonts")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private struct InstalledTerminalFontPickerSheet: UIViewControllerRepresentable {
	@Binding var selectedFontFamily: String
	let onSelectionMessage: (String) -> Void
	let onDismiss: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(
			selectedFontFamily: $selectedFontFamily,
			onSelectionMessage: onSelectionMessage,
			onDismiss: onDismiss
		)
	}

	func makeUIViewController(context: Context) -> UIFontPickerViewController {
		let configuration = UIFontPickerViewController.Configuration()
		configuration.includeFaces = false

		let controller = UIFontPickerViewController(configuration: configuration)
		controller.delegate = context.coordinator
		return controller
	}

	func updateUIViewController(_: UIFontPickerViewController, context _: Context) {}

	final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
		private var selectedFontFamily: Binding<String>
		private let onSelectionMessage: (String) -> Void
		private let onDismiss: () -> Void

		init(
			selectedFontFamily: Binding<String>,
			onSelectionMessage: @escaping (String) -> Void,
			onDismiss: @escaping () -> Void
		) {
			self.selectedFontFamily = selectedFontFamily
			self.onSelectionMessage = onSelectionMessage
			self.onDismiss = onDismiss
		}

		func fontPickerViewControllerDidCancel(_: UIFontPickerViewController) {
			onDismiss()
		}

		func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
			guard let descriptor = viewController.selectedFontDescriptor,
			      let fontFamily = TerminalFontSettings.normalizedFamily(
			      	descriptor.object(forKey: .family) as? String
			      )
			else {
				onDismiss()
				return
			}

			if SystemFontCatalog.isBuiltInSystemFamily(fontFamily),
			   !SystemFontCatalog.isMonospacedSystemFamily(fontFamily)
			{
				onSelectionMessage(
					"“\(fontFamily)” is a built-in system font. Termsy keeps built-in choices limited to monospaced families, so pick it from the System Monospaced Fonts list or choose a custom installed font here."
				)
				onDismiss()
				return
			}

			CTFontManagerRequestFonts([descriptor as CTFontDescriptor] as CFArray) { unresolved in
				DispatchQueue.main.async {
					if CFArrayGetCount(unresolved) > 0 {
						self.onSelectionMessage(
							"Termsy couldn’t make “\(fontFamily)” available yet. Try selecting it again from Installed / Custom Fonts."
						)
					} else {
						self.selectedFontFamily.wrappedValue = fontFamily
						GhosttyApp.shared.reloadConfig()
					}
					self.onDismiss()
				}
			}
		}
	}
}

private enum SystemFontCatalog {
	static let builtInSystemFamilies: Set<String> = Set(UIFont.familyNames)
	static let monospacedSystemFamilies: [String] = builtInSystemFamilies
		.filter(hasMonospacedTrait)
		.sorted { lhs, rhs in
			lhs.localizedStandardCompare(rhs) == .orderedAscending
		}

	private static let monospacedSystemFamilySet = Set(monospacedSystemFamilies)

	static func isBuiltInSystemFamily(_ family: String) -> Bool {
		builtInSystemFamilies.contains(family)
	}

	static func isMonospacedSystemFamily(_ family: String) -> Bool {
		monospacedSystemFamilySet.contains(family)
	}

	private static func hasMonospacedTrait(_ family: String) -> Bool {
		UIFont.fontNames(forFamilyName: family).contains { fontName in
			guard let descriptor = UIFont(name: fontName, size: 12)?.fontDescriptor else {
				return false
			}
			return descriptor.symbolicTraits.contains(.traitMonoSpace)
		}
	}
}

#Preview {
	SettingsView()
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("System Monospaced Fonts") {
	NavigationStack {
		SystemMonospacedFontListView(selectedFontFamily: .constant("SF Mono"))
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
}
