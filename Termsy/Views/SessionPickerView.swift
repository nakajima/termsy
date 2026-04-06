//
//  SessionPickerView.swift
//  Termsy
//
//  Shown in an inspector when tapping + in the tab bar.
//  Lists saved sessions to quickly open, plus a "New Session" option.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionPickerView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) var sessions: [Session]

	var body: some View {
		NavigationStack {
			List {
				if !sessions.isEmpty {
					Section("Saved Sessions") {
						ForEach(sessions) { session in
							let isOpen = coordinator.tabs.contains { $0.session.uuid == session.uuid }

							Button {
								coordinator.openTab(for: session)
								coordinator.isShowingSessionPicker = false
							} label: {
								HStack {
									VStack(alignment: .leading, spacing: 2) {
										Text("\(session.username)@\(session.hostname)")
											.font(.body)
											.foregroundStyle(theme.primaryText)
										if let tmux = session.tmuxSessionName, !tmux.isEmpty {
											Text("tmux • \(tmux)")
												.font(.caption)
												.foregroundStyle(theme.secondaryText)
										}
									}
									Spacer()
									if isOpen {
										Text("Open")
											.font(.caption)
											.foregroundStyle(theme.secondaryText)
									}
								}
							}
							.listRowBackground(theme.cardBackground)
						}
						.onDelete(perform: deleteSessions)
					}
				}

				Section {
					Button {
						coordinator.isShowingSessionPicker = false
						coordinator.isShowingConnectView = true
					} label: {
						Label("New Session", systemImage: "plus.circle")
							.font(.body)
							.foregroundStyle(.tint)
					}
					.keyboardShortcut("t", modifiers: .command)
					.listRowBackground(theme.cardBackground)
				}
			}
			.scrollContentBackground(.hidden)
			.background(theme.background)
			.navigationTitle("Sessions")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") {
						coordinator.isShowingSessionPicker = false
					}
					.keyboardShortcut(.cancelAction)
				}
			}
			.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
		}
	}

	@MainActor
	private func deleteSessions(at offsets: IndexSet) {
		let sessionsToDelete = offsets.map { sessions[$0] }
		guard !sessionsToDelete.isEmpty else { return }

		do {
			try dbContext.writer.write { db in
				for var session in sessionsToDelete {
					session.markDeleted()
					try session.update(db)
				}
			}
			sessionsToDelete.forEach(Keychain.removePassword)
			SessionRecordSync.scheduleSync(dbContext: dbContext, reason: "delete session")
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
	return SessionPickerView()
		.databaseContext(.readWrite { db.queue })
		.environment(coordinator)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
