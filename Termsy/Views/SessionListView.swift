//
//  SessionListView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionListView: View {
	@Environment(ViewCoordinator.self) var coordinator

	var body: some View {
		SessionListContent(
			variant: .savedSessions,
			onOpenSession: { session in
				coordinator.openTab(for: session)
			},
			onOpenNewSession: {
				coordinator.openNewTabUI()
			},
			onAppearWithSessions: { sessions in
				if sessions.isEmpty {
					coordinator.isShowingConnectView = true
				}
			}
		)
		.navigationTitle("Teletype")
		.accessibilityIdentifier("screen.savedSessions")
		.toolbar {
			ToolbarItem(placement: .termsyPrimaryAction) {
				Button {
					coordinator.openNewTabUI()
				} label: {
					Label("New Session", systemImage: "plus")
				}
				.accessibilityIdentifier("action.newSession")
				.keyboardShortcut("t", modifiers: .command)
			}
		}
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var defaultPortSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true,
			customTitle: "Production"
		)
		defaultPortSession.lastConnectedAt = .now
		try defaultPortSession.save(db)

		var secondProdSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "worker",
			port: 22,
			autoconnect: true
		)
		secondProdSession.createdAt = Date.now.addingTimeInterval(-3600)
		try secondProdSession.save(db)

		var customPortSession = Session(
			hostname: "staging.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 2222,
			autoconnect: false
		)
		customPortSession.createdAt = Date.now.addingTimeInterval(-86400)
		try customPortSession.save(db)
	}

	let coordinator = ViewCoordinator()
	return NavigationStack {
		SessionListView()
	}
	.databaseContext(.readWrite { db.queue })
	.environment(coordinator)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
