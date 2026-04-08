#if os(macOS)
import Foundation
import GhosttyTerminal
import Observation

@MainActor
@Observable
final class MacTerminalTab: Identifiable {
	enum Source: Hashable {
		case localShell
		case ssh(Session)
	}

	let id = UUID()
	let source: Source
	let viewState: TerminalViewState
	@ObservationIgnored
	lazy var terminalSession = InMemoryTerminalSession(
		write: { [weak self] data in
			Task { @MainActor [weak self] in
				self?.handleTerminalInput(data)
			}
		},
		resize: { [weak self] viewport in
			Task { @MainActor [weak self] in
				self?.handleViewport(viewport)
			}
		}
	)

	var connectionError: String?
	var isStarting = false
	var hasStarted = false
	var onRequestClose: (() -> Void)?

	@ObservationIgnored private var currentTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
	@ObservationIgnored private var localShellSession: LocalShellSession?
	@ObservationIgnored private var sshSession: MacSSHTerminalSession?
	@ObservationIgnored private var acceptsTerminalOutput = true
	@ObservationIgnored private var terminalDidFinish = false

	init(source: Source) {
		self.source = source

		let controller = TerminalController(
			configSource: .generated(GhosttyConfigBuilder.buildConfigText(theme: TerminalTheme.current)),
			theme: GhosttyTerminal.TerminalTheme()
		)
		self.viewState = TerminalViewState(controller: controller)
		self.viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))

		configureTransport()
	}

	var title: String {
		switch source {
		case .localShell:
			return LocalShellProfile.default.titleFallback
		case let .ssh(session):
			if let tmuxSessionName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
			   !tmuxSessionName.isEmpty {
				return "\(tmuxSessionName) • \(session.username)@\(session.hostname)"
			}
			return "\(session.username)@\(session.hostname)"
		}
	}

	var windowTitle: String {
		let dynamicTitle = viewState.title.trimmingCharacters(in: .whitespacesAndNewlines)
		return dynamicTitle.isEmpty ? title : dynamicTitle
	}

	func reloadConfiguration(theme: TerminalTheme) {
		viewState.controller.updateConfigSource(
			.generated(GhosttyConfigBuilder.buildConfigText(theme: theme))
		)
	}

	func startIfNeeded() async {
		guard !hasStarted, !isStarting else { return }
		isStarting = true
		connectionError = nil
		acceptsTerminalOutput = true
		terminalDidFinish = false
		defer { isStarting = false }

		do {
			switch source {
			case .localShell:
				localShellSession?.updateTerminalSize(currentTerminalSize)
				try localShellSession?.start()
			case .ssh:
				try await sshSession?.start(size: currentTerminalSize)
			}
			hasStarted = true
		} catch {
			connectionError = error.localizedDescription
		}
	}

	func close() {
		acceptsTerminalOutput = false
		localShellSession?.stop()
		sshSession?.stop()
	}

	private func configureTransport() {
		switch source {
		case .localShell:
			let localShellSession = LocalShellSession(profile: LocalShellProfile())
			localShellSession.onRemoteOutput = { [weak self] data in
				Task { @MainActor [weak self] in
					self?.handleTerminalOutput(data)
				}
			}
			localShellSession.onClose = { [weak self] reason in
				Task { @MainActor [weak self] in
					self?.handleLocalShellClose(reason)
				}
			}
			self.localShellSession = localShellSession
		case let .ssh(session):
			let sshSession = MacSSHTerminalSession(session: session)
			sshSession.onOutput = { [weak self] data in
				Task { @MainActor [weak self] in
					self?.handleTerminalOutput(data)
				}
			}
			sshSession.onClose = { [weak self] reason in
				Task { @MainActor [weak self] in
					self?.handleSSHClose(reason)
				}
			}
			self.sshSession = sshSession
		}
	}

	private func handleTerminalInput(_ data: Data) {
		localShellSession?.send(data)
		sshSession?.write(data)
	}

	private func handleTerminalOutput(_ data: Data) {
		guard acceptsTerminalOutput, !terminalDidFinish, !data.isEmpty else { return }
		terminalSession.receive(data)
	}

	private func handleViewport(_ viewport: InMemoryTerminalViewport) {
		let size = TerminalWindowSize(
			columns: Int(max(viewport.columns, 1)),
			rows: Int(max(viewport.rows, 1)),
			pixelWidth: Int(viewport.widthPixels),
			pixelHeight: Int(viewport.heightPixels)
		)
		currentTerminalSize = size
		localShellSession?.updateTerminalSize(size)
		sshSession?.resize(size)
	}

	private func handleLocalShellClose(_ reason: LocalShellSession.CloseReason) {
		hasStarted = false
		acceptsTerminalOutput = false
		switch reason {
		case .localDisconnect:
			break
		case .cleanExit:
			finishTerminal(exitCode: 0, runtimeMilliseconds: 0)
			onRequestClose?()
		case let .error(message):
			connectionError = message
		}
	}

	private func handleSSHClose(_ reason: SSHTerminalSession.CloseReason) {
		hasStarted = false
		acceptsTerminalOutput = false
		switch reason {
		case .localDisconnect:
			break
		case .cleanExit:
			finishTerminal(exitCode: 0, runtimeMilliseconds: 0)
			onRequestClose?()
		case let .error(message):
			connectionError = message
		}
	}

	private func finishTerminal(exitCode: UInt32, runtimeMilliseconds: UInt64) {
		guard !terminalDidFinish else { return }
		terminalDidFinish = true
		acceptsTerminalOutput = false
		terminalSession.finish(exitCode: exitCode, runtimeMilliseconds: runtimeMilliseconds)
	}
}

@MainActor
final class MacSSHTerminalSession {
	let session: Session
	let sshSession = SSHTerminalSession()
	var onOutput: ((Data) -> Void)?
	var onClose: ((SSHTerminalSession.CloseReason) -> Void)?

	init(session: Session) {
		self.session = session
		sshSession.onRemoteOutput = { [weak self] data in
			self?.onOutput?(data)
		}
		sshSession.onClose = { [weak self] reason in
			self?.onClose?(reason)
		}
	}

	func start(size: TerminalWindowSize) async throws {
		sshSession.updateTerminalSize(size)
		try await sshSession.connect(
			host: session.hostname,
			port: session.port,
			username: session.username,
			password: Keychain.password(for: session)
		)
		startTmuxIfNeeded()
	}

	func write(_ data: Data) {
		sshSession.connection.send(data)
	}

	func resize(_ size: TerminalWindowSize) {
		sshSession.updateTerminalSize(size)
	}

	func stop() {
		sshSession.disconnect()
	}

	private func startTmuxIfNeeded() {
		guard let rawName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !rawName.isEmpty
		else { return }

		let escapedName = shellQuoted(rawName)
		let command = Data("tmux new-session -A -s \(escapedName)\r".utf8)

		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			self?.sshSession.connection.send(command)
		}
	}

	private func shellQuoted(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}
}
#endif
