#if os(macOS)
	import AppKit
	import Foundation
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
		@ObservationIgnored let terminalView: MacTerminalView

		var reportedTitle = ""
		private(set) var customTitle: String?
		var connectionError: String?
		var isStarting = false
		var hasStarted = false
		var onRequestClose: (() -> Void)?
		var onRequestRename: (() -> Void)?

		@ObservationIgnored private var currentTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
		@ObservationIgnored private var localShellSession: LocalShellSession?
		@ObservationIgnored private var sshSession: MacSSHTerminalSession?
		@ObservationIgnored private var acceptsTerminalOutput = true
		@ObservationIgnored private var terminalDidFinish = false
		@ObservationIgnored private static var didLogTerminalIOActivation = false

		init(source: Source) {
			self.source = source
			switch source {
			case .localShell:
				self.customTitle = nil
			case let .ssh(session):
				self.customTitle = Self.normalizedTabTitle(session.customTitle)
			}
			self.terminalView = MacTerminalView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
			configureTerminalView()
			configureTransport()
		}

		var automaticTitle: String {
			let dynamicTitle = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			if !dynamicTitle.isEmpty {
				return dynamicTitle
			}

			switch source {
			case .localShell:
				return LocalShellProfile.default.titleFallback
			case let .ssh(session):
				if let tmuxSessionName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
				   !tmuxSessionName.isEmpty
				{
					return "\(tmuxSessionName) • \(session.username)@\(session.hostname)"
				}
				return "\(session.username)@\(session.hostname)"
			}
		}

		var title: String {
			customTitle ?? automaticTitle
		}

		var windowTitle: String {
			title
		}

		func applyTheme(_ theme: AppTheme) {
			terminalView.applyTheme(theme)
		}

		func reloadConfiguration(theme: TerminalTheme) {
			terminalView.applyTheme(theme.appTheme)
			MacGhosttyApp.shared.reloadConfig(theme: theme)
		}

		func setDisplayActive(_ isActive: Bool) {
			terminalView.setDisplayActive(isActive)
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
			terminalView.stop()
			localShellSession?.stop()
			sshSession?.stop()
		}

		func rename(to title: String?) {
			customTitle = Self.normalizedTabTitle(title)
		}

		private func configureTerminalView() {
			terminalView.onWrite = { [weak self] data in
				self?.handleTerminalInput(data)
			}
			terminalView.onResize = { [weak self] _, _ in
				guard let self, let size = self.terminalView.currentTerminalSize() else { return }
				self.handleViewport(size)
			}
			terminalView.onTitleChange = { [weak self] title in
				self?.reportedTitle = title
			}
			terminalView.onRenameTabRequest = { [weak self] in
				self?.onRequestRename?()
			}
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

		private static func normalizedTabTitle(_ title: String?) -> String? {
			guard let title else { return nil }
			let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}

		private func handleTerminalInput(_ data: Data) {
			if MacDebugLogging.isEnabled(
				environmentKey: MacDebugLogging.terminalIOEnvironmentKey,
				defaultsKey: MacDebugLogging.terminalIODefaultsKey
			) {
				if !Self.didLogTerminalIOActivation {
					Self.didLogTerminalIOActivation = true
					print(
						"[TerminalIO] macOS terminal I/O logging enabled (env: \(MacDebugLogging.terminalIOEnvironmentKey)=1, defaults: \(MacDebugLogging.terminalIODefaultsKey)=true)"
					)
				}
				print("[TerminalIO] host <- terminal \(MacDebugLogging.describe(data))")
			}
			localShellSession?.send(data)
			sshSession?.write(data)
		}

		private func handleTerminalOutput(_ data: Data) {
			guard acceptsTerminalOutput, !terminalDidFinish, !data.isEmpty else { return }
			terminalView.feedData(data)
		}

		private func handleViewport(_ size: TerminalWindowSize) {
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
			terminalView.processExited(code: exitCode, runtimeMs: runtimeMilliseconds)
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
