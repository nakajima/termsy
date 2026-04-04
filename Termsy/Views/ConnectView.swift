//
//  ConnectView.swift
//  Termsy
//

import GRDB
import GRDBQuery
import SwiftUI

struct ConnectionConfig: Hashable {
	var host: String
	var port: Int
	var username: String
	var password: String
	var tmuxSessionName: String?
}

struct ConnectView: View {
	var onConnect: (Session) -> Void

	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Environment(ViewCoordinator.self) var coordinator

	@State private var host = ""
	@State private var port = "22"
	@State private var username = ""
	@State private var password = ""
	@State private var tmuxSessionName = ""
	@State private var errorMessage: String? = nil
	@State private var autoconnect: Bool = true

	@FocusState private var isFocused

	private var canConnect: Bool {
		!host.isEmpty && !username.isEmpty
	}

	var body: some View {
		Form {
			Section("Host Details") {
				HStack {
					TextField("Username", text: $username)
						.textContentType(.username)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.focused($isFocused)
						.onAppear {
							self.isFocused = true
						}
						.foregroundStyle(theme.primaryText)
					Text("@")
						.foregroundStyle(theme.secondaryText)
					TextField("Host", text: $host)
						.textContentType(.URL)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.foregroundStyle(theme.primaryText)
				}
				.listRowBackground(theme.cardBackground)
			}
			Section(header: Text("Tmux Session Name"), footer: Text("Will be started using `tmux new-session -A -s`")) {
				TextField("Tmux Session Name", text: $tmuxSessionName)
					.textContentType(.username)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.foregroundStyle(theme.primaryText)
					.listRowBackground(theme.cardBackground)
			}
			Section {
				Toggle("Autoconnect to this session", isOn: $autoconnect)
					.tint(theme.accent)
					.listRowBackground(theme.cardBackground)
			}
			Section {
				Button("Connect") {
					var session = Session(
						hostname: host,
						username: username,
						tmuxSessionName: tmuxSessionName.trimmingCharacters(
							in: .whitespacesAndNewlines) == "" ? nil : tmuxSessionName,
						port: Int(port) ?? 22,
						autoconnect: autoconnect
					)

					do {
						try dbContext.writer.write { db in
							try session.save(db)
						}
					} catch {
						withAnimation {
							self.errorMessage = "\(error.localizedDescription)"
						}

						return
					}

					onConnect(session)
					coordinator.isShowingConnectView = false
				}
				.animation(.easeInOut, value: host)
				.disabled(!canConnect)
				.listRowBackground(canConnect ? theme.accent : theme.controlBackground)
				.foregroundStyle(canConnect ? theme.crust : theme.tertiaryText)
				if let errorMessage {
					Text(errorMessage)
						.foregroundStyle(theme.error)
						.listRowBackground(theme.cardBackground)
				}
			}
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("New Session")
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	let coordinator = ViewCoordinator()
	return NavigationStack {
		ConnectView { config in
			print("Connect to \(config.hostname)")
		}
	}
	.databaseContext(.readWrite { db.queue })
	.environment(coordinator)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
