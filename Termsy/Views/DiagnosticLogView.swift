//
//  DiagnosticLogView.swift
//  Termsy
//

import SwiftUI

struct DiagnosticLogView: View {
	@Environment(ViewCoordinator.self) private var coordinator
	@Environment(\.appTheme) private var theme
	@State private var logText = DiagnosticLogStore.shared.readDisplayText()
	@State private var shareURL = DiagnosticLogStore.shared.ensureShareableFile()

	var body: some View {
		Form {
			Section {
				Button {
					coordinator.recordDiagnosticSnapshot(reason: "settings.manualCapture")
					refresh()
				} label: {
					Label("Capture Current State", systemImage: "camera.metering.matrix")
				}
				.listRowBackground(theme.cardBackground)

				ShareLink(item: shareURL) {
					Label("Share Log", systemImage: "square.and.arrow.up")
				}
				.listRowBackground(theme.cardBackground)

				Button(role: .destructive) {
					DiagnosticLogStore.shared.clear()
					refresh()
				} label: {
					Label("Clear Log", systemImage: "trash")
				}
				.listRowBackground(theme.cardBackground)
			} footer: {
				Text("Diagnostics persist between launches and record lifecycle, display, responder, and tab state only. Terminal input/output text and connection targets are not recorded here.")
			}

			Section("Log") {
				ScrollView(.vertical) {
					Text(logText)
						.font(.system(.caption, design: .monospaced))
						.foregroundStyle(theme.primaryText)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
						.padding(.vertical, 4)
				}
				.frame(minHeight: 320)
				.listRowBackground(theme.cardBackground)
			}
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("Diagnostics")
		.termsyInlineNavigationTitle()
		.toolbar {
			ToolbarItem(placement: .termsyPrimaryAction) {
				Button("Refresh") { refresh() }
			}
		}
		.onAppear {
			DiagnosticLogStore.shared.record("diagnostics.view.appear")
			refresh()
		}
	}

	private func refresh() {
		shareURL = DiagnosticLogStore.shared.ensureShareableFile()
		logText = DiagnosticLogStore.shared.readDisplayText()
	}
}

#Preview {
	NavigationStack {
		DiagnosticLogView()
			.environment(ViewCoordinator())
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
}
