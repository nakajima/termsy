#if os(macOS)
	import AppKit
	import CoreText
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

	@MainActor
	enum MacSystemFontCatalog {
		private static let familySystemFlags: [String: Bool] = {
			let descriptor = CTFontDescriptorCreateWithAttributes([:] as CFDictionary)
			let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
			var flags: [String: Bool] = [:]

			for descriptor in matches {
				guard let family = TerminalFontSettings.normalizedFamily(
					CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
				) else {
					continue
				}

				flags[family] = (flags[family] ?? false) || isSystemDescriptor(descriptor)
			}

			return flags
		}()

		static let builtInSystemFamilies: Set<String> = Set(
			familySystemFlags.compactMap { family, isSystem in
				isSystem ? family : nil
			}
		)

		static let monospacedSystemFamilies: [String] = Array(
			Set((NSFontManager.shared.availableFontNames(with: [.fixedPitchFontMask]) ?? [])
				.compactMap { NSFont(name: $0, size: 12)?.familyName })
				.intersection(builtInSystemFamilies)
		)
		.sorted { lhs, rhs in
			lhs.localizedStandardCompare(rhs) == .orderedAscending
		}

		static let installedFamilies: [String] = familySystemFlags
			.compactMap { family, isSystem in
				isSystem ? nil : family
			}
			.sorted { lhs, rhs in
				lhs.localizedStandardCompare(rhs) == .orderedAscending
			}

		private static func isSystemDescriptor(_ descriptor: CTFontDescriptor) -> Bool {
			if let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL {
				return isSystemFontURL(url)
			}

			if let priority = CTFontDescriptorCopyAttribute(descriptor, kCTFontPriorityAttribute) as? NSNumber {
				return priority.intValue == Int(kCTFontPrioritySystem)
			}

			return true
		}

		private static func isSystemFontURL(_ url: URL) -> Bool {
			let path = url.standardizedFileURL.path
			return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
		}
	}

	#Preview("macOS System Fonts") {
		NavigationStack {
			SystemMonospacedFontListView(selectedFontFamily: .constant("Menlo"))
				.environment(\.appTheme, TerminalTheme.mocha.appTheme)
		}
	}
#endif
