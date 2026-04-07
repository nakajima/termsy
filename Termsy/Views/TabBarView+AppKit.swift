#if canImport(AppKit) && !canImport(UIKit)
import SwiftUI

struct TabBarRepresentable: View {
	@Environment(ViewCoordinator.self) private var coordinator
	@Environment(\.appTheme) private var theme

	var body: some View {
		HStack(spacing: 8) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(coordinator.tabs) { tab in
						HStack(spacing: 8) {
							Button {
								coordinator.selectTab(tab.id)
							} label: {
								HStack(spacing: 8) {
									if tab.connectionError != nil {
										Image(systemName: "exclamationmark.triangle.fill")
											.foregroundStyle(theme.warning)
									}
									Text(tab.displayTitle)
										.lineLimit(1)
										.foregroundStyle(tab.id == coordinator.selectedTabID ? theme.primaryText : theme.secondaryText)
								}
							}
							.buttonStyle(.plain)

							Button {
								coordinator.closeTab(tab.id)
							} label: {
								Image(systemName: "xmark")
									.font(.system(size: 10, weight: .bold))
							}
							.buttonStyle(.plain)
							.foregroundStyle(theme.tertiaryText)
						}
						.padding(.horizontal, 12)
						.padding(.vertical, 7)
						.background(
							Capsule()
								.fill(tab.id == coordinator.selectedTabID ? theme.selectedBackground : theme.cardBackground)
						)
						.overlay(
							Capsule()
								.stroke(tab.id == coordinator.selectedTabID ? theme.accent.opacity(0.35) : theme.divider, lineWidth: 1)
						)
					}
				}
			}

			Spacer(minLength: 0)

			Button {
				coordinator.openSettings()
			} label: {
				Image(systemName: "gearshape")
			}
			.buttonStyle(.plain)
			.foregroundStyle(theme.secondaryText)

			Button {
				coordinator.openNewTabUI()
			} label: {
				Image(systemName: "plus")
			}
			.buttonStyle(.plain)
			.foregroundStyle(theme.secondaryText)
		}
		.padding(.horizontal, 10)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(theme.background)
	}
}
#endif
