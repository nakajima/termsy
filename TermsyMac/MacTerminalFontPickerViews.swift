#if os(macOS)
	import AppKit
	import Combine
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

	@MainActor
	final class MacFontPanelController: NSObject, ObservableObject {
		private var currentFontFamily: String?
		private var onSelectFamily: ((String) -> Void)?

		func present(selectedFontFamily: String, onSelectFamily: @escaping (String) -> Void) {
			self.currentFontFamily = TerminalFontSettings.normalizedFamily(selectedFontFamily)
			self.onSelectFamily = onSelectFamily

			let fontManager = NSFontManager.shared
			let fontPanel = NSFontPanel.shared
			let selectedFont = makeSelectedFont()

			fontManager.target = self
			fontManager.action = #selector(changeFont(_:))
			fontManager.setSelectedFont(selectedFont, isMultiple: false)
			fontPanel.setPanelFont(selectedFont, isMultiple: false)
			fontManager.orderFrontFontPanel(nil)
			NSApp.activate(ignoringOtherApps: true)
		}

		@objc
		func changeFont(_ sender: Any?) {
			let fontManager = (sender as? NSFontManager) ?? NSFontManager.shared
			let updatedFont = fontManager.convert(makeSelectedFont())
			guard let family = TerminalFontSettings.normalizedFamily(updatedFont.familyName) else {
				return
			}
			currentFontFamily = family
			onSelectFamily?(family)
		}

		private func makeSelectedFont() -> NSFont {
			if let currentFontFamily,
			   let font = NSFontManager.shared.font(withFamily: currentFontFamily, traits: [], weight: 5, size: 12)
			{
				return font
			}

			if let font = NSFont.userFixedPitchFont(ofSize: 12) {
				return font
			}

			return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
