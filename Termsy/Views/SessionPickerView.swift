//
//  SessionPickerView.swift
//  Termsy
//
//  Shown in a trailing panel when tapping + in the tab bar.
//  Lists saved sessions to quickly open, plus a "New Session" option.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionPickerView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.appTheme) private var theme

	var body: some View {
		NavigationStack {
			SessionListContent(
				variant: .picker,
				isSessionOpen: { session in
					coordinator.tabs.contains { tab in
						guard let openSession = tab.session else { return false }
						if let openID = openSession.id, let sessionID = session.id {
							return openID == sessionID
						}
						return openSession.normalizedTargetKey == session.normalizedTargetKey
					}
				},
				onOpenSession: openSession,
				onOpenLocalShell: {
					#if os(macOS)
						openLocalShell()
					#endif
				},
				onOpenNewSession: openNewSession,
				onClose: close
			)
			.navigationTitle("Sessions")
			.termsyInlineNavigationTitle()
			.toolbar {
				ToolbarItem(placement: .termsyPrimaryAction) {
					Button("Done") {
						close()
					}
					.keyboardShortcut(.cancelAction)
				}
			}
			.termsyNavigationBarAppearance(theme)
		}
	}

	private func openSession(_ session: Session) {
		coordinator.openTab(for: session)
		close()
	}

	#if os(macOS)
		private func openLocalShell() {
			close()
			coordinator.openLocalShellTab()
		}
	#endif

	private func openNewSession() {
		close()
		coordinator.isShowingConnectView = true
	}

	private func close() {
		coordinator.isShowingSessionPicker = false
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var primarySession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true,
			customTitle: "Production"
		)
		primarySession.lastConnectedAt = .now
		try primarySession.save(db)

		var secondarySession = Session(
			hostname: "staging.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 2222,
			autoconnect: false
		)
		secondarySession.createdAt = Date.now.addingTimeInterval(-43200)
		try secondarySession.save(db)
	}

	let coordinator = ViewCoordinator()
	return SessionPickerView()
		.databaseContext(.readWrite { db.queue })
		.environment(coordinator)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
