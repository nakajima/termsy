import GRDB
import GRDBQuery
import SwiftUI

private enum SessionEditField: Hashable {
	case initialWorkingDirectory
	case tmuxSessionName
}

struct SessionEditView: View {
	let session: Session
	let onSave: (Session) -> Void

	@Environment(\.databaseContext) private var dbContext
	@Environment(\.appTheme) private var theme
	@Environment(\.dismiss) private var dismiss

	@State private var initialWorkingDirectory: String
	@State private var tmuxSessionName: String
	@State private var errorMessage: String?
	@FocusState private var focusedField: SessionEditField?

	init(session: Session, onSave: @escaping (Session) -> Void = { _ in }) {
		self.session = session
		self.onSave = onSave
		_initialWorkingDirectory = State(initialValue: session.trimmedInitialWorkingDirectory ?? "")
		_tmuxSessionName = State(initialValue: session.trimmedTmuxSessionName ?? "")
	}

	private var sanitizedInitialWorkingDirectory: String? {
		Self.trimmedOptional(initialWorkingDirectory)
	}

	private var sanitizedTmuxSessionName: String? {
		Self.trimmedOptional(tmuxSessionName)
	}

	private var hasChanges: Bool {
		sanitizedInitialWorkingDirectory != session.trimmedInitialWorkingDirectory
			|| sanitizedTmuxSessionName != session.trimmedTmuxSessionName
	}

	var body: some View {
		Form {
			SessionEditTargetSection(displayTarget: session.displayTarget)
			SessionEditFieldsSection(
				initialWorkingDirectory: $initialWorkingDirectory,
				tmuxSessionName: $tmuxSessionName,
				focusedField: $focusedField
			)
			if let errorMessage {
				SessionEditErrorSection(message: errorMessage)
			}
		}
		.scrollContentBackground(.hidden)
		.background(theme.background)
		.navigationTitle("Edit Session")
		.termsyInlineNavigationTitle()
		.toolbar {
			ToolbarItem(placement: .termsyCancellationAction) {
				Button("Cancel") {
					dismiss()
				}
				.keyboardShortcut(.cancelAction)
			}
			ToolbarItem(placement: .termsyPrimaryAction) {
				Button("Save") {
					save()
				}
				.disabled(!hasChanges)
				.keyboardShortcut(.defaultAction)
			}
		}
		.onSubmit {
			handleSubmit()
		}
		.onAppear {
			DispatchQueue.main.async {
				focusedField = .initialWorkingDirectory
			}
		}
		.onChange(of: initialWorkingDirectory, initial: false) { _, _ in
			errorMessage = nil
		}
		.onChange(of: tmuxSessionName, initial: false) { _, _ in
			errorMessage = nil
		}
	}

	private func handleSubmit() {
		switch focusedField {
		case .initialWorkingDirectory:
			focusedField = .tmuxSessionName
		case .tmuxSessionName, .none:
			save()
		}
	}

	@MainActor
	private func save() {
		guard hasChanges else {
			dismiss()
			return
		}

		guard let sessionID = session.id else {
			errorMessage = SessionEditError.missingSession.localizedDescription
			return
		}

		var updatedSession = session
		updatedSession.initialWorkingDirectory = sanitizedInitialWorkingDirectory
		updatedSession.tmuxSessionName = sanitizedTmuxSessionName

		do {
			let persistedSession = try dbContext.writer.write { db -> Session in
				if try Session.conflictingSession(updatedSession, excludingID: sessionID, in: db) != nil {
					throw SessionEditError.duplicateSession
				}

				try db.execute(
					sql: "UPDATE session SET initialWorkingDirectory = ?, tmuxSessionName = ? WHERE id = ?",
					arguments: [updatedSession.initialWorkingDirectory, updatedSession.tmuxSessionName, sessionID]
				)

				guard let persistedSession = try Session.fetchOne(db, key: sessionID) else {
					throw SessionEditError.missingSession
				}
				return persistedSession
			}

			if session.normalizedTargetKey != persistedSession.normalizedTargetKey {
				Keychain.movePasswordIfNeeded(from: session, to: persistedSession)
			}
			onSave(persistedSession)
			dismiss()
		} catch {
			withAnimation {
				errorMessage = error.localizedDescription
			}
		}
	}

	private static func trimmedOptional(_ value: String) -> String? {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}

private enum SessionEditError: LocalizedError {
	case duplicateSession
	case missingSession

	var errorDescription: String? {
		switch self {
		case .duplicateSession:
			"Another saved session already uses that cwd and tmux session."
		case .missingSession:
			"Only saved sessions can be edited."
		}
	}
}

private struct SessionEditTargetSection: View {
	let displayTarget: String

	@Environment(\.appTheme) private var theme

	var body: some View {
		Section("Target") {
			Text(displayTarget)
				.foregroundStyle(theme.primaryText)
				.textSelection(.enabled)
		}
		.listRowBackground(theme.cardBackground)
	}
}

private struct SessionEditFieldsSection: View {
	@Binding var initialWorkingDirectory: String
	@Binding var tmuxSessionName: String
	let focusedField: FocusState<SessionEditField?>.Binding

	@Environment(\.appTheme) private var theme

	var body: some View {
		Section {
			TextField("Working Directory", text: $initialWorkingDirectory)
				.accessibilityIdentifier("field.sessionEdit.cwd")
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.submitLabel(.next)
				.focused(focusedField, equals: .initialWorkingDirectory)
				.foregroundStyle(theme.primaryText)
			TextField("Tmux Session Name", text: $tmuxSessionName)
				.accessibilityIdentifier("field.sessionEdit.tmuxSessionName")
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.submitLabel(.done)
				.focused(focusedField, equals: .tmuxSessionName)
				.foregroundStyle(theme.primaryText)
		} header: {
			Text("Startup")
		} footer: {
			Text("Cwd is applied before tmux starts. Leave either field blank to skip that startup option.")
		}
		.listRowBackground(theme.cardBackground)
	}
}

private struct SessionEditErrorSection: View {
	let message: String

	@Environment(\.appTheme) private var theme

	var body: some View {
		Section {
			Text(message)
				.foregroundStyle(theme.error)
		}
		.listRowBackground(theme.cardBackground)
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	let session = (try? db.queue.write { database in
		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			initialWorkingDirectory: "~/src/termsy",
			port: 22,
			autoconnect: true,
			customTitle: "Production"
		)
		try session.save(database)
		return session
	}) ?? Session(
		hostname: "prod.example.com",
		username: "pat",
		tmuxSessionName: "api",
		initialWorkingDirectory: "~/src/termsy",
		port: 22,
		autoconnect: true,
		customTitle: "Production"
	)

	return NavigationStack {
		SessionEditView(session: session)
	}
	.databaseContext(.readWrite { db.queue })
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
