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
		try Session.fetchSavedSessions(db)
	}
}

struct SessionListView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) var sessions: [Session]

	var body: some View {
		List {
			#if os(macOS)
				Section("Local") {
					Button {
						coordinator.openLocalShellTab()
					} label: {
						VStack(alignment: .leading, spacing: 4) {
							Text("Local Shell")
								.font(.headline)
								.foregroundStyle(theme.primaryText)
							Text(LocalShellProfile.default.detailText)
								.font(.caption)
								.foregroundStyle(theme.secondaryText)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.vertical, 6)
					}
					.listRowBackground(theme.cardBackground)
				}
			#endif

			Section(sessions.isEmpty ? "Saved Sessions" : "") {
				ForEach(sessions, id: \.id) { session in
					sessionRow(for: session)
				}
				.onDelete(perform: deleteSessions)
			}
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("Teletype")
		.accessibilityIdentifier("screen.savedSessions")
		.toolbar {
			#if os(macOS)
				ToolbarItemGroup(placement: .termsyPrimaryAction) {
					Button {
						coordinator.openLocalShellTab()
					} label: {
						Label("Local Shell", systemImage: "terminal")
					}
					.keyboardShortcut("l", modifiers: .command)

					Button {
						coordinator.openNewTabUI()
					} label: {
						Label("New Session", systemImage: "plus")
					}
					.keyboardShortcut("t", modifiers: .command)
				}
			#else
				ToolbarItem(placement: .termsyPrimaryAction) {
					Button {
						coordinator.openNewTabUI()
					} label: {
						Label("New Session", systemImage: "plus")
					}
					.accessibilityIdentifier("action.newSession")
					.keyboardShortcut("t", modifiers: .command)
				}
			#endif
		}
		.onAppear {
			#if os(iOS)
				if sessions.isEmpty {
					coordinator.isShowingConnectView = true
				}
			#endif
		}
	}

	@ViewBuilder
	private func sessionRow(for session: Session) -> some View {
		Button {
			coordinator.openTab(for: session)
		} label: {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					Text(session.listTitle)
						.font(.headline)
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					if let subtitle = session.listSubtitle {
						Text(subtitle)
							.font(.subheadline)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
					HStack(spacing: 8) {
						if let lastConnectedAt = session.lastConnectedAt {
							Text(lastConnectedAt, style: .relative)
								.monospacedDigit()
						} else {
							Text("Never connected")
						}
					}
					.font(.caption)
					.foregroundStyle(theme.tertiaryText)
				}
				Spacer(minLength: 0)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 6)
		}
		.listRowBackground(theme.cardBackground)
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

		var customPortSession = Session(
			hostname: "staging.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 2222,
			autoconnect: false
		)
		customPortSession.createdAt = Date.now.addingTimeInterval(-86_400)
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
