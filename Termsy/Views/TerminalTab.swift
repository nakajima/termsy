//
//  TerminalTab.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif

/// Represents a single open terminal tab.
@Observable @MainActor
class TerminalTab: Identifiable {
	enum RestorationMode {
		case launch
		case backgroundReconnect

		var showsProgress: Bool {
			switch self {
			case .launch:
				true
			case .backgroundReconnect:
				false
			}
		}
	}

	enum OverlayState {
		case connected
		case connecting
		case awaitingPassword
		case failed(String)
		case restoring(RestorationMode)
	}

	private enum ConnectionPhase: Equatable {
		case idle
		case connecting
		case connected
		case waitingForPassword
		case failed(String)
	}

	private enum ConnectionAttemptPresentation {
		case initial
		case restoringSnapshot
	}

	let endpoint: TerminalEndpoint
	var session: Session?
	var sshSession = SSHTerminalSession()
	#if os(macOS)
		private let localShellSession: LocalShellSession?
	#endif
	var terminalView: TerminalView
	private var phase: ConnectionPhase = .idle
	var connectionError: String? {
		get {
			if case let .failed(message) = phase { return message }
			return nil
		}
		set {
			if let newValue {
				phase = .failed(newValue)
			} else if case .failed = phase {
				phase = .idle
			}
		}
	}

	var isConnected: Bool {
		get { phase == .connected }
		set { phase = newValue ? .connected : .idle }
	}

	var needsPassword: Bool {
		get { phase == .waitingForPassword }
		set {
			if newValue {
				phase = .waitingForPassword
			} else if phase == .waitingForPassword {
				phase = .idle
			}
		}
	}

	var restorationMode: RestorationMode?
	var onRequestClose: (() -> Void)?
	var onRequestNewTab: (() -> Void)?
	var onRequestSelectTab: ((Int) -> Void)?
	var onRequestMoveTabSelection: ((Int) -> Void)?
	var onRequestShowSettings: (() -> Void)?
	var onRequestDismissAuxiliaryUI: (() -> Bool)?
	var onConnectionEstablished: ((Session) -> Void)?
	var onOverlayStateChange: (() -> Void)?
	var onTerminalViewReplacementRequested: (() -> Void)?
	var reportedTitle = ""
	var connectionLog: [String] = []
	private(set) var isRecording = false
	private(set) var recordingDataByteCount: Int64 = 0
	#if canImport(UIKit)
		@ObservationIgnored private var restorationSnapshot: UIImage?
		var displaySnapshot: UIImage? {
			restorationSnapshot
		}
	#endif
	@ObservationIgnored var onFirstRemoteOutput: (() -> Void)?
	@ObservationIgnored private var pendingPreviewTranscript: String?
	@ObservationIgnored private var pendingPreviewReadinessLabel: String?
	@ObservationIgnored private var isPassivePreview = false
	@ObservationIgnored private(set) var isDisplayActive = false
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	@ObservationIgnored private var scheduledConnectionTask: Task<Void, Never>?
	@ObservationIgnored private let activationReconnectDelayNanoseconds: UInt64 = 750_000_000
	@ObservationIgnored private let reconnectRetryDelayNanoseconds: UInt64 = 2_000_000_000
	@ObservationIgnored private var remoteConnectAttempt = 0
	@ObservationIgnored private var wantsConnection = true
	@ObservationIgnored private var terminalRecorder: TerminalSessionRecorder?

	let id = UUID()

	init(session: Session) {
		self.endpoint = .remote
		self.session = session
		self.customTitle = Self.normalizedTabTitle(session.customTitle)
		self.terminalView = TerminalView(frame: .zero)
		#if canImport(UIKit)
			if session.isOpen {
				self.restorationMode = .launch
				if let snapshotData = session.lastTerminalSnapshotJPEGData {
					self.restorationSnapshot = UIImage(data: snapshotData)
				} else {
					self.restorationSnapshot = nil
				}
			} else {
				self.restorationMode = nil
				self.restorationSnapshot = nil
			}
		#endif
		#if os(macOS)
			self.localShellSession = nil
		#endif

		configureTerminalView()
		configureSSHSessionCallbacks()
	}

	#if os(macOS)
		init(localShellProfile: LocalShellProfile = .default) {
			self.endpoint = .localShell(localShellProfile)
			self.session = nil
			self.terminalView = TerminalView(frame: .zero)
			self.localShellSession = LocalShellSession(profile: localShellProfile)

			configureTerminalView()
			localShellSession?.onRemoteOutput = { [weak self] data in
				self?.recordTerminalOutput(data)
				self?.terminalView.feedData(data)
			}
			localShellSession?.onClose = { [weak self] reason in
				self?.handleLocalShellClose(reason)
			}
		}
	#endif

	private(set) var customTitle: String?

	var automaticTitle: String {
		switch endpoint {
		case .remote:
			guard let session else { return "Session" }
			if let tmuxTitle = startupTmuxTabTitle(for: session) {
				return tmuxTitle
			}
			let dynamicTitle = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			if !dynamicTitle.isEmpty {
				return dynamicTitle
			}
			return "\(session.username)@\(session.hostname)"
		case let .localShell(profile):
			let dynamicTitle = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			if !dynamicTitle.isEmpty {
				return dynamicTitle
			}
			return profile.titleFallback
		}
	}

	private func startupTmuxTabTitle(for session: Session) -> String? {
		guard let tmuxName = session.trimmedTmuxSessionName else { return nil }
		let trimmedHostname = session.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
		let hostname = trimmedHostname.isEmpty ? session.hostname : trimmedHostname
		return "\(hostname)#\(tmuxName)"
	}

	var displayTitle: String {
		customTitle ?? automaticTitle
	}

	var detailText: String {
		switch endpoint {
		case .remote:
			guard let session else { return "" }
			return "\(session.username)@\(session.hostname)"
		case let .localShell(profile):
			return profile.detailText
		}
	}

	var recordingFileURL: URL? {
		terminalRecorder?.fileURL
	}

	var recordingSource: TerminalRecording.Source {
		switch endpoint {
		case .remote:
			.remote
		case .localShell:
			.localShell
		}
	}

	var progressTitle: String {
		switch endpoint {
		case .remote:
			guard let session else { return "Connecting\u{2026}" }
			return "Connecting to \(session.hostname)\u{2026}"
		case .localShell:
			return "Starting local shell\u{2026}"
		}
	}

	var failureTitle: String {
		switch endpoint {
		case .remote: "Connection Failed"
		case .localShell: "Local Shell Failed"
		}
	}

	var isLocalShell: Bool {
		if case .localShell = endpoint { return true }
		return false
	}

	var overlayState: OverlayState {
		if let restorationMode {
			return .restoring(restorationMode)
		}
		switch phase {
		case .connecting:
			return .connecting
		case .waitingForPassword:
			return .awaitingPassword
		case let .failed(message):
			return .failed(message)
		case .idle, .connected:
			return .connected
		}
	}

	var showsOverlay: Bool {
		switch overlayState {
		case .connected, .failed:
			false
		case .connecting, .awaitingPassword, .restoring:
			true
		}
	}

	var isRestoring: Bool { restorationMode != nil }

	var showsConnectingOverlay: Bool {
		if case .connecting = overlayState { return true }
		return false
	}

	var showsRestoringProgress: Bool {
		restorationMode?.showsProgress ?? false
	}

	var connectionIsActive: Bool {
		if isPassivePreview {
			return true
		}
		switch endpoint {
		case .remote:
			return sshSession.connection.isActive
		case .localShell:
			#if os(macOS)
				return localShellSession?.isActive ?? false
			#else
				return false
			#endif
		}
	}

	var connectionLogText: String {
		connectionLog.joined(separator: "\n")
	}

	var shouldRequestBackgroundExecution: Bool {
		guard !isPassivePreview else { return false }
		guard case .remote = endpoint else { return false }
		return isConnected || phase == .connecting
	}

	private var shouldDeferRemoteConnectionUntilAppActive: Bool {
		guard case .remote = endpoint else { return false }
		#if canImport(UIKit) && !os(macOS)
			return !ApplicationActivity.isActive
		#else
			return false
		#endif
	}

	func hostDidAppear() {
		renderPendingPreviewIfNeeded()
		wantsConnection = true
		beginConnectionAttemptIfNeeded(presentation: connectionPresentationForCurrentState)
	}

	func retryConnection(preservingRestoration: Bool = false) {
		restartConnection(
			presentation: preservingRestoration ? .restoringSnapshot : .initial,
			preservingRestoration: preservingRestoration
		)
	}

	private var connectionPresentationForCurrentState: ConnectionAttemptPresentation {
		if case .backgroundReconnect = restorationMode {
			return .restoringSnapshot
		}
		return .initial
	}

	private func restartConnection(
		presentation: ConnectionAttemptPresentation,
		preservingRestoration: Bool
	) {
		guard !isPassivePreview else { return }
		logConnectionEvent("Reconnect requested")
		connectTask?.cancel()
		connectTask = nil
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = nil
		if !preservingRestoration {
			finishRestorationPresentation()
		}
		wantsConnection = true
		connectionError = nil
		if phase == .connected || phase == .connecting {
			switch endpoint {
			case .remote:
				sshSession.disconnect()
			case .localShell:
				break
			}
		}
		phase = .idle
		notifyOverlayStateChanged()
		beginConnectionAttemptIfNeeded(presentation: presentation)
	}

	private func beginConnectionAttemptIfNeeded(
		after delayNanoseconds: UInt64 = 0,
		presentation: ConnectionAttemptPresentation
	) {
		guard !isPassivePreview else {
			renderPendingPreviewIfNeeded()
			return
		}
		guard wantsConnection else { return }
		if delayNanoseconds > 0 {
			scheduleConnectionAttempt(after: delayNanoseconds, presentation: presentation)
			return
		}
		guard terminalView.hasAttachedWindow else { return }
		if shouldDeferRemoteConnectionUntilAppActive {
			logConnectionEvent("Deferring connection until app becomes active")
			return
		}
		guard phase == .idle,
		      connectTask == nil,
		      !connectionIsActive
		else {
			return
		}

		applyConnectionPresentation(presentation)
		phase = .connecting
		notifyOverlayStateChanged()
		connectTask = Task { @MainActor [weak self] in
			defer {
				self?.connectTask = nil
				self?.notifyOverlayStateChanged()
			}
			guard let self else { return }
			if self.shouldDeferRemoteConnectionUntilAppActive {
				self.phase = .idle
				self.logConnectionEvent("Deferred pending connection because app is inactive")
				return
			}
			await self.connect(presentation: presentation)
		}
	}

	private func scheduleConnectionAttempt(
		after delayNanoseconds: UInt64,
		presentation: ConnectionAttemptPresentation
	) {
		guard wantsConnection else { return }
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: delayNanoseconds)
			guard !Task.isCancelled else { return }
			self?.scheduledConnectionTask = nil
			self?.beginConnectionAttemptIfNeeded(presentation: presentation)
		}
	}

	private func connect(presentation: ConnectionAttemptPresentation) async {
		if isPassivePreview {
			renderPendingPreviewIfNeeded()
			return
		}
		if shouldDeferRemoteConnectionUntilAppActive {
			phase = .idle
			logConnectionEvent("Connection request deferred because app is inactive")
			return
		}
		phase = .connecting
		connectionError = nil
		notifyOverlayStateChanged()
		logConnectionEvent("Connect requested")
		switch endpoint {
		case .remote:
			await connectRemote(presentation: presentation)
		case .localShell:
			#if os(macOS)
				await connectLocalShell()
			#endif
		}
	}

	private func connectRemote(presentation: ConnectionAttemptPresentation) async {
		guard let session else { return }
		logConnectionEvent("Checking saved credentials")
		let keychainPassword = Keychain.password(for: session)
		logConnectionEvent(
			keychainPassword == nil
				? "No saved password available"
				: "Using saved password from keychain"
		)
		await performRemoteConnect(
			password: keychainPassword,
			presentation: presentation,
			savePasswordOnSuccess: false
		)
	}

	private func performRemoteConnect(
		password: String?,
		presentation: ConnectionAttemptPresentation,
		savePasswordOnSuccess: Bool
	) async {
		guard let session else { return }
		remoteConnectAttempt += 1
		let attempt = remoteConnectAttempt
		let sshSession = resetSSHSessionForNewConnection(attempt: attempt)
		let tmuxSessionName = configuredTmuxSessionName(for: session)
		let initialWorkingDirectory = session.trimmedInitialWorkingDirectory
		let startupModeMessage = if let tmuxSessionName {
			"Attempt \(attempt): starting remote session directly in tmux \(tmuxSessionName)"
		} else {
			"Attempt \(attempt): starting remote login shell"
		}
		logConnectionEvent("Attempt \(attempt): connecting to \(session.username)@\(session.hostname):\(session.port)")
		logConnectionEvent(startupModeMessage)
		if let initialWorkingDirectory {
			logConnectionEvent("Attempt \(attempt): starting in \(initialWorkingDirectory)")
		}
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: password,
				tmuxSessionName: tmuxSessionName,
				initialWorkingDirectory: initialWorkingDirectory
			)
			guard !Task.isCancelled, self.sshSession === sshSession else {
				logConnectionEvent("Attempt \(attempt): ignoring stale successful connection")
				sshSession.disconnect()
				return
			}
			wantsConnection = true
			phase = .connected
			connectionError = nil
			self.session?.lastConnectedAt = Date()
			if savePasswordOnSuccess, let password {
				Keychain.setPassword(password, for: session)
			}
			notifyOverlayStateChanged()
			logConnectionEvent("Attempt \(attempt): connection established")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
		} catch SSHConnectionError.authenticationFailed {
			guard self.sshSession === sshSession else { return }
			finishRestorationPresentation()
			logConnectionEvent("Attempt \(attempt): authentication failed; prompting for password")
			wantsConnection = false
			phase = .waitingForPassword
			notifyOverlayStateChanged()
		} catch {
			guard self.sshSession === sshSession else { return }
			switch presentation {
			case .initial:
				finishRestorationPresentation()
				phase = .failed("\(error)")
			case .restoringSnapshot:
				phase = .idle
				applyConnectionPresentation(.restoringSnapshot)
			}
			if shouldDeferRemoteConnectionUntilAppActive {
				logConnectionEvent("Attempt \(attempt): connection failed while app inactive; reconnect deferred: \(error)")
				notifyOverlayStateChanged()
				return
			}
			logConnectionEvent("Attempt \(attempt): connection failed: \(error)")
			notifyOverlayStateChanged()
			beginConnectionAttemptIfNeeded(after: reconnectRetryDelayNanoseconds, presentation: presentation)
		}
	}

	#if os(macOS)
		private func connectLocalShell() async {
			guard let localShellSession else { return }
			do {
				try localShellSession.start()
				phase = .connected
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			} catch {
				finishRestorationPresentation()
				print("[LocalShell] failed to start: \(error)")
				phase = .failed(error.localizedDescription)
				notifyOverlayStateChanged()
			}
		}
	#endif

	private func configuredTmuxSessionName(for session: Session?) -> String? {
		guard let rawTmuxSessionName = session?.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !rawTmuxSessionName.isEmpty
		else {
			return nil
		}
		return rawTmuxSessionName
	}

	private func resetSSHSessionForNewConnection(attempt: Int) -> SSHTerminalSession {
		let previousSession = sshSession
		let terminalSize = previousSession.terminalSize
		let wasForeground = previousSession.isForeground
		previousSession.onRemoteOutput = nil
		previousSession.onClose = nil
		previousSession.onEvent = nil
		previousSession.disconnect()

		let newSession = SSHTerminalSession()
		sshSession = newSession
		configureSSHSessionCallbacks(for: newSession)
		newSession.updateTerminalSize(terminalSize)
		if !wasForeground {
			newSession.enterBackground()
		}
		logConnectionEvent("Attempt \(attempt): created fresh SSH transport")
		return newSession
	}

	private func applyConnectionPresentation(_ presentation: ConnectionAttemptPresentation) {
		switch presentation {
		case .initial:
			return
		case .restoringSnapshot:
			guard case .remote = endpoint else { return }
			#if canImport(UIKit)
				if case .backgroundReconnect = restorationMode, restorationSnapshot != nil {
					return
				}
				beginRestoration(.backgroundReconnect, snapshot: restorationSnapshot ?? terminalView.captureSnapshot())
			#else
				if case .backgroundReconnect = restorationMode {
					return
				}
				beginRestoration(.backgroundReconnect)
			#endif
		}
	}

	private func finishRestorationPresentation() {
		restorationMode = nil
		#if canImport(UIKit)
			restorationSnapshot = nil
		#endif
		notifyOverlayStateChanged()
	}

	#if canImport(UIKit)
		private func beginRestoration(_ mode: RestorationMode, snapshot: UIImage?) {
			restorationMode = mode
			restorationSnapshot = snapshot
			notifyOverlayStateChanged()
		}
	#else
		private func beginRestoration(_ mode: RestorationMode) {
			restorationMode = mode
			notifyOverlayStateChanged()
		}
	#endif

	private func configureSSHSessionCallbacks(for sshSession: SSHTerminalSession? = nil) {
		let sshSession = sshSession ?? self.sshSession
		sshSession.onRemoteOutput = { [weak self, weak sshSession] data in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			if self.restorationMode != nil {
				self.finishRestorationPresentation()
			}
			if self.phase == .connecting {
				self.phase = .connected
				self.connectionError = nil
				self.notifyOverlayStateChanged()
			}
			if let onFirstRemoteOutput = self.onFirstRemoteOutput {
				self.onFirstRemoteOutput = nil
				onFirstRemoteOutput()
			}
			self.recordTerminalOutput(data)
			self.terminalView.feedData(data)
		}
		sshSession.onClose = { [weak self, weak sshSession] reason in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			self.handleSSHSessionClose(reason)
		}
		sshSession.onEvent = { [weak self, weak sshSession] message in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			self.logConnectionEvent(message)
		}
	}

	func connectWithPassword(_ password: String) async {
		guard case .remote = endpoint else { return }
		wantsConnection = true
		phase = .connecting
		connectionError = nil
		logConnectionEvent("Retrying with password")
		await performRemoteConnect(
			password: password,
			presentation: .initial,
			savePasswordOnSuccess: true
		)
	}

	func disconnect() {
		wantsConnection = false
		connectTask?.cancel()
		connectTask = nil
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = nil
		if isPassivePreview {
			phase = .idle
			pendingPreviewTranscript = nil
			notifyOverlayStateChanged()
			return
		}
		phase = .idle
		notifyOverlayStateChanged()
		logConnectionEvent("Disconnect requested")
		switch endpoint {
		case .remote:
			sshSession.disconnect()
		case .localShell:
			#if os(macOS)
				localShellSession?.disconnect()
			#endif
		}
	}

	func close() {
		_ = stopRecording()
		disconnect()
		terminalView.stop()
		terminalView.removeFromSuperview()
	}

	func resetTerminalView() {
		reportedTitle = ""
		terminalView.stop()
		terminalView.removeFromSuperview()
		terminalView = TerminalView(frame: .zero)
		if isPassivePreview {
			terminalView.setPresentationMode(.passivePreview)
		}
		configureTerminalView()
		terminalView.setDisplayActive(isDisplayActive)
		onTerminalViewReplacementRequested?()
	}

	#if canImport(UIKit)
		func capturePersistedSnapshotJPEGData() -> Data? {
			guard case .remote = endpoint,
			      let jpegData = terminalView.capturePersistedSnapshotJPEGData()
			else {
				return nil
			}
			session?.lastTerminalSnapshotJPEGData = jpegData
			if restorationMode == .launch {
				restorationSnapshot = UIImage(data: jpegData)
			}
			return jpegData
		}

		func prepareScreenshotBackgroundReconnect(readinessLabel: String, retryCount: Int = 12) {
			guard retryCount > 0 else {
				print("[Screenshots] failed to prepare \(readinessLabel)")
				return
			}
			renderPendingPreviewIfNeeded()
			guard terminalView.hasAttachedWindow else {
				Task { @MainActor [weak self] in
					try? await Task.sleep(nanoseconds: 100_000_000)
					self?.prepareScreenshotBackgroundReconnect(readinessLabel: readinessLabel, retryCount: retryCount - 1)
				}
				return
			}
			beginRestoration(.backgroundReconnect, snapshot: terminalView.captureSnapshot())
			print("[Screenshots] ready \(readinessLabel)")
		}
	#endif

	func applyTheme(_ theme: AppTheme) {
		terminalView.applyTheme(theme)
	}

	func preparePassivePreview(transcript: String, screenshotReadyLabel: String? = nil) {
		isPassivePreview = true
		pendingPreviewTranscript = transcript
		pendingPreviewReadinessLabel = screenshotReadyLabel
		wantsConnection = false
		phase = .connected
		connectionError = nil
		finishRestorationPresentation()
		terminalView.setPresentationMode(.passivePreview)
		connectionLog = [
			"[Demo] Loaded canned transcript for preview",
			"[Demo] Session target: \(detailText)",
		]
		notifyOverlayStateChanged()
	}

	func renderPendingPreviewIfNeeded() {
		guard isPassivePreview, let transcript = pendingPreviewTranscript else { return }
		terminalView.start()
		terminalView.feedData(Data(transcript.utf8))
		pendingPreviewTranscript = nil
		if let pendingPreviewReadinessLabel {
			print("[Screenshots] ready \(pendingPreviewReadinessLabel)")
			self.pendingPreviewReadinessLabel = nil
		}
	}

	func setDisplayActive(_ isActive: Bool) {
		isDisplayActive = isActive
		terminalView.setDisplayActive(isActive)
	}

	func enterForeground() {
		switch endpoint {
		case .remote:
			sshSession.enterForeground()
		case .localShell:
			break
		}
	}

	func enterBackground() {
		switch endpoint {
		case .remote:
			sshSession.enterBackground()
		case .localShell:
			break
		}
	}

	func noteAppWillResignActive() {
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = nil
		#if canImport(UIKit)
			if case .remote = endpoint,
			   isConnected,
			   !isPassivePreview,
			   terminalView.hasAttachedWindow
			{
				restorationSnapshot = terminalView.captureSnapshot()
			}
		#endif
		if ApplicationActivity.hasBackgroundExecution, shouldRequestBackgroundExecution {
			logConnectionEvent("Requested iOS background execution to keep the SSH session alive")
		}
		logConnectionEvent("App will resign active; state=\(phaseDescription) wantsConnection=\(wantsConnection)")
	}

	func noteAppDidEnterBackground() {
		guard case .remote = endpoint, !isPassivePreview else { return }
		logConnectionEvent(
			"App did enter background; shouldRequestBackgroundExecution=\(shouldRequestBackgroundExecution) "
				+ "backgroundTaskActive=\(ApplicationActivity.hasBackgroundExecution) "
				+ "remaining=\(Self.backgroundTimeRemainingDescription(ApplicationActivity.backgroundTimeRemaining))"
		)
	}

	func noteBackgroundExecutionRequested(
		granted: Bool,
		alreadyActive: Bool,
		remaining: TimeInterval?
	) {
		guard case .remote = endpoint, !isPassivePreview else { return }
		logConnectionEvent(
			"Background execution request: granted=\(granted) alreadyActive=\(alreadyActive) "
				+ "remaining=\(Self.backgroundTimeRemainingDescription(remaining))"
		)
	}

	func noteBackgroundExecutionExpired(remaining: TimeInterval?) {
		guard case .remote = endpoint, !isPassivePreview else { return }
		logConnectionEvent(
			"Background execution expired; remaining=\(Self.backgroundTimeRemainingDescription(remaining))"
		)
	}

	func noteBackgroundExecutionEnded(remainingBeforeEnd: TimeInterval?) {
		guard case .remote = endpoint, !isPassivePreview else { return }
		logConnectionEvent(
			"Ended background execution; remainingBeforeEnd="
				+ Self.backgroundTimeRemainingDescription(remainingBeforeEnd)
		)
	}

	func noteAppDidBecomeActive() {
		guard wantsConnection else { return }
		if phase == .connected, !connectionIsActive {
			logConnectionEvent("App became active; connection was inactive; preparing background reconnect")
			#if canImport(UIKit)
				prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
			#else
				prepareForReconnectAfterBackgroundLoss()
			#endif
			return
		}
		if phase == .idle || phase == .connecting {
			logConnectionEvent("App became active; reconciling connection")
			if phase == .connecting, connectTask == nil, !connectionIsActive {
				phase = .idle
			}
			beginConnectionAttemptIfNeeded(
				after: activationReconnectDelayNanoseconds,
				presentation: connectionPresentationForCurrentState
			)
		}
	}

	#if canImport(UIKit)
		func prepareForReconnectAfterBackgroundLoss(snapshot: UIImage? = nil) {
			guard case .remote = endpoint, !isPassivePreview else {
				retryConnection()
				return
			}
			beginRestoration(.backgroundReconnect, snapshot: snapshot ?? restorationSnapshot ?? terminalView.captureSnapshot())
			resetTerminalView()
			retryConnection(preservingRestoration: true)
		}
	#else
		func prepareForReconnectAfterBackgroundLoss() {
			guard case .remote = endpoint, !isPassivePreview else {
				retryConnection()
				return
			}
			beginRestoration(.backgroundReconnect)
			resetTerminalView()
			retryConnection(preservingRestoration: true)
		}
	#endif

	private func isRecoverableBackgroundDisconnectMessage(_ message: String) -> Bool {
		let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !normalized.isEmpty else { return false }
		let keywords = [
			"tcpshutdown",
			"tcp shutdown",
			"timeout",
			"timed out",
			"nwtcpconnection",
			"network connection was lost",
			"network is down",
			"not connected",
			"socket is not connected",
			"connection reset",
			"broken pipe",
			"connection abort",
			"connection aborted",
			"software caused connection abort",
			"connection closed unexpectedly",
			"host is down",
			"econnreset",
			"enotconn",
			"etimedout",
			"econnaborted",
			"posixerror",
		]
		return keywords.contains { normalized.contains($0) }
	}

	private func shouldReconnectAfterClose(message: String, wasConnectedBeforeClose: Bool) -> Bool {
		guard case .remote = endpoint else { return false }
		guard wantsConnection else { return false }
		return wasConnectedBeforeClose || isRecoverableBackgroundDisconnectMessage(message)
	}

	private var phaseDescription: String {
		switch phase {
		case .idle: "idle"
		case .connecting: "connecting"
		case .connected: "connected"
		case .waitingForPassword: "waitingForPassword"
		case let .failed(message): "failed(\(message))"
		}
	}

	func updateTerminalSize(_ size: TerminalWindowSize) {
		recordTerminalResize(size)
		switch endpoint {
		case .remote:
			sshSession.updateTerminalSize(size)
		case .localShell:
			#if os(macOS)
				localShellSession?.updateTerminalSize(size)
			#endif
		}
	}

	private func logConnectionEvent(_ message: String) {
		let timestamp = Date().formatted(date: .omitted, time: .standard)
		connectionLog.append("[\(timestamp)] \(message)")
		if connectionLog.count > 120 {
			connectionLog.removeFirst(connectionLog.count - 120)
		}
	}

	private static func backgroundTimeRemainingDescription(_ remaining: TimeInterval?) -> String {
		guard let remaining else { return "unavailable" }
		guard remaining.isFinite else { return "unlimited" }
		if remaining >= TimeInterval(Int32.max) {
			return "unlimited"
		}
		return String(format: "%.1fs", remaining)
	}

	private func notifyOverlayStateChanged() {
		onOverlayStateChange?()
	}

	private func handleTerminalInputSendFailure() {
		guard case .remote = endpoint, wantsConnection else { return }
		guard phase != .connecting else { return }
		logConnectionEvent("Terminal input could not be sent because the SSH session channel is inactive")
		connectionError = nil
		#if canImport(UIKit)
			prepareForReconnectAfterBackgroundLoss(snapshot: displaySnapshot ?? terminalView.captureSnapshot())
		#else
			prepareForReconnectAfterBackgroundLoss()
		#endif
	}

	private func configureTerminalView() {
		terminalView.delegate = self
	}

	func rename(to title: String?) {
		let normalizedTitle = Self.normalizedTabTitle(title)
		customTitle = normalizedTitle
		session?.customTitle = normalizedTitle
	}

	func makeRecordingMetadata(startedAt: Date) -> TerminalRecording {
		let size = terminalView.currentTerminalSize() ?? sshSession.terminalSize
		let safeColumns = max(size.columns, 1)
		let safeRows = max(size.rows, 1)
		let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let recordingTitle = title.isEmpty ? automaticTitle : title
		return TerminalRecording(
			sessionID: session?.id,
			source: recordingSource,
			targetDescription: detailText,
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
		if let size = terminalView.currentTerminalSize() {
			recorder.recordResize(columns: size.columns, rows: size.rows)
		}
	}

	func stopRecording() -> TerminalSessionRecorder.Completed? {
		guard let recorder = terminalRecorder else { return nil }
		terminalRecorder = nil
		isRecording = false
		return recorder.stop()
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

	private static func normalizedTabTitle(_ title: String?) -> String? {
		guard let title else { return nil }
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	func requestReconnect() {
		#if canImport(UIKit)
			prepareForReconnectAfterBackgroundLoss(snapshot: displaySnapshot)
		#else
			prepareForReconnectAfterBackgroundLoss()
		#endif
	}

	private func handleSSHSessionClose(_ reason: SSHTerminalSession.CloseReason) {
		let wasConnectedBeforeClose = isConnected
		connectTask?.cancel()
		connectTask = nil
		if phase == .connecting || phase == .connected {
			phase = .idle
		}

		switch reason {
		case .localDisconnect:
			logConnectionEvent("SSH session closed locally")
			if wantsConnection {
				notifyOverlayStateChanged()
				beginConnectionAttemptIfNeeded(
					after: activationReconnectDelayNanoseconds,
					presentation: connectionPresentationForCurrentState
				)
			} else {
				phase = .idle
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			}
		case .cleanExit:
			logConnectionEvent("SSH session exited cleanly")
			if ApplicationActivity.isActive {
				wantsConnection = false
				phase = .idle
				finishRestorationPresentation()
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			} else {
				wantsConnection = true
				phase = .idle
				#if canImport(UIKit)
					prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
				#else
					prepareForReconnectAfterBackgroundLoss()
				#endif
			}
		case let .error(message):
			logConnectionEvent("SSH session closed with error: \(message)")
			if shouldReconnectAfterClose(message: message, wasConnectedBeforeClose: wasConnectedBeforeClose) {
				phase = .idle
				if wasConnectedBeforeClose {
					#if canImport(UIKit)
						beginRestoration(.backgroundReconnect, snapshot: displaySnapshot ?? terminalView.captureSnapshot())
					#else
						beginRestoration(.backgroundReconnect)
					#endif
				} else {
					notifyOverlayStateChanged()
				}
				logConnectionEvent("Scheduling reconnect after SSH close")
				beginConnectionAttemptIfNeeded(
					after: ApplicationActivity.isActive ? activationReconnectDelayNanoseconds : 0,
					presentation: wasConnectedBeforeClose ? .restoringSnapshot : connectionPresentationForCurrentState
				)
			} else {
				phase = .failed(message)
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			}
		}
	}

	#if os(macOS)
		private func handleLocalShellClose(_ reason: LocalShellSession.CloseReason) {
			connectTask?.cancel()
			connectTask = nil
			if phase == .connecting || phase == .connected {
				phase = .idle
			}
			finishRestorationPresentation()

			switch reason {
			case .localDisconnect:
				phase = .idle
				notifyOverlayStateChanged()
			case .cleanExit:
				phase = .idle
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			case let .error(message):
				phase = .failed(message)
				notifyOverlayStateChanged()
			}
		}
	#endif
}

extension TerminalTab: TerminalViewDelegate {
	func terminalView(_: TerminalView, didWrite data: Data) {
		recordTerminalInput(data)
		switch endpoint {
		case .remote:
			if !sshSession.connection.send(data) {
				handleTerminalInputSendFailure()
			}
		case .localShell:
			#if os(macOS)
				localShellSession?.send(data)
			#endif
		}
	}

	func terminalViewDidResize(_: TerminalView) {
		guard let size = terminalView.currentTerminalSize() else { return }
		updateTerminalSize(size)
	}

	func terminalView(_: TerminalView, didReportTitle title: String) {
		reportedTitle = ShellTitleState.parse(title).title
	}

	func terminalViewRequestsCloseTab(_: TerminalView) {
		onRequestClose?()
	}

	func terminalViewRequestsNewTab(_: TerminalView) {
		onRequestNewTab?()
	}

	func terminalView(_: TerminalView, requestsSelectTab index: Int) {
		onRequestSelectTab?(index)
	}

	func terminalView(_: TerminalView, requestsMoveTabSelectionBy offset: Int) {
		onRequestMoveTabSelection?(offset)
	}

	func terminalViewRequestsShowSettings(_: TerminalView) {
		onRequestShowSettings?()
	}

	func terminalViewShouldDismissAuxiliaryUI(_: TerminalView) -> Bool {
		onRequestDismissAuxiliaryUI?() ?? false
	}
}
