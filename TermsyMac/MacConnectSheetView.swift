#if os(macOS)
	import GRDB
	import GRDBQuery
	import SwiftUI

	private struct MacSavedSessionsRequest: ValueObservationQueryable {
		static var defaultValue: [Session] { [] }

		func fetch(_ db: Database) throws -> [Session] {
			try Session.fetchSavedSessions(db)
		}
	}

	struct MacConnectSheetView: View {
		var onConnect: (Session) -> Void

		@Environment(\.databaseContext) private var dbContext
		@Environment(\.appTheme) private var theme
		@Environment(\.dismiss) private var dismiss
		@Query(MacSavedSessionsRequest()) private var savedSessions: [Session]

		private var groupedSavedSessions: [SessionHostGroup] {
			Session.groupByHost(savedSessions)
		}

		@State private var host = ""
		@State private var port = "22"
		@State private var username = ""
		@State private var password = ""
		@State private var tmuxSessionName = ""
		@State private var autoconnect = true
		@State private var errorMessage: String?

		private var canConnect: Bool {
			!host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				&& !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}

		var body: some View {
			NavigationStack {
				Form {
					if !groupedSavedSessions.isEmpty {
						ForEach(groupedSavedSessions) { group in
							Section(group.title) {
								ForEach(group.sessions, id: \.id) { session in
									Button {
										connectExisting(session)
									} label: {
										HStack(alignment: .top, spacing: 12) {
											VStack(alignment: .leading, spacing: 5) {
												Text(session.listTitle)
													.foregroundStyle(theme.primaryText)
													.lineLimit(1)
												if let subtitle = session.listSubtitle {
													Text(subtitle)
														.font(.caption)
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
									}
									.buttonStyle(.plain)
								}
							}
						}
					}

					Section("Host") {
						TextField("Hostname", text: $host)
						TextField("Username", text: $username)
						TextField("Port", text: $port)
							.textFieldStyle(.roundedBorder)
					}

					Section("Authentication") {
						SecureField("Password (optional)", text: $password)
					}

					Section("Session") {
						TextField("tmux Session Name (optional)", text: $tmuxSessionName)
						Toggle("Autoconnect to this session", isOn: $autoconnect)
					}

					if let errorMessage {
						Section {
							Text(errorMessage)
								.foregroundStyle(theme.error)
						}
					}
				}
				.formStyle(.grouped)
				.scrollContentBackground(.hidden)
				.background(theme.background)
				.navigationTitle("SSH Sessions")
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("Cancel") {
							dismiss()
						}
					}
					ToolbarItem(placement: .confirmationAction) {
						Button("Connect") {
							saveAndConnect()
						}
						.disabled(!canConnect)
						.keyboardShortcut(.defaultAction)
					}
				}
			}
			.frame(width: 460, height: 420)
		}

		private func connectExisting(_ session: Session) {
			onConnect(session)
			dismiss()
		}

		private func saveAndConnect() {
			guard canConnect else { return }

			var session = Session(
				hostname: host,
				username: username,
				tmuxSessionName: tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : tmuxSessionName,
				port: Int(port) ?? 22,
				autoconnect: autoconnect
			)

			do {
				try dbContext.writer.write { db in
					if var existingSession = try Session.existing(session, in: db) {
						existingSession.hostname = session.hostname
						existingSession.username = session.username
						existingSession.tmuxSessionName = session.tmuxSessionName
						existingSession.port = session.port
						existingSession.autoconnect = session.autoconnect
						try existingSession.update(db)
						session = existingSession
					} else {
						try session.save(db)
					}
				}
				if !password.isEmpty {
					Keychain.setPassword(password, for: session)
				}
				onConnect(session)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
			}
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
			secondarySession.createdAt = Date.now.addingTimeInterval(-43_200)
			try secondarySession.save(db)
		}
		return MacConnectSheetView { _ in }
			.databaseContext(.readWrite { db.queue })
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
#endif
