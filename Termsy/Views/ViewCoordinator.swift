//
//  ViewCoordinator.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import GRDB
import GRDBQuery
import Observation
import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif

@Observable @MainActor
class ViewCoordinator {
	private enum WorkspacePersistence {
		static let selectedSessionIDKey = "workspace.selectedSessionID"
	}

	var path = NavigationPath()
	var isShowingConnectView = false {
		didSet { refreshDisplayActivity() }
	}

	var isShowingSessionPicker = false {
		didSet { refreshDisplayActivity() }
	}

	var isShowingSettings = false {
		didSet { refreshDisplayActivity() }
	}

	var isPresentingAuxiliaryUI: Bool {
		isShowingConnectView || isShowingSessionPicker || isShowingSettings
	}

	private struct PersistedTerminalSnapshot {
		let sessionID: Int64
		let jpegData: Data
	}

	private var appIsActive = true
	private var databaseContext: DatabaseContext?
	private var isRestoringSavedWorkspace = false

	/// All open terminal tabs.
	var tabs: [TerminalTab] = []

	/// The currently selected tab, or nil if showing the session list.
	var selectedTabID: UUID?

	var selectedTab: TerminalTab? {
		tabs.first { $0.id == selectedTabID }
	}

	func configureDatabaseContext(_ databaseContext: DatabaseContext) {
		self.databaseContext = databaseContext
	}

	func restoreSavedWorkspace() {
		guard tabs.isEmpty else { return }
		guard let databaseContext else { return }

		let sessions: [Session]
		do {
			sessions = try databaseContext.reader.read { db in
				try Session.filter { $0.isOpen == true }.fetchAll(db)
			}
		} catch {
			print("[DB] failed to read saved workspace state: \(error)")
			return
		}

		isRestoringSavedWorkspace = true
		defer {
			isRestoringSavedWorkspace = false
			persistWorkspaceStateIfPossible()
		}

		for session in orderedWorkspaceSessions(sessions) {
			open(tab: TerminalTab(session: session), persistWorkspace: false)
		}

		guard let selectedSessionID = persistedSelectedSessionID else { return }
		guard let selectedTab = tabs.first(where: { $0.session?.id == selectedSessionID }) else {
			persistedSelectedSessionID = nil
			return
		}
		selectTab(selectedTab.id, persistWorkspace: false)
	}

	func openTab(for session: Session) {
		open(tab: TerminalTab(session: session))
	}

	func openPassivePreviewTab(
		for session: Session,
		transcript: String,
		screenshotReadyLabel: String? = nil
	) {
		let tab = TerminalTab(session: session)
		tab.preparePassivePreview(transcript: transcript, screenshotReadyLabel: screenshotReadyLabel)
		open(tab: tab)
	}

	#if os(macOS)
		func openLocalShellTab(profile: LocalShellProfile = .default) {
			open(tab: TerminalTab(localShellProfile: profile))
		}
	#endif

	private func open(tab: TerminalTab, persistWorkspace: Bool = true) {
		let tabID = tab.id
		tab.onRequestClose = { [weak self] in
			self?.closeTab(tabID)
		}
		tab.onRequestNewTab = { [weak self] in
			self?.openNewTabUI()
		}
		tab.onRequestSelectTab = { [weak self] index in
			self?.selectTabNumber(index)
		}
		tab.onRequestMoveTabSelection = { [weak self] offset in
			self?.moveTabSelection(by: offset)
		}
		tab.onRequestShowSettings = { [weak self] in
			self?.openSettings()
		}
		tab.onRequestDismissAuxiliaryUI = { [weak self] in
			self?.dismissPresentedUI() ?? false
		}
		tabs.append(tab)
		selectTab(tab.id, persistWorkspace: false)
		if persistWorkspace {
			persistWorkspaceStateIfPossible()
		}
	}

	func openSettings() {
		isShowingConnectView = false
		isShowingSessionPicker = false
		isShowingSettings = true
	}

	func openNewTabUI() {
		isShowingSettings = false
		if tabs.isEmpty {
			isShowingConnectView = true
			isShowingSessionPicker = false
		} else {
			isShowingConnectView = false
			isShowingSessionPicker = true
		}
	}

	@discardableResult
	func dismissPresentedUI() -> Bool {
		if isShowingSettings {
			isShowingSettings = false
			return true
		}
		if isShowingConnectView {
			isShowingConnectView = false
			return true
		}
		if isShowingSessionPicker {
			isShowingSessionPicker = false
			return true
		}
		return false
	}

	func appWillResignActive() {
		appIsActive = false
		ApplicationActivity.isActive = false
		for tab in tabs {
			tab.noteAppWillResignActive()
		}
		refreshDisplayActivity()
	}

	func appDidEnterBackground() {
		appIsActive = false
		ApplicationActivity.isActive = false
		for tab in tabs {
			tab.noteAppDidEnterBackground()
		}
		#if canImport(UIKit)
			persistWorkspaceStateIfPossible(snapshotRecords: capturePersistedTerminalSnapshots())
		#else
			persistWorkspaceStateIfPossible()
		#endif
		let backgroundExecutionTabs = tabs.filter(\.shouldRequestBackgroundExecution)
		if !backgroundExecutionTabs.isEmpty {
			let alreadyActive = ApplicationActivity.hasBackgroundExecution
			ApplicationActivity.onBackgroundExecutionExpiration = { [weak self] remaining in
				self?.noteBackgroundExecutionExpired(remaining: remaining)
			}
			let granted = ApplicationActivity.beginBackgroundExecution(name: "Teletype SSH")
			let remaining = ApplicationActivity.backgroundTimeRemaining
			for tab in backgroundExecutionTabs {
				tab.noteBackgroundExecutionRequested(
					granted: granted,
					alreadyActive: alreadyActive,
					remaining: remaining
				)
			}
		}
		refreshDisplayActivity()
	}

	func appDidBecomeActive() {
		appIsActive = true
		ApplicationActivity.isActive = true
		let hadBackgroundExecution = ApplicationActivity.hasBackgroundExecution
		let remaining = ApplicationActivity.backgroundTimeRemaining
		ApplicationActivity.endBackgroundExecution()
		ApplicationActivity.onBackgroundExecutionExpiration = nil
		if hadBackgroundExecution {
			for tab in tabs {
				tab.noteBackgroundExecutionEnded(remainingBeforeEnd: remaining)
			}
		}
		for tab in tabs {
			tab.noteAppDidBecomeActive()
		}
		refreshDisplayActivity()
		#if canImport(UIKit)
			selectedTab?.restoreKeyboardFocusAfterAppActivation()
		#endif
	}

	private func noteBackgroundExecutionExpired(remaining: TimeInterval?) {
		for tab in tabs {
			tab.noteBackgroundExecutionExpired(remaining: remaining)
		}
	}

	func selectTab(_ id: UUID?, persistWorkspace: Bool = true) {
		let previousID = selectedTabID
		selectedTabID = id

		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.id == previousID })
		{
			prevTab.enterBackground()
		}

		if let id, let tab = tabs.first(where: { $0.id == id }) {
			tab.enterForeground()
		}

		refreshDisplayActivity()
		if persistWorkspace {
			persistWorkspaceStateIfPossible()
		}
	}

	func selectTabNumber(_ number: Int) {
		guard number >= 1, number <= tabs.count else { return }
		selectTab(tabs[number - 1].id)
	}

	func moveTabSelection(by offset: Int) {
		guard !tabs.isEmpty, offset != 0 else { return }
		guard let selectedTabID,
		      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
		else {
			let fallbackIndex = offset > 0 ? 0 : tabs.count - 1
			selectTab(tabs[fallbackIndex].id)
			return
		}

		let wrappedOffset = offset % tabs.count
		let nextIndex = (selectedIndex + wrappedOffset + tabs.count) % tabs.count
		selectTab(tabs[nextIndex].id)
	}

	func closeTab(_ id: UUID?) {
		guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
		let tab = tabs[index]
		stopRecording(tabID: id)
		tab.close()
		tabs.remove(at: index)

		if selectedTabID == id {
			if tabs.isEmpty {
				selectedTabID = nil
				refreshDisplayActivity()
			} else {
				let newIndex = min(index, tabs.count - 1)
				selectTab(tabs[newIndex].id, persistWorkspace: false)
			}
		}
		persistWorkspaceStateIfPossible()
	}

	func closeOtherTabs(_ id: UUID?) {
		let toClose = tabs.filter { $0.id != id }
		for tab in toClose {
			stopRecording(tabID: tab.id)
			tab.close()
		}
		tabs.removeAll { $0.id != id }
		if let id {
			selectTab(id, persistWorkspace: false)
		} else {
			selectedTabID = nil
			refreshDisplayActivity()
		}
		persistWorkspaceStateIfPossible()
	}

	func renameTab(_ id: UUID?, to title: String?) {
		guard let id, let tab = tabs.first(where: { $0.id == id }) else { return }
		tab.rename(to: title)
	}

	@discardableResult
	func startRecording(tabID: UUID) -> URL? {
		guard let databaseContext else { return nil }
		guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
		guard !tab.isRecording else { return tab.recordingFileURL }

		var recording = tab.makeRecordingMetadata(startedAt: Date())
		do {
			try databaseContext.writer.write { db in
				try recording.save(db)
			}
			let recorder = try TerminalSessionRecorder(recording: recording)
			tab.startRecording(recorder)
			return recorder.fileURL
		} catch {
			if let id = recording.id {
				try? databaseContext.writer.write { db in
					_ = try TerminalRecording.deleteOne(db, key: id)
				}
			}
			print("[Recording] failed to start: \(error)")
			return nil
		}
	}

	@discardableResult
	func stopRecording(tabID: UUID) -> URL? {
		guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
		guard let completed = tab.stopRecording() else { return nil }
		persistCompletedRecording(completed)
		return completed.fileURL
	}

	private func persistCompletedRecording(_ completed: TerminalSessionRecorder.Completed) {
		guard let databaseContext else { return }
		do {
			try databaseContext.writer.write { db in
				let recording = completed.recording
				try recording.update(db)
			}
		} catch {
			print("[Recording] failed to persist completed recording: \(error)")
		}
	}

	func moveTab(from source: IndexSet, to destination: Int) {
		tabs.move(fromOffsets: source, toOffset: destination)
		persistWorkspaceStateIfPossible()
	}

	func reorderTabs(_ orderedIDs: [UUID]) {
		var reordered: [TerminalTab] = []
		for id in orderedIDs {
			if let tab = tabs.first(where: { $0.id == id }) {
				reordered.append(tab)
			}
		}
		tabs = reordered
		persistWorkspaceStateIfPossible()
	}

	private func orderedWorkspaceSessions(_ sessions: [Session]) -> [Session] {
		sessions.sorted { lhs, rhs in
			let lhsOrder = lhs.tabOrder ?? Int.max
			let rhsOrder = rhs.tabOrder ?? Int.max
			if lhsOrder != rhsOrder {
				return lhsOrder < rhsOrder
			}
			if lhs.createdAt != rhs.createdAt {
				return lhs.createdAt < rhs.createdAt
			}
			return lhs.normalizedTargetKey < rhs.normalizedTargetKey
		}
	}

	private var persistedSelectedSessionID: Int64? {
		get {
			(UserDefaults.standard.object(forKey: WorkspacePersistence.selectedSessionIDKey) as? NSNumber)?.int64Value
		}
		set {
			if let newValue {
				UserDefaults.standard.set(NSNumber(value: newValue), forKey: WorkspacePersistence.selectedSessionIDKey)
			} else {
				UserDefaults.standard.removeObject(forKey: WorkspacePersistence.selectedSessionIDKey)
			}
		}
	}

	private func persistWorkspaceStateIfPossible(snapshotRecords: [PersistedTerminalSnapshot] = []) {
		guard !isRestoringSavedWorkspace else { return }
		guard let databaseContext else { return }

		let openSessions = tabs.enumerated().compactMap { index, tab -> (sessionID: Int64, tabOrder: Int)? in
			guard let sessionID = tab.session?.id else { return nil }
			return (sessionID: sessionID, tabOrder: index)
		}

		do {
			try databaseContext.writer.write { db in
				try db.execute(sql: "UPDATE session SET isOpen = 0, tabOrder = NULL")
				for openSession in openSessions {
					try db.execute(
						sql: "UPDATE session SET isOpen = 1, tabOrder = ? WHERE id = ?",
						arguments: [openSession.tabOrder, openSession.sessionID]
					)
				}
				for snapshotRecord in snapshotRecords {
					try db.execute(
						sql: "UPDATE session SET lastTerminalSnapshotJPEGData = ? WHERE id = ?",
						arguments: [snapshotRecord.jpegData, snapshotRecord.sessionID]
					)
				}
			}
			persistedSelectedSessionID = selectedTab?.session?.id
		} catch {
			print("[DB] failed to persist workspace state: \(error)")
		}
	}

	#if canImport(UIKit)
		private func capturePersistedTerminalSnapshots() -> [PersistedTerminalSnapshot] {
			tabs.compactMap { tab in
				guard let sessionID = tab.session?.id,
				      let jpegData = tab.capturePersistedSnapshotJPEGData()
				else {
					return nil
				}
				return PersistedTerminalSnapshot(sessionID: sessionID, jpegData: jpegData)
			}
		}
	#endif

	private func refreshDisplayActivity() {
		let activeTabID = appIsActive && !isPresentingAuxiliaryUI ? selectedTabID : nil
		for tab in tabs {
			tab.setDisplayActive(tab.id == activeTabID)
		}
	}
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

	private enum ConnectionState {
		case idle
		case connecting
		case connected
		case waitingForPassword
		case closedByUser
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
	private var connectionState: ConnectionState = .idle
	var connectionError: String?
	var isConnected: Bool {
		get { connectionState == .connected }
		set { connectionState = newValue ? .connected : .idle }
	}

	var needsPassword: Bool {
		get { connectionState == .waitingForPassword }
		set {
			if newValue {
				connectionState = .waitingForPassword
			} else if connectionState == .waitingForPassword {
				connectionState = .idle
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
	@ObservationIgnored private var restorationPresentationMode: RestorationMode?

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
				self.restorationPresentationMode = .launch
				if let snapshotData = session.lastTerminalSnapshotJPEGData {
					self.restorationSnapshot = UIImage(data: snapshotData)
				} else {
					self.restorationSnapshot = nil
				}
			} else {
				self.restorationMode = nil
				self.restorationPresentationMode = nil
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
			guard let session else { return "Connecting…" }
			return "Connecting to \(session.hostname)…"
		case .localShell:
			return "Starting local shell…"
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
		if let restorationPresentationMode {
			return .restoring(restorationPresentationMode)
		}
		if needsPassword {
			return .awaitingPassword
		}
		if let connectionError {
			return .failed(connectionError)
		}

		switch connectionState {
		case .connecting:
			return .connecting
		case .idle, .connected, .closedByUser:
			return .connected
		case .waitingForPassword:
			return .awaitingPassword
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

	var isRestoring: Bool { restorationPresentationMode != nil }

	var showsConnectingOverlay: Bool {
		if case .connecting = overlayState { return true }
		return false
	}

	var showsRestoringProgress: Bool {
		restorationPresentationMode?.showsProgress ?? false
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
		return isConnected || connectionState == .connecting
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
		if case .backgroundReconnect = restorationPresentationMode {
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
			clearRestorationState()
		}
		wantsConnection = true
		connectionError = nil
		if connectionState == .connected || connectionState == .connecting {
			switch endpoint {
			case .remote:
				sshSession.disconnect()
			case .localShell:
				break
			}
		}
		connectionState = .idle
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
		guard connectionState == .idle,
		      connectTask == nil,
		      !connectionIsActive
		else {
			return
		}

		applyConnectionPresentation(presentation)
		connectionState = .connecting
		notifyOverlayStateChanged()
		connectTask = Task { @MainActor [weak self] in
			defer {
				self?.connectTask = nil
				self?.notifyOverlayStateChanged()
			}
			guard let self else { return }
			if self.shouldDeferRemoteConnectionUntilAppActive {
				self.connectionState = .idle
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
			connectionState = .idle
			logConnectionEvent("Connection request deferred because app is inactive")
			return
		}
		connectionState = .connecting
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
		remoteConnectAttempt += 1
		let attempt = remoteConnectAttempt
		logConnectionEvent("Attempt \(attempt): checking saved credentials")
		let keychainPassword = Keychain.password(for: session)
		logConnectionEvent(
			keychainPassword == nil
				? "Attempt \(attempt): no saved password available"
				: "Attempt \(attempt): using saved password from keychain"
		)
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
				password: keychainPassword,
				tmuxSessionName: tmuxSessionName,
				initialWorkingDirectory: initialWorkingDirectory
			)
			guard !Task.isCancelled, self.sshSession === sshSession else {
				logConnectionEvent("Attempt \(attempt): ignoring stale successful connection")
				sshSession.disconnect()
				return
			}
			wantsConnection = true
			connectionState = .connected
			connectionError = nil
			self.session?.lastConnectedAt = Date()
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
			connectionState = .waitingForPassword
			notifyOverlayStateChanged()
		} catch {
			guard self.sshSession === sshSession else { return }
			connectionState = .idle
			switch presentation {
			case .initial:
				finishRestorationPresentation()
				connectionError = "\(error)"
			case .restoringSnapshot:
				connectionError = nil
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
				connectionState = .connected
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			} catch {
				finishRestorationPresentation()
				print("[LocalShell] failed to start: \(error)")
				connectionState = .idle
				connectionError = error.localizedDescription
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
				if case .backgroundReconnect = restorationPresentationMode, restorationSnapshot != nil {
					return
				}
				beginRestoration(.backgroundReconnect, snapshot: restorationSnapshot ?? terminalView.captureSnapshot())
			#else
				if case .backgroundReconnect = restorationPresentationMode {
					return
				}
				beginRestoration(.backgroundReconnect)
			#endif
		}
	}

	private func clearRestorationState() {
		restorationMode = nil
		restorationPresentationMode = nil
		#if canImport(UIKit)
			restorationSnapshot = nil
		#endif
		notifyOverlayStateChanged()
	}

	private func finishRestorationPresentation() {
		restorationMode = nil
		restorationPresentationMode = nil
		#if canImport(UIKit)
			restorationSnapshot = nil
		#endif
		notifyOverlayStateChanged()
	}

	#if canImport(UIKit)
		private func beginRestoration(_ mode: RestorationMode, snapshot: UIImage?) {
			restorationMode = mode
			restorationPresentationMode = mode
			restorationSnapshot = snapshot
			notifyOverlayStateChanged()
		}
	#else
		private func beginRestoration(_ mode: RestorationMode) {
			restorationMode = mode
			restorationPresentationMode = mode
			notifyOverlayStateChanged()
		}
	#endif

	private func configureSSHSessionCallbacks(for sshSession: SSHTerminalSession? = nil) {
		let sshSession = sshSession ?? self.sshSession
		sshSession.onRemoteOutput = { [weak self, weak sshSession] data in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
			if self.restorationMode != nil || self.restorationPresentationMode != nil {
				self.finishRestorationPresentation()
			}
			if self.connectionState == .connecting {
				self.connectionState = .connected
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
		guard case .remote = endpoint, let session else { return }
		wantsConnection = true
		connectionState = .connecting
		connectionError = nil
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
		logConnectionEvent("Attempt \(attempt): retrying with password for \(session.username)@\(session.hostname):\(session.port)")
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
				logConnectionEvent("Attempt \(attempt): ignoring stale successful password retry")
				sshSession.disconnect()
				return
			}
			connectionState = .connected
			connectionError = nil
			self.session?.lastConnectedAt = Date()
			Keychain.setPassword(password, for: session)
			notifyOverlayStateChanged()
			logConnectionEvent("Attempt \(attempt): connection established with password")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
		} catch SSHConnectionError.authenticationFailed {
			guard self.sshSession === sshSession else { return }
			finishRestorationPresentation()
			logConnectionEvent("Attempt \(attempt): password retry authentication failed")
			wantsConnection = false
			connectionState = .waitingForPassword
			notifyOverlayStateChanged()
		} catch {
			guard self.sshSession === sshSession else { return }
			finishRestorationPresentation()
			logConnectionEvent("Attempt \(attempt): password retry failed: \(error)")
			connectionState = .idle
			connectionError = "\(error)"
			notifyOverlayStateChanged()
			beginConnectionAttemptIfNeeded(after: reconnectRetryDelayNanoseconds, presentation: .initial)
		}
	}

	func disconnect() {
		wantsConnection = false
		connectTask?.cancel()
		connectTask = nil
		scheduledConnectionTask?.cancel()
		scheduledConnectionTask = nil
		if isPassivePreview {
			connectionState = .closedByUser
			pendingPreviewTranscript = nil
			notifyOverlayStateChanged()
			return
		}
		connectionState = .closedByUser
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
		connectionState = .connected
		connectionError = nil
		finishRestorationPresentation()
		terminalView.setPresentationMode(.passivePreview)
		clearAppInactiveState()
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

	#if canImport(UIKit)
		func restoreKeyboardFocusAfterAppActivation() {
			guard isDisplayActive else { return }
			terminalView.restoreKeyboardFocusAfterAppActivation()
		}
	#endif

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
		logConnectionEvent("App will resign active; state=\(connectionStateDescription) wantsConnection=\(wantsConnection)")
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
		if connectionState == .connected, !connectionIsActive {
			logConnectionEvent("App became active; connection was inactive; preparing background reconnect")
			#if canImport(UIKit)
				prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
			#else
				prepareForReconnectAfterBackgroundLoss()
			#endif
			return
		}
		if connectionState == .idle || connectionState == .connecting {
			logConnectionEvent("App became active; reconciling connection")
			if connectionState == .connecting, connectTask == nil, !connectionIsActive {
				connectionState = .idle
			}
			beginConnectionAttemptIfNeeded(
				after: activationReconnectDelayNanoseconds,
				presentation: connectionPresentationForCurrentState
			)
		}
	}

	func clearAppInactiveState() {}

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

	private var connectionStateDescription: String {
		switch connectionState {
		case .idle: "idle"
		case .connecting: "connecting"
		case .connected: "connected"
		case .waitingForPassword: "waitingForPassword"
		case .closedByUser: "closedByUser"
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

	private func configureTerminalView() {
		terminalView.onCloseTabRequest = { [weak self] in
			self?.requestClose()
		}
		terminalView.onNewTabRequest = { [weak self] in
			self?.requestNewTab()
		}
		terminalView.onSelectTabRequest = { [weak self] index in
			self?.requestSelectTab(index)
		}
		terminalView.onMoveTabSelectionRequest = { [weak self] offset in
			self?.requestMoveTabSelection(offset)
		}
		terminalView.onShowSettingsRequest = { [weak self] in
			self?.requestShowSettings()
		}
		terminalView.onDismissAuxiliaryUIRequest = { [weak self] in
			self?.requestDismissAuxiliaryUI() ?? false
		}
		terminalView.onWrite = { [weak self] data in
			guard let self else { return }
			self.recordTerminalInput(data)
			switch self.endpoint {
			case .remote:
				self.sshSession.connection.send(data)
			case .localShell:
				#if os(macOS)
					self.localShellSession?.send(data)
				#endif
			}
		}
		terminalView.onResize = { [weak self] _, _ in
			guard let self, let size = self.terminalView.currentTerminalSize() else { return }
			self.updateTerminalSize(size)
		}
		terminalView.onTitleChange = { [weak self] title in
			self?.reportedTitle = title
		}
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

	func requestClose() {
		onRequestClose?()
	}

	func requestNewTab() {
		onRequestNewTab?()
	}

	func requestSelectTab(_ index: Int) {
		onRequestSelectTab?(index)
	}

	func requestMoveTabSelection(_ offset: Int) {
		onRequestMoveTabSelection?(offset)
	}

	func requestShowSettings() {
		onRequestShowSettings?()
	}

	func requestReconnect() {
		#if canImport(UIKit)
			prepareForReconnectAfterBackgroundLoss(snapshot: displaySnapshot)
		#else
			prepareForReconnectAfterBackgroundLoss()
		#endif
	}

	@discardableResult
	func requestDismissAuxiliaryUI() -> Bool {
		onRequestDismissAuxiliaryUI?() ?? false
	}

	private func handleSSHSessionClose(_ reason: SSHTerminalSession.CloseReason) {
		let wasConnectedBeforeClose = isConnected
		connectTask?.cancel()
		connectTask = nil
		if connectionState == .connecting || connectionState == .connected {
			connectionState = .idle
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
				connectionState = .closedByUser
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			}
		case .cleanExit:
			logConnectionEvent("SSH session exited cleanly")
			if ApplicationActivity.isActive {
				wantsConnection = false
				connectionState = .closedByUser
				finishRestorationPresentation()
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			} else {
				wantsConnection = true
				connectionState = .idle
				#if canImport(UIKit)
					prepareForReconnectAfterBackgroundLoss(snapshot: restorationSnapshot)
				#else
					prepareForReconnectAfterBackgroundLoss()
				#endif
			}
		case let .error(message):
			logConnectionEvent("SSH session closed with error: \(message)")
			connectionState = .idle
			if shouldReconnectAfterClose(message: message, wasConnectedBeforeClose: wasConnectedBeforeClose) {
				connectionError = nil
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
				connectionError = message
				finishRestorationPresentation()
				notifyOverlayStateChanged()
			}
		}
	}

	#if os(macOS)
		private func handleLocalShellClose(_ reason: LocalShellSession.CloseReason) {
			connectTask?.cancel()
			connectTask = nil
			if connectionState == .connecting || connectionState == .connected {
				connectionState = .idle
			}
			finishRestorationPresentation()

			switch reason {
			case .localDisconnect:
				connectionState = .closedByUser
				notifyOverlayStateChanged()
			case .cleanExit:
				connectionState = .closedByUser
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			case let .error(message):
				connectionError = message
				notifyOverlayStateChanged()
			}
		}
	#endif
}
