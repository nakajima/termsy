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
		private(set) var isRecording = false
		private(set) var recordingDataByteCount: Int64 = 0
		var onRequestClose: (() -> Void)?
		var onRequestRename: (() -> Void)?
		var onRequestStartRecording: (() -> Void)?
		var onRequestStopRecording: (() -> Void)?

		@ObservationIgnored private var currentTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
		@ObservationIgnored private var localShellSession: LocalShellSession?
		@ObservationIgnored private var sshSession: MacSSHTerminalSession?
		@ObservationIgnored private var acceptsTerminalOutput = true
		@ObservationIgnored private var terminalDidFinish = false
		@ObservationIgnored private var terminalRecorder: TerminalSessionRecorder?
		@ObservationIgnored private var shellActivityState: ShellActivityState?
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

		var needsCloseConfirmation: Bool {
			guard !terminalDidFinish else { return false }

			switch source {
			case .localShell:
				return localShellSession?.needsCloseConfirmation ?? false
			case .ssh:
				guard hasStarted else { return false }
				switch shellActivityState {
				case .some(.prompt):
					return false
				case .some(.command):
					return true
				case .none:
					return terminalView.needsCloseConfirmation
				}
			}
		}

		var recordingFileURL: URL? {
			terminalRecorder?.fileURL
		}

		var recordingSource: TerminalRecording.Source {
			switch source {
			case .localShell:
				.localShell
			case .ssh:
				.remote
			}
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
			_ = stopRecording()
			acceptsTerminalOutput = false
			terminalView.stop()
			localShellSession?.stop()
			sshSession?.stop()
		}

		func rename(to title: String?) {
			customTitle = Self.normalizedTabTitle(title)
		}

		func makeRecordingMetadata(startedAt: Date) -> TerminalRecording {
			let safeColumns = max(currentTerminalSize.columns, 1)
			let safeRows = max(currentTerminalSize.rows, 1)
			let recordingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? automaticTitle : title
			return TerminalRecording(
				sessionID: sessionIDForRecording,
				source: recordingSource,
				targetDescription: detailTextForRecording,
				title: recordingTitle,
				startedAt: startedAt,
				initialColumns: safeColumns,
				initialRows: safeRows,
				fileName: TerminalRecordingStorage.makeFileName(startedAt: startedAt, title: recordingTitle)
			)
		}

		func startRecording(_ recorder: TerminalSessionRecorder) {
			guard terminalRecorder == nil else { return }
			recordingDataByteCount = 0
			terminalRecorder = recorder
			isRecording = true
			terminalView.isRecording = true
			recorder.recordResize(columns: currentTerminalSize.columns, rows: currentTerminalSize.rows)
		}

		func stopRecording() -> TerminalSessionRecorder.Completed? {
			guard let recorder = terminalRecorder else { return nil }
			terminalRecorder = nil
			isRecording = false
			terminalView.isRecording = false
			return recorder.stop()
		}

		private var sessionIDForRecording: Int64? {
			switch source {
			case .localShell:
				nil
			case let .ssh(session):
				session.id
			}
		}

		private var detailTextForRecording: String {
			switch source {
			case .localShell:
				LocalShellProfile.default.detailText
			case let .ssh(session):
				"\(session.username)@\(session.hostname)"
			}
		}

		private func recordTerminalInput(_ data: Data) {
			guard let terminalRecorder, !data.isEmpty else { return }
			recordingDataByteCount += Int64(data.count)
			terminalRecorder.recordInput(data)
		}

		private func recordTerminalOutput(_ data: Data) {
			guard let terminalRecorder, !data.isEmpty else { return }
			recordingDataByteCount += Int64(data.count)
			terminalRecorder.recordOutput(data)
		}

		private func recordTerminalResize(_ size: TerminalWindowSize) {
			terminalRecorder?.recordResize(columns: size.columns, rows: size.rows)
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
				let parsedTitle = ShellTitleState.parse(title)
				self?.reportedTitle = parsedTitle.title
				if let activityState = parsedTitle.activityState {
					self?.shellActivityState = activityState
				}
			}
			terminalView.onRenameTabRequest = { [weak self] in
				self?.onRequestRename?()
			}
			terminalView.onStartRecordingRequest = { [weak self] in
				self?.onRequestStartRecording?()
			}
			terminalView.onStopRecordingRequest = { [weak self] in
				self?.onRequestStopRecording?()
			}
			terminalView.isRecording = isRecording
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
			recordTerminalInput(data)
			localShellSession?.send(data)
			sshSession?.write(data)
		}

		private func handleTerminalOutput(_ data: Data) {
			guard acceptsTerminalOutput, !terminalDidFinish, !data.isEmpty else { return }
			recordTerminalOutput(data)
			terminalView.feedData(data)
		}

		private func handleViewport(_ size: TerminalWindowSize) {
			currentTerminalSize = size
			recordTerminalResize(size)
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
				password: Keychain.password(for: session),
				tmuxSessionName: session.trimmedTmuxSessionName,
				initialWorkingDirectory: session.trimmedInitialWorkingDirectory
			)
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
	}
#endif
