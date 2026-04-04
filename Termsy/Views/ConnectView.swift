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
	@Environment(ViewCoordinator.self) var coordinator

	@State private var host = ""
	@State private var port = "22"
	@State private var username = ""
	@State private var password = ""
	@State private var tmuxSessionName = ""
	@State private var errorMessage: String? = nil
	@State private var autoconnect: Bool = true

	@FocusState private var isFocused

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
					Text("@")
					TextField("Host", text: $host)
						.textContentType(.URL)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
				}
			}
			Section(header: Text("Tmux Session Name"), footer: Text("Will be started using `tmux new-session -A -s`")) {
				TextField("Tmux Session Name", text: $tmuxSessionName)
					.textContentType(.username)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
			}
			Section {
				Toggle("Autoconnect to this session", isOn: $autoconnect)
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
				.disabled(host.isEmpty || username.isEmpty)
				.listRowBackground(host.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
				.foregroundStyle(host.isEmpty ? Color.secondary.opacity(0.5) : Color.white)
				if let errorMessage {
					Text(errorMessage)
						.foregroundStyle(.red)
				}
			}
		}
		.navigationTitle("New Session")
	}
}

#Preview {
	NavigationStack {
		ConnectView { config in
			print("Connect to \(config.hostname)")
		}
	}
}
