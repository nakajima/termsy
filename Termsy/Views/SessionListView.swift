//
//  SessionListView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionsRequest: ValueObservationQueryable {
	static var defaultValue: [Session] { [] }

	func fetch(_ db: Database) throws -> [Session] {
		try Session
			.order(Column("lastConnectedAt").desc, Column("createdAt").desc)
			.fetchAll(db)
	}
}

struct SessionListView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) var sessions: [Session]

	var body: some View {
		List {
			ForEach(sessions) { session in
				Button {
					coordinator.openTab(for: session)
				} label: {
					VStack(alignment: .leading, spacing: 4) {
						Text("\(session.username)@\(session.hostname)")
							.font(.headline)
							.foregroundStyle(theme.primaryText)
						if let tmuxSessionName = session.tmuxSessionName, !tmuxSessionName.isEmpty {
							Text("tmux • \(tmuxSessionName)")
								.font(.caption)
								.foregroundStyle(theme.secondaryText)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 6)
				}
				.listRowBackground(theme.cardBackground)
			}
			.onDelete(perform: deleteSessions)
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("Termsy")
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					coordinator.openNewTabUI()
				} label: {
					Label("New Session", systemImage: "plus")
				}
				.keyboardShortcut("t", modifiers: .command)
			}
		}
		.onAppear {
			if sessions.isEmpty {
				coordinator.isShowingConnectView = true
			}
		}
	}

	@MainActor
	private func deleteSessions(at offsets: IndexSet) {
		let sessionsToDelete = offsets.map { sessions[$0] }
		guard !sessionsToDelete.isEmpty else { return }

		do {
			try dbContext.writer.write { db in
				for session in sessionsToDelete {
					try session.delete(db)
				}
			}
			sessionsToDelete.forEach(Keychain.removePassword)
		} catch {
			print("[DB] failed to delete sessions: \(error)")
		}
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true
		)
		try session.save(db)
	}

	let coordinator = ViewCoordinator()
	return NavigationStack {
		SessionListView()
	}
	.databaseContext(.readWrite { db.queue })
	.environment(coordinator)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
