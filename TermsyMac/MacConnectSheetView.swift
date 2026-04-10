#if os(macOS)
	import GRDB
	import GRDBQuery
	import SwiftUI

	private struct MacSavedSessionsRequest: ValueObservationQueryable {
		static var defaultValue: [Session] { [] }

		func fetch(_ db: Database) throws -> [Session] {
			try Session.order(Column("lastConnectedAt")).fetchAll(db)
		}
	}

	struct MacConnectSheetView: View {
		var onConnect: (Session) -> Void

		@Environment(\.databaseContext) private var dbContext
		@Environment(\.appTheme) private var theme
		@Environment(\.dismiss) private var dismiss
		@Query(MacSavedSessionsRequest()) private var savedSessions: [Session]

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
					if !savedSessions.isEmpty {
						Section("Saved Sessions") {
							ForEach(savedSessions, id: \.id) { session in
								Button {
									connectExisting(session)
								} label: {
									VStack(alignment: .leading, spacing: 3) {
										Text("\(session.username)@\(session.hostname)")
											.foregroundStyle(theme.primaryText)
										if let tmuxSessionName = session.tmuxSessionName, !tmuxSessionName.isEmpty {
											Text("tmux • \(tmuxSessionName)")
												.font(.caption)
												.foregroundStyle(theme.secondaryText)
										}
									}
									.frame(maxWidth: .infinity, alignment: .leading)
								}
								.buttonStyle(.plain)
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
			.frame(minWidth: 460, minHeight: 420)
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
					if var existingSession = try Session.filter({
						$0.hostname == session.hostname
//					&&
//					$0.username == session.username &&
//					$0.tmuxSessionName == session.tmuxSessionName &&
//					$0.port == session.port
					}).fetchOne(db) {
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
		return MacConnectSheetView { _ in }
			.databaseContext(.readWrite { db.queue })
			.environment(\.appTheme, TerminalTheme.mocha.appTheme)
	}
#endif
