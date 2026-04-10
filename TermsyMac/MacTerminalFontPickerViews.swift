#if os(macOS)
	import AppKit
	import SwiftUI

	struct SystemMonospacedFontListView: View {
		@Binding var selectedFontFamily: String
		@Environment(\.appTheme) private var theme

		private var selectedFamily: String? {
			TerminalFontSettings.normalizedFamily(selectedFontFamily)
		}

		var body: some View {
			List(MacSystemFontCatalog.monospacedSystemFamilies, id: \.self) { family in
				Button {
					selectedFontFamily = family
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
				.buttonStyle(.plain)
				.listRowBackground(theme.cardBackground)
			}
			.scrollContentBackground(.hidden)
			.background(theme.background)
			.navigationTitle("System Fonts")
		}
	}

	struct InstalledTerminalFontPickerSheet: View {
		@Binding var selectedFontFamily: String
		let onSelectionMessage: (String) -> Void
		let onDismiss: () -> Void
		@Environment(\.appTheme) private var theme
		@State private var searchText = ""

		private var filteredFamilies: [String] {
			let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !query.isEmpty else { return MacSystemFontCatalog.installedFamilies }
			return MacSystemFontCatalog.installedFamilies.filter {
				$0.localizedCaseInsensitiveContains(query)
			}
		}

		var body: some View {
			NavigationStack {
				List(filteredFamilies, id: \.self) { family in
					Button {
						selectedFontFamily = family
						onDismiss()
					} label: {
						HStack {
							Text(family)
								.foregroundStyle(theme.primaryText)
							Spacer()
							if TerminalFontSettings.normalizedFamily(selectedFontFamily) == family {
								Image(systemName: "checkmark")
									.foregroundStyle(theme.accent)
							}
						}
					}
					.buttonStyle(.plain)
					.listRowBackground(theme.cardBackground)
				}
				.searchable(text: $searchText)
				.scrollContentBackground(.hidden)
				.background(theme.background)
				.navigationTitle("Installed Fonts")
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("Done") { onDismiss() }
					}
				}
			}
		}
	}

	enum MacSystemFontCatalog {
		static let builtInSystemFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies)
		static let monospacedSystemFamilies: [String] = Set(
			(NSFontManager.shared.availableFontNames(with: [.fixedPitchFontMask]) ?? [])
				.compactMap { NSFont(name: $0, size: 12)?.familyName }
		)
		.sorted { lhs, rhs in
			lhs.localizedStandardCompare(rhs) == .orderedAscending
		}

		static let installedFamilies: [String] = Array(builtInSystemFamilies)
			.sorted { lhs, rhs in
				lhs.localizedStandardCompare(rhs) == .orderedAscending
			}
	}

	#Preview("macOS System Fonts") {
		NavigationStack {
			SystemMonospacedFontListView(selectedFontFamily: .constant("Menlo"))
				.environment(\.appTheme, TerminalTheme.mocha.appTheme)
		}
	}
#endif
