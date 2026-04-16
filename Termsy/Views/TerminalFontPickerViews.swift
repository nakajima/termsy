#if canImport(UIKit)
//
	//  TerminalFontPickerViews.swift
	//  Termsy
//

	import CoreText
	import SwiftUI
	import UIKit

	struct SystemMonospacedFontListView: View {
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

	struct InstalledTerminalFontPickerSheet: UIViewControllerRepresentable {
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
						"“\(fontFamily)” is a built-in system font. Teletype keeps built-in choices limited to monospaced families, so pick it from the System Monospaced Fonts list or choose a custom installed font here."
					)
					onDismiss()
					return
				}

				CTFontManagerRequestFonts([descriptor as CTFontDescriptor] as CFArray) { unresolved in
					DispatchQueue.main.async {
						if CFArrayGetCount(unresolved) > 0 {
							self.onSelectionMessage(
								"Teletype couldn’t make “\(fontFamily)” available yet. Try selecting it again from Installed / Custom Fonts."
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

	enum SystemFontCatalog {
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

	#Preview("System Monospaced Fonts") {
		NavigationStack {
			SystemMonospacedFontListView(selectedFontFamily: .constant("SF Mono"))
				.environment(\.appTheme, TerminalTheme.mocha.appTheme)
		}
	}
#endif
