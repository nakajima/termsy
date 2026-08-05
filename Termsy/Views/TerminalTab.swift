//
//  TerminalTab.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Foundation
import Observation
import SwiftUI

import UIKit

struct TerminalSnapshot {
	let image: UIImage
	let viewportSize: CGSize
}

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

		var diagnosticDescription: String {
			switch self {
			case .initial:
				"initial"
			case .restoringSnapshot:
				"restoringSnapshot"
			}
		}
	}

	let endpoint: TerminalEndpoint
	var session: Session?
	var sshSession = SSHTerminalSession()
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
	var onTerminalFontSizeChange: ((Float) -> Void)?
	var onOverlayStateChange: (() -> Void)?
	var onTerminalViewReplacementRequested: (() -> Void)?
	var reportedTitle = ""
	var connectionLog: [String] = []
	private(set) var isRecording = false
	private(set) var recordingDataByteCount: Int64 = 0
	@ObservationIgnored private var restorationSnapshot: TerminalSnapshot?
	var displaySnapshot: TerminalSnapshot? {
		restorationSnapshot
	}
	@ObservationIgnored var onFirstRemoteOutput: (() -> Void)?
	@ObservationIgnored private var pendingPreviewTranscript: String?
	@ObservationIgnored private var pendingPreviewReadinessLabel: String?
	@ObservationIgnored private var isPassivePreview = false
	@ObservationIgnored private(set) var isDisplayActive = false
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	@ObservationIgnored private var scheduledConnectionTask: Task<Void, Never>?
	@ObservationIgnored private var restorationRevealTask: Task<Void, Never>?
	@ObservationIgnored private var restorationFirstRemoteOutputAt: Date?
	@ObservationIgnored private let activationReconnectDelayNanoseconds: UInt64 = 750_000_000
	@ObservationIgnored private let reconnectRetryDelayNanoseconds: UInt64 = 2_000_000_000
	@ObservationIgnored private let restorationRevealQuietDelayNanoseconds: UInt64 = 250_000_000
	@ObservationIgnored private let restorationRevealMaximumDelayNanoseconds: UInt64 = 800_000_000
	@ObservationIgnored private var remoteConnectAttempt = 0
	@ObservationIgnored private var wantsConnection = true
	@ObservationIgnored private var lastRemoteOutputAt: Date?
	@ObservationIgnored private var lastTerminalInputAt: Date?
	@ObservationIgnored private var terminalRecorder: TerminalSessionRecorder?
	@ObservationIgnored private var suppressedCloseSessionIDs = Set<ObjectIdentifier>()
	@ObservationIgnored private var fileDropBatches: [TerminalFileDropBatch] = []
	@ObservationIgnored private var fileDropTask: Task<Void, Never>?
	var fileDropOverlayState = TerminalFileDropOverlayState.idle

	let id = UUID()

	init(session: Session) {
		self.endpoint = .remote
		self.session = session
		self.customTitle = Self.normalizedTabTitle(session.customTitle)
		self.terminalView = TerminalView(frame: .zero)
		if session.isOpen {
			self.restorationMode = .launch
			self.restorationSnapshot = Self.persistedRestorationSnapshot(for: session)
		} else {
			self.restorationMode = nil
			self.restorationSnapshot = nil
		}

		configureTerminalView()
		configureSSHSessionCallbacks()
	}


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
		if fileDropOverlayState.isPresented { return true }
		return switch overlayState {
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
			return false
		}
	}

	var connectionLogText: String {
		connectionLog.joined(separator: "\n")
	}

	var showsConnectionLogPanel: Bool {
		switch overlayState {
		case .connecting, .awaitingPassword, .restoring:
			true
		case .connected, .failed:
			false
		}
	}

	var shouldRequestBackgroundExecution: Bool {
		guard !isPassivePreview else { return false }
		guard case .remote = endpoint else { return false }
		return isConnected || phase == .connecting
	}

	private var shouldDeferRemoteConnectionUntilAppActive: Bool {
		guard case .remote = endpoint else { return false }
		return !ApplicationActivity.isActive
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
				suppressCloseCallbacks(for: sshSession)
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
		if phase == .connecting, connectTask == nil, !connectionIsActive {
			phase = .idle
			recordConnectionDiagnosticEvent(
				"connect.recoverStaleConnecting",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
			notifyOverlayStateChanged()
		}
		guard phase == .idle,
		      connectTask == nil,
		      !connectionIsActive
		else {
			recordConnectionDiagnosticEvent(
				"connect.skip.busy",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
			return
		}
		if delayNanoseconds > 0 {
			recordConnectionDiagnosticEvent(
				"connect.schedule",
				metadata: [
					"delaySeconds": String(format: "%.2f", Double(delayNanoseconds) / 1_000_000_000),
					"presentation": presentation.diagnosticDescription,
				]
			)
			scheduleConnectionAttempt(after: delayNanoseconds, presentation: presentation)
			return
		}
		guard terminalView.hasAttachedWindow else {
			recordConnectionDiagnosticEvent(
				"connect.skip.noWindow",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
			return
		}
		if shouldDeferRemoteConnectionUntilAppActive {
			recordConnectionDiagnosticEvent(
				"connect.deferred.appInactive",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
			logConnectionEvent("Deferring connection until app becomes active")
			return
		}

		applyConnectionPresentation(presentation)
		phase = .connecting
		recordConnectionDiagnosticEvent(
			"connect.task.start",
			metadata: ["presentation": presentation.diagnosticDescription]
		)
		notifyOverlayStateChanged()
		connectTask = Task { @MainActor [weak self] in
			defer {
				self?.connectTask = nil
				self?.notifyOverlayStateChanged()
			}
			guard let self else { return }
			if self.shouldDeferRemoteConnectionUntilAppActive {
				self.phase = .idle
				self.recordConnectionDiagnosticEvent(
					"connect.task.deferred.appInactive",
					metadata: ["presentation": presentation.diagnosticDescription]
				)
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
			self?.recordConnectionDiagnosticEvent(
				"connect.schedule.fire",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
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
			recordConnectionDiagnosticEvent(
				"connect.request.deferred.appInactive",
				metadata: ["presentation": presentation.diagnosticDescription]
			)
			logConnectionEvent("Connection request deferred because app is inactive")
			return
		}
		phase = .connecting
		connectionError = nil
		notifyOverlayStateChanged()
		recordConnectionDiagnosticEvent(
			"connect.request",
			metadata: ["presentation": presentation.diagnosticDescription]
		)
		logConnectionEvent("Connect requested")
		switch endpoint {
		case .remote:
			await connectRemote(presentation: presentation)
		case .localShell:
			break
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
		let tmuxSessionName = session.trimmedTmuxSessionName
		let initialWorkingDirectory = session.trimmedInitialWorkingDirectory
		let startupModeMessage = if let tmuxSessionName {
			"Attempt \(attempt): starting remote session directly in tmux \(tmuxSessionName)"
		} else {
			"Attempt \(attempt): starting remote login shell"
		}
		recordConnectionDiagnosticEvent(
			"connect.attempt.start",
			attempt: attempt,
			metadata: [
				"presentation": presentation.diagnosticDescription,
				"hasPassword": password?.isEmpty == false,
				"hasTmuxSession": tmuxSessionName != nil,
				"hasInitialWorkingDirectory": initialWorkingDirectory != nil,
			]
		)
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
				let isCurrentSession = self.sshSession === sshSession
				logConnectionEvent("Attempt \(attempt): ignoring stale successful connection")
				recordConnectionDiagnosticEvent(
					"connect.attempt.staleSuccess",
					attempt: attempt,
					metadata: [
						"taskCancelled": Task.isCancelled,
						"currentSession": isCurrentSession,
					]
				)
				if isCurrentSession {
					suppressCloseCallbacks(for: sshSession)
				}
				sshSession.disconnect()
				if isCurrentSession {
					phase = .idle
					connectTask = nil
					notifyOverlayStateChanged()
					if wantsConnection {
						beginConnectionAttemptIfNeeded(
							after: reconnectRetryDelayNanoseconds,
							presentation: presentation
						)
					} else {
						finishRestorationPresentation()
					}
				}
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
			recordConnectionDiagnosticEvent("connect.attempt.success", attempt: attempt)
			logConnectionEvent("Attempt \(attempt): connection established")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
		} catch SSHConnectionError.authenticationFailed {
			guard self.sshSession === sshSession else { return }
			finishRestorationPresentation()
			recordConnectionDiagnosticEvent("connect.attempt.authenticationFailed", attempt: attempt)
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
				recordConnectionDiagnosticEvent(
					"connect.attempt.failure.inactiveApp",
					attempt: attempt,
					metadata: Self.sanitizedDiagnosticMetadata(for: error)
				)
				logConnectionEvent("Attempt \(attempt): connection failed while app inactive; reconnect deferred: \(error)")
				notifyOverlayStateChanged()
				return
			}
			recordConnectionDiagnosticEvent(
				"connect.attempt.failure",
				attempt: attempt,
				metadata: Self.sanitizedDiagnosticMetadata(for: error)
			)
			logConnectionEvent("Attempt \(attempt): connection failed: \(error)")
			connectTask = nil
			notifyOverlayStateChanged()
			beginConnectionAttemptIfNeeded(after: reconnectRetryDelayNanoseconds, presentation: presentation)
		}
	}


	private func resetSSHSessionForNewConnection(attempt: Int) -> SSHTerminalSession {
		let newSession = replaceSSHSession(attempt: attempt)
		logConnectionEvent("Attempt \(attempt): created fresh SSH transport")
		return newSession
	}

	private func replaceSSHSession(attempt: Int? = nil) -> SSHTerminalSession {
		let previousSession = sshSession
		let terminalSize = previousSession.terminalSize
		let wasForeground = previousSession.isForeground
		previousSession.onRemoteOutput = nil
		previousSession.onClose = nil
		previousSession.onEvent = nil
		previousSession.onDiagnosticEvent = nil
		suppressedCloseSessionIDs.remove(ObjectIdentifier(previousSession))
		previousSession.disconnect()

		let newSession = SSHTerminalSession()
		sshSession = newSession
		configureSSHSessionCallbacks(for: newSession, attempt: attempt)
		newSession.updateTerminalSize(terminalSize)
		if !wasForeground {
			newSession.enterBackground()
		}
		return newSession
	}

	private func applyConnectionPresentation(_ presentation: ConnectionAttemptPresentation) {
		switch presentation {
		case .initial:
			return
		case .restoringSnapshot:
			guard case .remote = endpoint else { return }
			if case .backgroundReconnect = restorationMode, restorationSnapshot != nil {
				return
			}
			beginRestoration(.backgroundReconnect, snapshot: restorationSnapshot ?? captureRestorationSnapshot())
		}
	}

	private func captureRestorationSnapshot() -> TerminalSnapshot? {
		let viewportSize = terminalView.bounds.size
		guard viewportSize.width > 0, viewportSize.height > 0,
		      let image = terminalView.captureSnapshot()
		else {
			return nil
		}
		return TerminalSnapshot(image: image, viewportSize: viewportSize)
	}

	private static func persistedRestorationSnapshot(for session: Session) -> TerminalSnapshot? {
		guard let data = session.lastTerminalSnapshotJPEGData,
		      let width = session.lastTerminalSnapshotWidth,
		      let height = session.lastTerminalSnapshotHeight,
		      width > 0,
		      height > 0,
		      let image = UIImage(data: data)
		else {
			return nil
		}
		return TerminalSnapshot(
			image: image,
			viewportSize: CGSize(width: CGFloat(width), height: CGFloat(height))
		)
	}

	private func persistedRestorationSnapshot(from data: Data?) -> TerminalSnapshot? {
		guard var session, let data else { return nil }
		session.lastTerminalSnapshotJPEGData = data
		return Self.persistedRestorationSnapshot(for: session)
	}

	private func finishRestorationPresentation() {
		restorationRevealTask?.cancel()
		restorationRevealTask = nil
		restorationFirstRemoteOutputAt = nil
		restorationMode = nil
		restorationSnapshot = nil
		notifyOverlayStateChanged()
	}

	private func beginRestoration(_ mode: RestorationMode, snapshot: TerminalSnapshot?) {
		restorationRevealTask?.cancel()
		restorationRevealTask = nil
		restorationFirstRemoteOutputAt = nil
		restorationMode = mode
		restorationSnapshot = snapshot
		notifyOverlayStateChanged()
	}

	private func scheduleRestorationRevealAfterRemoteOutput() {
		guard restorationMode != nil else { return }
		let now = Date()
		if restorationFirstRemoteOutputAt == nil {
			restorationFirstRemoteOutputAt = now
		}
		restorationRevealTask?.cancel()
		let firstOutputAt = restorationFirstRemoteOutputAt ?? now
		let elapsedSeconds = max(0, now.timeIntervalSince(firstOutputAt))
		let elapsedNanoseconds = UInt64(elapsedSeconds * 1_000_000_000)
		let remainingMaximumDelay: UInt64
		if restorationRevealMaximumDelayNanoseconds > elapsedNanoseconds {
			remainingMaximumDelay = restorationRevealMaximumDelayNanoseconds - elapsedNanoseconds
		} else {
			remainingMaximumDelay = 0
		}
		let delay = min(restorationRevealQuietDelayNanoseconds, remainingMaximumDelay)
		restorationRevealTask = Task { @MainActor [weak self] in
			if delay > 0 {
				try? await Task.sleep(nanoseconds: delay)
			}
			guard !Task.isCancelled, let self else { return }
			self.terminalView.flushPendingDisplay()
			self.restorationRevealTask = nil
			self.finishRestorationPresentation()
		}
	}

	private func configureSSHSessionCallbacks(for sshSession: SSHTerminalSession? = nil, attempt: Int? = nil) {
		let sshSession = sshSession ?? self.sshSession
		sshSession.onRemoteOutput = { [weak self, weak sshSession] data in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			let wasRestoring = self.restorationMode != nil
			self.lastRemoteOutputAt = Date()
			if self.phase == .connecting {
				self.phase = .connected
				self.connectionError = nil
				self.notifyOverlayStateChanged()
			}
			self.recordTerminalOutput(data)
			self.terminalView.feedData(data)
			if wasRestoring {
				self.terminalView.flushPendingDisplay()
				self.scheduleRestorationRevealAfterRemoteOutput()
			}
			if let onFirstRemoteOutput = self.onFirstRemoteOutput {
				self.onFirstRemoteOutput = nil
				onFirstRemoteOutput()
			}
		}
		sshSession.onClose = { [weak self, weak sshSession] reason in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			self.handleSSHSessionClose(reason, from: sshSession)
		}
		sshSession.onEvent = { [weak self, weak sshSession] message in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			self.logConnectionEvent(message)
		}
		sshSession.onDiagnosticEvent = { [weak self, weak sshSession] event, metadata in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			self.recordSSHTransportDiagnosticEvent(event, attempt: attempt, metadata: metadata)
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
			break
		}
	}

	func close() {
		_ = stopRecording()
		cancelFileDropQueue()
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

	#if os(iOS)
		func releaseTerminalSurfaceForInactiveHost() {
			guard !isDisplayActive else { return }
			guard !isPassivePreview else { return }
			guard terminalView.surface != nil else { return }

			let displaySnapshot = captureRestorationSnapshot()
			let snapshotJPEGData = capturePersistedSnapshotJPEGData()
			let snapshot = displaySnapshot ?? persistedRestorationSnapshot(from: snapshotJPEGData) ?? restorationSnapshot
			let wasConnectionActive = connectionIsActive
			let wasConnecting = phase == .connecting
			let shouldReconnectOnSelection = wasConnectionActive || wasConnecting || phase == .connected || restorationMode != nil

			recordConnectionDiagnosticEvent(
				"surface.releaseInactive",
				metadata: [
					"hadSnapshot": snapshot != nil,
					"wasConnectionActive": wasConnectionActive,
					"wasConnecting": wasConnecting,
				]
			)
			logConnectionEvent("Released inactive terminal surface; reconnect will resume when selected")

			connectTask?.cancel()
			connectTask = nil
			scheduledConnectionTask?.cancel()
			scheduledConnectionTask = nil

			switch endpoint {
			case .remote:
				if wasConnectionActive || wasConnecting {
					_ = replaceSSHSession()
				}
			case .localShell:
				break
			}

			if phase == .connected || wasConnecting || wasConnectionActive {
				phase = .idle
			}
			if shouldReconnectOnSelection {
				beginRestoration(.backgroundReconnect, snapshot: snapshot ?? restorationSnapshot)
			}
			terminalView.stop()
		}
	#endif

	func capturePersistedSnapshotJPEGData() -> Data? {
		guard case .remote = endpoint else {
			return nil
		}
		guard terminalView.surface != nil, terminalView.hasAttachedWindow else {
			return session?.lastTerminalSnapshotJPEGData
		}
		let viewportSize = terminalView.bounds.size
		guard viewportSize.width > 0, viewportSize.height > 0,
		      let jpegData = terminalView.capturePersistedSnapshotJPEGData()
		else {
			return session?.lastTerminalSnapshotJPEGData
		}
		session?.lastTerminalSnapshotJPEGData = jpegData
		session?.lastTerminalSnapshotWidth = Double(viewportSize.width)
		session?.lastTerminalSnapshotHeight = Double(viewportSize.height)
		if restorationMode == .launch {
			restorationSnapshot = persistedRestorationSnapshot(from: jpegData)
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
		beginRestoration(.backgroundReconnect, snapshot: captureRestorationSnapshot())
		print("[Screenshots] ready \(readinessLabel)")
	}

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
		let previous = isDisplayActive
		isDisplayActive = isActive
		if previous != isActive {
			DiagnosticLogStore.shared.record(
				"terminalTab.setDisplayActive",
				metadata: diagnosticSnapshotMetadata(reason: "setDisplayActive", selected: nil)
			)
		}
		terminalView.setDisplayActive(isActive)
	}

	func recoverDisplayAfterAppActivation() {
		DiagnosticLogStore.shared.record(
			"terminalTab.recoverDisplayAfterAppActivation",
			metadata: diagnosticSnapshotMetadata(reason: "appActivationRecovery", selected: nil)
		)
		terminalView.recoverDisplayAfterAppActivation()
	}

	func diagnosticSnapshotMetadata(reason: String, index: Int? = nil, selected: Bool? = nil) -> [String: Any?] {
		var metadata: [String: Any?] = [
			"reason": reason,
			"tab": diagnosticID,
			"endpoint": endpointDiagnosticDescription,
			"phase": diagnosticPhaseDescription,
			"wantsConnection": wantsConnection,
			"connectionIsActive": connectionIsActive,
			"displayActive": isDisplayActive,
			"restoration": restorationDiagnosticDescription,
			"passivePreview": isPassivePreview,
			"recording": isRecording,
			"lastRemoteOutputAge": Self.ageDescription(since: lastRemoteOutputAt),
			"lastTerminalInputAge": Self.ageDescription(since: lastTerminalInputAt),
			"view": terminalView.diagnosticStateSummary(),
		]
		if let index {
			metadata["index"] = index
		}
		if let selected {
			metadata["selected"] = selected
		}
		return metadata
	}

	var diagnosticCompactSummary: String {
		"\(diagnosticID){phase=\(diagnosticPhaseDescription),displayActive=\(isDisplayActive),connectionActive=\(connectionIsActive),lastOutput=\(Self.ageDescription(since: lastRemoteOutputAt)),lastInput=\(Self.ageDescription(since: lastTerminalInputAt)),view=\(terminalView.diagnosticStateSummary())}"
	}

	private var diagnosticID: String {
		String(id.uuidString.prefix(8))
	}

	private var endpointDiagnosticDescription: String {
		switch endpoint {
		case .remote:
			return "remote"
		case .localShell:
			return "localShell"
		}
	}

	private var restorationDiagnosticDescription: String {
		guard let restorationMode else { return "none" }
		switch restorationMode {
		case .launch:
			return "launch"
		case .backgroundReconnect:
			return "backgroundReconnect"
		}
	}

	private var diagnosticPhaseDescription: String {
		switch phase {
		case .idle:
			return "idle"
		case .connecting:
			return "connecting"
		case .connected:
			return "connected"
		case .waitingForPassword:
			return "waitingForPassword"
		case .failed:
			return "failed"
		}
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
		DiagnosticLogStore.shared.record(
			"terminalTab.noteAppWillResignActive",
			metadata: diagnosticSnapshotMetadata(reason: "appWillResignActive", selected: nil)
		)
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = nil
		if case .remote = endpoint,
		   isConnected,
		   !isPassivePreview,
		   terminalView.hasAttachedWindow
		{
			restorationSnapshot = captureRestorationSnapshot()
		}
		if ApplicationActivity.hasBackgroundExecution, shouldRequestBackgroundExecution {
			logConnectionEvent("Requested iOS background execution to keep the SSH session alive")
		}
		logConnectionEvent("App will resign active; state=\(phaseDescription) wantsConnection=\(wantsConnection)")
	}

	func noteAppDidEnterBackground() {
		DiagnosticLogStore.shared.record(
			"terminalTab.noteAppDidEnterBackground",
			metadata: diagnosticSnapshotMetadata(reason: "appDidEnterBackground", selected: nil)
		)
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

	func noteAppDidBecomeActive(isSelected: Bool = true) {
		DiagnosticLogStore.shared.record(
			"terminalTab.noteAppDidBecomeActive",
			metadata: diagnosticSnapshotMetadata(reason: "appDidBecomeActive", selected: isSelected)
		)
		reconcileConnectionAfterAppActivation(
			isSelected: isSelected,
			reason: "appDidBecomeActive",
			selectedDelayNanoseconds: activationReconnectDelayNanoseconds
		)
	}

	func noteSelectedWhileAppActive() {
		DiagnosticLogStore.shared.record(
			"terminalTab.noteSelectedWhileAppActive",
			metadata: diagnosticSnapshotMetadata(reason: "selectedWhileAppActive", selected: true)
		)
		reconcileConnectionAfterAppActivation(
			isSelected: true,
			reason: "selectedWhileAppActive",
			selectedDelayNanoseconds: 0
		)
	}

	private func reconcileConnectionAfterAppActivation(
		isSelected: Bool,
		reason: String,
		selectedDelayNanoseconds: UInt64
	) {
		guard wantsConnection else { return }
		if phase == .connected, !connectionIsActive {
			if isSelected {
				logConnectionEvent("\(reason); connection was inactive; preparing background reconnect")
				recordConnectionDiagnosticEvent(
					"reconnect.backgroundLoss.start",
					metadata: ["reason": reason, "selected": true]
				)
				prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
			} else {
				logConnectionEvent("\(reason); background tab reconnect deferred until selected")
				phase = .idle
				beginRestoration(.backgroundReconnect, snapshot: restorationSnapshot)
				recordConnectionDiagnosticEvent(
					"reconnect.backgroundLoss.deferred",
					metadata: ["reason": reason, "selected": false]
				)
			}
			return
		}

		if isSelected, phase == .idle, restorationMode == .backgroundReconnect, !connectionIsActive {
			logConnectionEvent("\(reason); starting deferred background reconnect")
			recordConnectionDiagnosticEvent(
				"reconnect.deferredSelection.start",
				metadata: ["reason": reason]
			)
			prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
			return
		}

		if phase == .idle || phase == .connecting {
			logConnectionEvent("\(reason); reconciling connection selected=\(isSelected)")
			if phase == .connecting, connectTask == nil, !connectionIsActive {
				phase = .idle
			}
			guard isSelected else {
				recordConnectionDiagnosticEvent(
					"reconnect.deferredUntilSelected",
					metadata: ["reason": reason]
				)
				return
			}
			beginConnectionAttemptIfNeeded(
				after: selectedDelayNanoseconds,
				presentation: connectionPresentationForCurrentState
			)
		}
	}

	func prepareForReconnectAfterBackgroundLoss(snapshot: TerminalSnapshot? = nil) {
		guard case .remote = endpoint, !isPassivePreview else {
			retryConnection()
			return
		}
		beginRestoration(.backgroundReconnect, snapshot: snapshot ?? restorationSnapshot ?? captureRestorationSnapshot())
		resetTerminalView()
		retryConnection(preservingRestoration: true)
	}

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
			break
		}
	}

	private func logConnectionEvent(_ message: String) {
		let timestamp = Date().formatted(date: .omitted, time: .standard)
		connectionLog.append("[\(timestamp)] \(message)")
		if connectionLog.count > 120 {
			connectionLog.removeFirst(connectionLog.count - 120)
		}
	}

	private func suppressCloseCallbacks(for sshSession: SSHTerminalSession) {
		suppressedCloseSessionIDs.insert(ObjectIdentifier(sshSession))
	}

	private func shouldIgnoreClose(from sshSession: SSHTerminalSession) -> Bool {
		let id = ObjectIdentifier(sshSession)
		guard suppressedCloseSessionIDs.contains(id) else { return false }
		suppressedCloseSessionIDs.remove(id)
		return true
	}

	private var shouldStartReconnectImmediately: Bool {
		ApplicationActivity.isActive && isDisplayActive && !isPassivePreview
	}

	private func recordConnectionDiagnosticEvent(
		_ event: String,
		attempt: Int? = nil,
		metadata: [String: Any?] = [:]
	) {
		var payload: [String: Any?] = [
			"tab": diagnosticID,
			"endpoint": endpointDiagnosticDescription,
			"phase": diagnosticPhaseDescription,
			"wantsConnection": wantsConnection,
			"connectionIsActive": connectionIsActive,
			"displayActive": isDisplayActive,
			"restoration": restorationDiagnosticDescription,
			"appActive": ApplicationActivity.isActive,
			"foregroundActive": ApplicationActivity.isForegroundActive,
		]
		if let attempt {
			payload["attempt"] = attempt
		}
		for (key, value) in metadata {
			payload[key] = value
		}
		DiagnosticLogStore.shared.record("terminalTab.ssh.\(event)", metadata: payload)
	}

	private func recordSSHTransportDiagnosticEvent(
		_ event: String,
		attempt: Int?,
		metadata: [String: String]
	) {
		var payload: [String: Any?] = [:]
		for (key, value) in metadata {
			payload[key] = value
		}
		recordConnectionDiagnosticEvent(event, attempt: attempt, metadata: payload)
	}

	private static func sanitizedDiagnosticMetadata(for error: Error) -> [String: Any?] {
		var metadata: [String: Any?] = [
			"errorType": String(reflecting: type(of: error)),
		]
		if let sshError = error as? SSHConnectionError {
			metadata["errorDescription"] = sshError.description
		}
		let nsError = error as NSError
		metadata["errorDomain"] = nsError.domain
		metadata["errorCode"] = nsError.code
		return metadata
	}

	private static func ageDescription(since date: Date?) -> String {
		guard let date else { return "never" }
		return String(format: "%.2fs", Date().timeIntervalSince(date))
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
		DiagnosticLogStore.shared.record(
			"terminalTab.inputSendFailure",
			metadata: diagnosticSnapshotMetadata(reason: "inputSendFailure", selected: nil)
		)
		guard case .remote = endpoint, wantsConnection else { return }
		guard phase != .connecting else { return }
		logConnectionEvent("Terminal input could not be sent because the SSH session channel is inactive")
		connectionError = nil
		prepareForReconnectAfterBackgroundLoss(snapshot: displaySnapshot ?? captureRestorationSnapshot())
	}

	func handleDroppedFileURLs(_ urls: [URL]) {
		guard !urls.isEmpty else { return }
		terminalView.restoreKeyboardFocusIfNeeded(retryCount: 10)
		switch endpoint {
		case .remote:
			enqueueRemoteFileDrop(urls: urls)
		case .localShell:
			insertLocalShellDroppedPaths(urls)
		}
	}

	func handleFileDropFailure(message: String) {
		setFileDropOverlayState(.error(message))
	}

	func dismissFileDropError() {
		guard fileDropOverlayState.errorMessage != nil else { return }
		setFileDropOverlayState(.idle)
	}

	private func insertLocalShellDroppedPaths(_ urls: [URL]) {
		do {
			let text = try TerminalFileDropSupport.localShellInsertText(for: urls)
			terminalView.insertDirectTerminalText(text)
		} catch {
			setFileDropOverlayState(.error(error.localizedDescription))
		}
	}

	private func enqueueRemoteFileDrop(urls: [URL]) {
		guard fileDropOverlayState.errorMessage == nil else { return }
		fileDropBatches.append(TerminalFileDropBatch(urls: urls))
		refreshQueuedFileDropCount()
		startRemoteFileDropQueueIfNeeded()
	}

	private func startRemoteFileDropQueueIfNeeded() {
		guard fileDropTask == nil else { return }
		fileDropTask = Task { @MainActor [weak self] in
			await self?.processRemoteFileDropQueue()
		}
	}

	private func processRemoteFileDropQueue() async {
		defer { fileDropTask = nil }
		while !fileDropBatches.isEmpty {
			let batch = fileDropBatches.removeFirst()
			do {
				try await uploadRemoteFileDropBatch(batch)
			} catch {
				fileDropBatches.removeAll()
				setFileDropOverlayState(.error(error.localizedDescription))
				return
			}
		}
		setFileDropOverlayState(.idle)
	}

	private func uploadRemoteFileDropBatch(_ batch: TerminalFileDropBatch) async throws {
		guard sshSession.connection.isActive else { throw TerminalFileDropError.notConnected }
		let prepared = try TerminalFileDropSupport.prepareSSHUploadBatch(urls: batch.urls)
		defer { prepared.stopAccessingSecurityScopedResources() }

		let totalBytes = prepared.files.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
		updateFileDropProgress(
			fileCount: prepared.files.count,
			totalBytes: totalBytes,
			completedBytes: 0,
			currentFileName: prepared.files.first?.displayName
		)

		let remoteDirectory = try await sshSession.prepareFileDropDirectory(dropID: batch.id)
		var remotePaths: [String] = []
		var completedBytes: Int64 = 0

		for file in prepared.files {
			try Task.checkCancellation()
			let completedBeforeFile = completedBytes
			updateFileDropProgress(
				fileCount: prepared.files.count,
				totalBytes: totalBytes,
				completedBytes: completedBeforeFile,
				currentFileName: file.displayName
			)
			let remotePath = try await sshSession.uploadFileForDrop(
				localURL: file.sourceURL,
				remoteDirectory: remoteDirectory,
				remoteFileName: file.remoteFileName,
				posixPermissions: file.posixPermissions,
				onProgress: { [weak self] uploadedBytes in
					Task { @MainActor [weak self] in
						self?.updateFileDropProgress(
							fileCount: prepared.files.count,
							totalBytes: totalBytes,
							completedBytes: completedBeforeFile + min(uploadedBytes, max(file.byteCount, 0)),
							currentFileName: file.displayName
						)
					}
				}
			)
			completedBytes += max(file.byteCount, 0)
			remotePaths.append(remotePath)
			updateFileDropProgress(
				fileCount: prepared.files.count,
				totalBytes: totalBytes,
				completedBytes: completedBytes,
				currentFileName: file.displayName
			)
		}

		terminalView.insertDirectTerminalText(TerminalFileDropSupport.shellQuotedArgumentList(remotePaths))
	}

	private func updateFileDropProgress(
		fileCount: Int,
		totalBytes: Int64,
		completedBytes: Int64,
		currentFileName: String?
	) {
		setFileDropOverlayState(.uploading(
			activeFileCount: fileCount,
			queuedBatchCount: fileDropBatches.count,
			completedBytes: completedBytes,
			totalBytes: totalBytes,
			currentFileName: currentFileName
		))
	}

	private func refreshQueuedFileDropCount() {
		guard fileDropOverlayState.isUploading else { return }
		setFileDropOverlayState(.uploading(
			activeFileCount: fileDropOverlayState.activeFileCount,
			queuedBatchCount: fileDropBatches.count,
			completedBytes: fileDropOverlayState.completedBytes,
			totalBytes: fileDropOverlayState.totalBytes,
			currentFileName: fileDropOverlayState.currentFileName
		))
	}

	private func setFileDropOverlayState(_ state: TerminalFileDropOverlayState) {
		let wasPresented = fileDropOverlayState.isPresented
		fileDropOverlayState = state
		terminalView.setTerminalInputBlocked(state.blocksInput)
		if wasPresented != state.isPresented || state.errorMessage != nil || state.isUploading {
			notifyOverlayStateChanged()
		}
	}

	private func cancelFileDropQueue() {
		fileDropTask?.cancel()
		fileDropTask = nil
		fileDropBatches.removeAll()
		setFileDropOverlayState(.idle)
	}

	private func configureTerminalView() {
		terminalView.delegate = self
		terminalView.setFontSize(session?.resolvedTerminalFontSize ?? TerminalFontSettings.size)
		terminalView.setTerminalInputBlocked(fileDropOverlayState.blocksInput)
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
		prepareForReconnectAfterBackgroundLoss(snapshot: displaySnapshot)
	}

	private func handleSSHSessionClose(_ reason: SSHTerminalSession.CloseReason, from sshSession: SSHTerminalSession) {
		let closeReason = Self.diagnosticDescription(for: reason)
		if shouldIgnoreClose(from: sshSession) {
			recordConnectionDiagnosticEvent(
				"connection.close.ignored",
				metadata: ["closeReason": closeReason]
			)
			logConnectionEvent("Ignoring SSH close from a transport replaced during reconnect")
			return
		}

		let wasConnectedBeforeClose = isConnected
		recordConnectionDiagnosticEvent(
			"connection.close",
			metadata: [
				"closeReason": closeReason,
				"wasConnectedBeforeClose": wasConnectedBeforeClose,
				"reconnectImmediately": shouldStartReconnectImmediately,
			]
		)
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
				if shouldStartReconnectImmediately {
					beginConnectionAttemptIfNeeded(
						after: activationReconnectDelayNanoseconds,
						presentation: connectionPresentationForCurrentState
					)
				} else {
					recordConnectionDiagnosticEvent(
						"reconnect.deferredUntilSelected",
						metadata: ["reason": "localDisconnect"]
					)
				}
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
				prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
			}
		case let .error(message):
			logConnectionEvent("SSH session closed with error: \(message)")
			if shouldReconnectAfterClose(message: message, wasConnectedBeforeClose: wasConnectedBeforeClose) {
				phase = .idle
				if wasConnectedBeforeClose || restorationMode != nil {
					beginRestoration(
						.backgroundReconnect,
						snapshot: displaySnapshot ?? restorationSnapshot ?? captureRestorationSnapshot()
					)
				} else {
					notifyOverlayStateChanged()
				}
				if shouldStartReconnectImmediately {
					logConnectionEvent("Scheduling reconnect after SSH close")
					beginConnectionAttemptIfNeeded(
						after: activationReconnectDelayNanoseconds,
						presentation: wasConnectedBeforeClose ? .restoringSnapshot : connectionPresentationForCurrentState
					)
				} else {
					logConnectionEvent("Deferring reconnect after SSH close until the tab is selected")
					recordConnectionDiagnosticEvent(
						"reconnect.deferredUntilSelected",
						metadata: ["reason": "sshClose"]
					)
				}
			} else {
				phase = .failed(message)
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			}
		}
	}

	private static func diagnosticDescription(for reason: SSHTerminalSession.CloseReason) -> String {
		switch reason {
		case .localDisconnect:
			"localDisconnect"
		case .cleanExit:
			"cleanExit"
		case .error:
			"error"
		}
	}

}

extension TerminalTab: TerminalViewDelegate {
	func terminalView(_: TerminalView, didWrite data: Data) {
		lastTerminalInputAt = Date()
		recordTerminalInput(data)
		switch endpoint {
		case .remote:
			if !sshSession.connection.send(data) {
				handleTerminalInputSendFailure()
			}
		case .localShell:
			break
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

	func terminalView(_: TerminalView, didChangeFontSize fontSize: Float) {
		onTerminalFontSizeChange?(fontSize)
	}

	func terminalView(_: TerminalView, didReceiveFileDropURLs urls: [URL]) {
		handleDroppedFileURLs(urls)
	}

	func terminalView(_: TerminalView, didFailFileDropWithMessage message: String) {
		handleFileDropFailure(message: message)
	}
}
