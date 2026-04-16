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
	private enum Field: Hashable {
		case username
		case host
		case tmuxSessionName
	}

	var onConnect: (Session) -> Void

	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Environment(\.dismiss) private var dismiss
	@Environment(ViewCoordinator.self) var coordinator

	@State private var host = ""
	@State private var port = "22"
	@AppStorage("lastUsername") private var username = ""
	@State private var tmuxSessionName = ""
	@State private var errorMessage: String? = nil
	@State private var autoconnect: Bool = true

	@FocusState private var focusedField: Field?

	private var canConnect: Bool {
		!host.isEmpty && !username.isEmpty
	}

	var body: some View {
		Form {
			Section("Host Details") {
				HStack {
					TextField("Username", text: $username)
						.accessibilityIdentifier("field.username")
						.textContentType(.username)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.focused($focusedField, equals: .username)
						.submitLabel(.next)
						.foregroundStyle(theme.primaryText)
					Text("@")
						.foregroundStyle(theme.secondaryText)
					TextField("Host", text: $host)
						.accessibilityIdentifier("field.host")
						.textContentType(.URL)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.focused($focusedField, equals: .host)
						.submitLabel(.next)
						.foregroundStyle(theme.primaryText)
				}
				.listRowBackground(theme.cardBackground)
			}
			Section(
				header: Text("Tmux Session Name"),
				footer: Text("Will be started using `tmux new-session -A -s`")
			) {
				TextField("Tmux Session Name", text: $tmuxSessionName)
					.accessibilityIdentifier("field.tmuxSessionName")
					.textContentType(.username)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.focused($focusedField, equals: .tmuxSessionName)
					.submitLabel(canConnect ? .go : .done)
					.foregroundStyle(theme.primaryText)
					.listRowBackground(theme.cardBackground)
			}
			Section {
				Toggle("Autoconnect to this session", isOn: $autoconnect)
					.accessibilityIdentifier("toggle.autoconnect")
					.tint(theme.accent)
					.listRowBackground(theme.cardBackground)
			}
			Section {
				Button("Connect") {
					
					connect()
				}
				.animation(.easeInOut, value: host)
				.accessibilityIdentifier("action.connect")
				.disabled(!canConnect)
				.keyboardShortcut(.defaultAction)
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
		.accessibilityIdentifier("screen.newSession")
		.navigationTitle("New Session")
		.termsyInlineNavigationTitle()
		.toolbar {
			ToolbarItem(placement: .termsyCancellationAction) {
				Button("Cancel") {
					dismissConnectView()
				}
				.keyboardShortcut(.cancelAction)
			}
		}
		.onAppear {
			focusedField = username.isEmpty ? .username : .host
		}
		.onSubmit {
			handleSubmit()
		}
	}

	private func handleSubmit() {
		switch focusedField {
		case .username:
			focusedField = .host
		case .host:
			focusedField = .tmuxSessionName
		case .tmuxSessionName, .none:
			connect()
		}
	}

	private func connect() {
		guard canConnect else { return }

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
		} catch {
			withAnimation {
				errorMessage = "\(error.localizedDescription)"
			}
			return
		}

		onConnect(session)
		dismissConnectView()
	}

	private func dismissConnectView() {
		coordinator.isShowingConnectView = false
		dismiss()
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
