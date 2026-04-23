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
		#if canImport(UIKit)
			persistWorkspaceStateIfPossible(snapshotRecords: capturePersistedTerminalSnapshots())
		#else
			persistWorkspaceStateIfPossible()
		#endif
		if tabs.contains(where: \.shouldRequestBackgroundExecution) {
			_ = ApplicationActivity.beginBackgroundExecution(name: "Teletype SSH")
		}
		refreshDisplayActivity()
	}

	func appDidBecomeActive() {
		appIsActive = true
		ApplicationActivity.isActive = true
		ApplicationActivity.endBackgroundExecution()
		for tab in tabs {
			tab.noteAppDidBecomeActive()
		}
		refreshDisplayActivity()
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

	let endpoint: TerminalEndpoint
	var session: Session?
	var sshSession = SSHTerminalSession()
	#if os(macOS)
		private let localShellSession: LocalShellSession?
	#endif
	var terminalView: TerminalView
	var isConnected = false
	var connectionError: String?
	var needsPassword = false
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
	@ObservationIgnored private var wasConnectedWhenAppResignedActive = false
	@ObservationIgnored private(set) var isDisplayActive = false
	@ObservationIgnored private var backgroundReconnectGraceDeadline: Date?
	@ObservationIgnored private var reconnectGraceTask: Task<Void, Never>?
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	@ObservationIgnored private var pendingAutomaticConnectDelayNanoseconds: UInt64 = 0
	@ObservationIgnored private let activationReconnectDelayNanoseconds: UInt64 = 750_000_000
	@ObservationIgnored private var tmuxStartupTask: Task<Void, Never>?
	@ObservationIgnored private var remoteConnectAttempt = 0

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
				self?.terminalView.feedData(data)
			}
			localShellSession?.onClose = { [weak self] reason in
				self?.handleLocalShellClose(reason)
			}
		}
	#endif

	private(set) var customTitle: String?

	var automaticTitle: String {
		let dynamicTitle = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		if !dynamicTitle.isEmpty {
			return dynamicTitle
		}

		switch endpoint {
		case .remote:
			guard let session else { return "Session" }
			let baseTitle = "\(session.username)@\(session.hostname)"
			if let tmuxName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
			   !tmuxName.isEmpty
			{
				return "\(tmuxName) • \(baseTitle)"
			}
			return baseTitle
		case let .localShell(profile):
			return profile.titleFallback
		}
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
		if let restorationMode {
			return .restoring(restorationMode)
		}
		if let connectionError {
			return .failed(connectionError)
		}
		if needsPassword {
			return .awaitingPassword
		}
		if !isConnected {
			return .connecting
		}
		return .connected
	}

	var showsOverlay: Bool {
		switch overlayState {
		case .connected:
			return false
		case .connecting, .awaitingPassword, .failed, .restoring:
			return true
		}
	}

	var isRestoring: Bool {
		if case .restoring = overlayState {
			return true
		}
		return false
	}

	var showsConnectingOverlay: Bool {
		if case .connecting = overlayState {
			return true
		}
		return false
	}

	var showsRestoringProgress: Bool {
		guard case let .restoring(mode) = overlayState else { return false }
		return mode.showsProgress
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
		return isConnected || (connectionError == nil && !needsPassword)
	}

	var hasRecoverableBackgroundDisconnectError: Bool {
		guard case .remote = endpoint else { return false }
		guard !isConnected, wasConnectedWhenAppResignedActive, let connectionError else { return false }
		return isRecoverableBackgroundDisconnectMessage(connectionError)
	}

	func hostDidAppear() {
		renderPendingPreviewIfNeeded()
		ensureConnectionIfNeeded()
	}

	func retryConnection() {
		guard !isPassivePreview else { return }
		logConnectionEvent("Reconnect requested")
		connectTask?.cancel()
		connectTask = nil
		clearRestorationState()
		connectionError = nil
		needsPassword = false
		notifyOverlayStateChanged()
		ensureConnectionIfNeeded(after: 0)
	}

	private func ensureConnectionIfNeeded(after delayNanoseconds: UInt64? = nil) {
		if let delayNanoseconds {
			pendingAutomaticConnectDelayNanoseconds = delayNanoseconds
		}
		guard !isPassivePreview else {
			renderPendingPreviewIfNeeded()
			return
		}
		guard terminalView.hasAttachedWindow else { return }
		guard !isConnected,
		      connectionError == nil,
		      !needsPassword,
		      connectTask == nil,
		      !connectionIsActive
		else {
			return
		}

		let delay = pendingAutomaticConnectDelayNanoseconds
		pendingAutomaticConnectDelayNanoseconds = 0
		notifyOverlayStateChanged()
		connectTask = Task { @MainActor [weak self] in
			defer {
				self?.connectTask = nil
				self?.notifyOverlayStateChanged()
			}
			if delay > 0 {
				try? await Task.sleep(nanoseconds: delay)
				guard !Task.isCancelled else { return }
			}
			await self?.connect()
		}
	}

	func connect() async {
		if isPassivePreview {
			renderPendingPreviewIfNeeded()
			return
		}
		connectionError = nil
		notifyOverlayStateChanged()
		logConnectionEvent("Connect requested")
		switch endpoint {
		case .remote:
			await connectRemote()
		case .localShell:
			#if os(macOS)
				await connectLocalShell()
			#endif
		}
	}

	private func connectRemote() async {
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
		logConnectionEvent("Attempt \(attempt): connecting to \(session.username)@\(session.hostname):\(session.port)")
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: keychainPassword
			)
			guard !Task.isCancelled, self.sshSession === sshSession else {
				logConnectionEvent("Attempt \(attempt): ignoring stale successful connection")
				sshSession.disconnect()
				return
			}
			isConnected = true
			self.session?.lastConnectedAt = Date()
			clearAppInactiveState()
			notifyOverlayStateChanged()
			logConnectionEvent("Attempt \(attempt): connection established")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startRemotePostConnectSetup(using: sshSession, attempt: attempt)
		} catch SSHConnectionError.authenticationFailed {
			guard self.sshSession === sshSession else { return }
			clearRestorationState()
			logConnectionEvent("Attempt \(attempt): authentication failed; prompting for password")
			needsPassword = true
			notifyOverlayStateChanged()
		} catch {
			guard self.sshSession === sshSession else { return }
			clearRestorationState()
			logConnectionEvent("Attempt \(attempt): connection failed: \(error)")
			connectionError = "\(error)"
			notifyOverlayStateChanged()
		}
	}

	#if os(macOS)
		private func connectLocalShell() async {
			guard let localShellSession else { return }
			do {
				try localShellSession.start()
				isConnected = true
				clearRestorationState()
				clearAppInactiveState()
				notifyOverlayStateChanged()
			} catch {
				clearRestorationState()
				print("[LocalShell] failed to start: \(error)")
				connectionError = error.localizedDescription
				notifyOverlayStateChanged()
			}
		}
	#endif

	private func startRemotePostConnectSetup(using sshSession: SSHTerminalSession, attempt: Int) {
		let rawTmuxSessionName = (session?.tmuxSessionName)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let tmuxSessionName = rawTmuxSessionName.flatMap { $0.isEmpty ? nil : $0 }
		tmuxStartupTask?.cancel()
		guard let tmuxSessionName else {
			logConnectionEvent("Attempt \(attempt): no tmux session configured; leaving remote shell as-is")
			tmuxStartupTask = nil
			return
		}

		logConnectionEvent("Attempt \(attempt): scheduling tmux attach for \(tmuxSessionName)")
		tmuxStartupTask = Task { @MainActor [weak self, weak sshSession] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			guard let self, let sshSession, self.isConnected, self.sshSession === sshSession else { return }

			var hasGhosttyTerminfo = false
			do {
				self.logConnectionEvent("Attempt \(attempt): checking/installing remote xterm-ghostty terminfo")
				let result = try await sshSession.connection.runDetachedCommand(
					ShellTitleIntegration.remoteTerminfoInstallCommand
				)
				hasGhosttyTerminfo = self.remoteGhosttyTerminfoReady(from: result.output)
				let logOutput = self.remoteGhosttyTerminfoLogOutput(from: result.output)
				if let exitSignal = result.exitSignal {
					self.logConnectionEvent("Attempt \(attempt): remote terminfo setup exited with signal \(exitSignal)")
				} else if let exitStatus = result.exitStatus, exitStatus != 0 {
					self.logConnectionEvent("Attempt \(attempt): remote terminfo setup exited with status \(exitStatus)")
				}
				if !logOutput.isEmpty {
					self.logConnectionEvent("Attempt \(attempt): remote terminfo setup output: \(logOutput)")
				}
				self.logConnectionEvent(
					hasGhosttyTerminfo
						? "Attempt \(attempt): remote xterm-ghostty terminfo ready"
						: "Attempt \(attempt): remote xterm-ghostty terminfo unavailable; continuing with xterm-256color"
				)
			} catch {
				self.logConnectionEvent("Attempt \(attempt): remote terminfo setup failed: \(error)")
			}

			guard self.isConnected, self.sshSession === sshSession else { return }
			let escapedName = self.shellQuoted(tmuxSessionName)
			let commandPrefix = hasGhosttyTerminfo ? "env TERM=xterm-ghostty " : ""
			let command = Data("\(commandPrefix)tmux new-session -A -s \(escapedName)\r".utf8)
			self.logConnectionEvent("Attempt \(attempt): sending tmux attach command")
			sshSession.connection.send(command)
		}
	}

	private func remoteGhosttyTerminfoReady(from output: String) -> Bool {
		output
			.split(whereSeparator: \.isNewline)
			.contains { $0 == "TERMSY_XTERM_GHOSTTY_READY=1" }
	}

	private func remoteGhosttyTerminfoLogOutput(from output: String) -> String {
		output
			.split(whereSeparator: \.isNewline)
			.filter { !$0.hasPrefix("TERMSY_XTERM_GHOSTTY_READY=") }
			.map(String.init)
			.joined(separator: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func shellQuoted(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

	private func clearRestorationState() {
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
			if self.isRestoring {
				self.clearRestorationState()
			}
			if let onFirstRemoteOutput = self.onFirstRemoteOutput {
				self.onFirstRemoteOutput = nil
				onFirstRemoteOutput()
			}
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
		needsPassword = false
		connectionError = nil
		remoteConnectAttempt += 1
		let attempt = remoteConnectAttempt
		let sshSession = resetSSHSessionForNewConnection(attempt: attempt)
		logConnectionEvent("Attempt \(attempt): retrying with password for \(session.username)@\(session.hostname):\(session.port)")
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: password
			)
			guard !Task.isCancelled, self.sshSession === sshSession else {
				logConnectionEvent("Attempt \(attempt): ignoring stale successful password retry")
				sshSession.disconnect()
				return
			}
			isConnected = true
			self.session?.lastConnectedAt = Date()
			clearAppInactiveState()
			Keychain.setPassword(password, for: session)
			notifyOverlayStateChanged()
			logConnectionEvent("Attempt \(attempt): connection established with password")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startRemotePostConnectSetup(using: sshSession, attempt: attempt)
		} catch {
			guard self.sshSession === sshSession else { return }
			clearRestorationState()
			logConnectionEvent("Attempt \(attempt): password retry failed: \(error)")
			connectionError = "\(error)"
			notifyOverlayStateChanged()
		}
	}

	func disconnect() {
		connectTask?.cancel()
		connectTask = nil
		if isPassivePreview {
			isConnected = false
			pendingPreviewTranscript = nil
			notifyOverlayStateChanged()
			return
		}
		isConnected = false
		tmuxStartupTask?.cancel()
		tmuxStartupTask = nil
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
		isConnected = true
		connectionError = nil
		needsPassword = false
		clearRestorationState()
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
		reconnectGraceTask?.cancel()
		reconnectGraceTask = nil
		backgroundReconnectGraceDeadline = nil
		wasConnectedWhenAppResignedActive = isConnected
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
		logConnectionEvent("App will resign active; wasConnected=\(isConnected)")
	}

	func noteAppDidBecomeActive() {
		guard wasConnectedWhenAppResignedActive else { return }
		backgroundReconnectGraceDeadline = Date().addingTimeInterval(5)
		logConnectionEvent("App became active; reconnect grace window started")
		reconnectGraceTask?.cancel()
		reconnectGraceTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			self?.clearAppInactiveState()
		}
		if restorationMode == .backgroundReconnect {
			ensureConnectionIfNeeded(after: activationReconnectDelayNanoseconds)
			return
		}
		if hasRecoverableBackgroundDisconnectError || (isConnected && !connectionIsActive) {
			requestReconnect()
		}
	}

	func clearAppInactiveState() {
		wasConnectedWhenAppResignedActive = false
		backgroundReconnectGraceDeadline = nil
		reconnectGraceTask?.cancel()
		reconnectGraceTask = nil
	}

	#if canImport(UIKit)
		func prepareForReconnectAfterBackgroundLoss(snapshot: UIImage? = nil) {
			guard !isPassivePreview else { return }
			logConnectionEvent("Preparing for reconnect after background loss")
			clearAppInactiveState()
			connectTask?.cancel()
			connectTask = nil
			connectionError = nil
			needsPassword = false
			beginRestoration(.backgroundReconnect, snapshot: snapshot ?? displaySnapshot)
			disconnect()
			pendingAutomaticConnectDelayNanoseconds = activationReconnectDelayNanoseconds
			resetTerminalView()
			notifyOverlayStateChanged()
			ensureConnectionIfNeeded()
		}
	#else
		func prepareForReconnectAfterBackgroundLoss() {
			guard !isPassivePreview else { return }
			logConnectionEvent("Preparing for reconnect after background loss")
			clearAppInactiveState()
			connectTask?.cancel()
			connectTask = nil
			connectionError = nil
			needsPassword = false
			beginRestoration(.backgroundReconnect)
			disconnect()
			pendingAutomaticConnectDelayNanoseconds = activationReconnectDelayNanoseconds
			resetTerminalView()
			notifyOverlayStateChanged()
			ensureConnectionIfNeeded()
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

	private func shouldAutoReconnect(for message: String) -> Bool {
		guard isRecoverableBackgroundDisconnectMessage(message) else { return false }
		return shouldReconnectAfterAppDeactivation
	}

	private var shouldReconnectAfterAppDeactivation: Bool {
		guard case .remote = endpoint else { return false }
		if !ApplicationActivity.isActive {
			return wasConnectedWhenAppResignedActive
		}
		guard wasConnectedWhenAppResignedActive,
		      let deadline = backgroundReconnectGraceDeadline
		else {
			return false
		}
		return Date() < deadline
	}

	private func scheduleReconnectAfterBackgroundLoss(logMessage: String) {
		logConnectionEvent(logMessage)
		connectionError = nil
		pendingAutomaticConnectDelayNanoseconds = activationReconnectDelayNanoseconds
		notifyOverlayStateChanged()
		guard ApplicationActivity.isActive else { return }
		ensureConnectionIfNeeded()
	}

	func updateTerminalSize(_ size: TerminalWindowSize) {
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
		if connectionLog.count > 60 {
			connectionLog.removeFirst(connectionLog.count - 60)
		}
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
		connectTask?.cancel()
		connectTask = nil
		isConnected = false
		needsPassword = false
		tmuxStartupTask?.cancel()
		tmuxStartupTask = nil

		switch reason {
		case .localDisconnect:
			logConnectionEvent("SSH session closed locally")
			if restorationMode == .backgroundReconnect {
				logConnectionEvent("Ignoring expected local disconnect while preparing background reconnect")
				notifyOverlayStateChanged()
				return
			}
			clearRestorationState()
			clearAppInactiveState()
			notifyOverlayStateChanged()
		case .cleanExit:
			logConnectionEvent("SSH session exited cleanly")
			if shouldReconnectAfterAppDeactivation {
				#if canImport(UIKit)
					beginRestoration(.backgroundReconnect, snapshot: displaySnapshot)
				#else
					beginRestoration(.backgroundReconnect)
				#endif
				resetTerminalView()
				scheduleReconnectAfterBackgroundLoss(
					logMessage: "Treating clean SSH exit as recoverable after app deactivation"
				)
			} else {
				clearRestorationState()
				clearAppInactiveState()
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			}
		case let .error(message):
			logConnectionEvent("SSH session closed with error: \(message)")
			if shouldAutoReconnect(for: message) {
				#if canImport(UIKit)
					beginRestoration(.backgroundReconnect, snapshot: displaySnapshot)
				#else
					beginRestoration(.backgroundReconnect)
				#endif
				resetTerminalView()
				scheduleReconnectAfterBackgroundLoss(
					logMessage: "Scheduling automatic reconnect after transport shutdown"
				)
			} else {
				clearRestorationState()
				clearAppInactiveState()
				connectionError = message
				notifyOverlayStateChanged()
			}
		}
	}

	#if os(macOS)
		private func handleLocalShellClose(_ reason: LocalShellSession.CloseReason) {
			connectTask?.cancel()
			connectTask = nil
			isConnected = false
			needsPassword = false
			clearRestorationState()

			switch reason {
			case .localDisconnect:
				clearAppInactiveState()
				notifyOverlayStateChanged()
			case .cleanExit:
				clearAppInactiveState()
				notifyOverlayStateChanged()
				terminalView.processExited()
				onRequestClose?()
			case let .error(message):
				clearAppInactiveState()
				connectionError = message
				notifyOverlayStateChanged()
			}
		}
	#endif
}
