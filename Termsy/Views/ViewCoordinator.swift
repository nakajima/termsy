//
//  ViewCoordinator.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Observation
import SwiftUI

@Observable @MainActor
class ViewCoordinator {
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

	private var appIsActive = true

	/// All open terminal tabs.
	var tabs: [TerminalTab] = []

	/// The currently selected tab, or nil if showing the session list.
	var selectedTabID: UUID?

	var selectedTab: TerminalTab? {
		tabs.first { $0.id == selectedTabID }
	}

	func openTab(for session: Session) {
		open(tab: TerminalTab(session: session))
	}

	#if os(macOS)
	func openLocalShellTab(profile: LocalShellProfile = .default) {
		open(tab: TerminalTab(localShellProfile: profile))
	}
	#endif

	private func open(tab: TerminalTab) {
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
		selectTab(tab.id)
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
		if tabs.contains(where: \.shouldRequestBackgroundExecution) {
			_ = ApplicationActivity.beginBackgroundExecution(name: "Termsy SSH")
		}
		for tab in tabs {
			tab.noteAppWillResignActive()
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

		guard let selectedTab else { return }
		if selectedTab.consumeReconnectOnActivation() {
			selectedTab.requestReconnect()
			return
		}
		guard selectedTab.isConnected else { return }
		guard !selectedTab.connectionIsActive else { return }
		selectedTab.requestReconnect()
	}

	func selectTab(_ id: UUID?) {
		let previousID = selectedTabID
		selectedTabID = id

		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.id == previousID }) {
			prevTab.enterBackground()
		}

		if let id, let tab = tabs.first(where: { $0.id == id }) {
			tab.enterForeground()
		}

		refreshDisplayActivity()
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
			} else {
				let newIndex = min(index, tabs.count - 1)
				selectTab(tabs[newIndex].id)
			}
		}
	}

	func closeOtherTabs(_ id: UUID?) {
		let toClose = tabs.filter { $0.id != id }
		for tab in toClose {
			tab.close()
		}
		tabs.removeAll { $0.id != id }
		if let id { selectTab(id) }
	}

	func moveTab(from source: IndexSet, to destination: Int) {
		tabs.move(fromOffsets: source, toOffset: destination)
	}

	func reorderTabs(_ orderedIDs: [UUID]) {
		var reordered: [TerminalTab] = []
		for id in orderedIDs {
			if let tab = tabs.first(where: { $0.id == id }) {
				reordered.append(tab)
			}
		}
		tabs = reordered
	}

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
	var isRestoring = false
	var onRequestClose: (() -> Void)?
	var onRequestNewTab: (() -> Void)?
	var onRequestSelectTab: ((Int) -> Void)?
	var onRequestMoveTabSelection: ((Int) -> Void)?
	var onRequestShowSettings: (() -> Void)?
	var onRequestDismissAuxiliaryUI: (() -> Bool)?
	var onRequestReconnect: (() -> Void)?
	var onConnectionEstablished: ((Session) -> Void)?
	var reportedTitle = ""
	var connectionLog: [String] = []

	@ObservationIgnored private var wasConnectedWhenAppResignedActive = false
	@ObservationIgnored private var shouldReconnectOnActivation = false
	@ObservationIgnored private(set) var isDisplayActive = false
	@ObservationIgnored private var backgroundReconnectGraceDeadline: Date?
	@ObservationIgnored private var reconnectGraceTask: Task<Void, Never>?
	@ObservationIgnored private var tmuxStartupTask: Task<Void, Never>?
	@ObservationIgnored private var remoteConnectAttempt = 0

	let id = UUID()

	init(session: Session) {
		self.endpoint = .remote
		self.session = session
		self.terminalView = TerminalView(frame: .zero)
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

	var displayTitle: String {
		let dynamicTitle = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		if !dynamicTitle.isEmpty {
			return dynamicTitle
		}

		switch endpoint {
		case .remote:
			guard let session else { return "Session" }
			let baseTitle = "\(session.username)@\(session.hostname)"
			if let tmuxName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
			   !tmuxName.isEmpty {
				return "\(tmuxName) • \(baseTitle)"
			}
			return baseTitle
		case let .localShell(profile):
			return profile.titleFallback
		}
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

	var connectionIsActive: Bool {
		switch endpoint {
		case .remote:
			sshSession.connection.isActive
		case .localShell:
			#if os(macOS)
			localShellSession?.isActive ?? false
			#else
			false
			#endif
		}
	}

	var connectionLogText: String {
		connectionLog.joined(separator: "\n")
	}

	var shouldRequestBackgroundExecution: Bool {
		guard case .remote = endpoint else { return false }
		return isConnected || (connectionError == nil && !needsPassword)
	}

	func connect() async {
		connectionError = nil
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
			logConnectionEvent("Attempt \(attempt): connection established")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startTmuxIfNeeded(using: sshSession, attempt: attempt)
		} catch SSHConnectionError.authenticationFailed {
			guard self.sshSession === sshSession else { return }
			logConnectionEvent("Attempt \(attempt): authentication failed; prompting for password")
			needsPassword = true
		} catch {
			guard self.sshSession === sshSession else { return }
			logConnectionEvent("Attempt \(attempt): connection failed: \(error)")
			connectionError = "\(error)"
		}
	}

	#if os(macOS)
	private func connectLocalShell() async {
		guard let localShellSession else { return }
		do {
			try localShellSession.start()
			isConnected = true
			clearAppInactiveState()
		} catch {
			print("[LocalShell] failed to start: \(error)")
			connectionError = error.localizedDescription
		}
	}
	#endif

	private func startTmuxIfNeeded(using sshSession: SSHTerminalSession, attempt: Int) {
		guard let session,
		      let rawName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !rawName.isEmpty
		else { return }

		let escapedName = shellQuoted(rawName)
		let command = Data("tmux new-session -A -s \(escapedName)\r".utf8)
		tmuxStartupTask?.cancel()
		logConnectionEvent("Attempt \(attempt): scheduling tmux attach for \(rawName)")
		tmuxStartupTask = Task { @MainActor [weak self, weak sshSession] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			guard let self, let sshSession, self.isConnected, self.sshSession === sshSession else { return }
			self.logConnectionEvent("Attempt \(attempt): sending tmux attach command")
			sshSession.connection.send(command)
		}
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

	private func configureSSHSessionCallbacks(for sshSession: SSHTerminalSession? = nil) {
		let sshSession = sshSession ?? self.sshSession
		sshSession.onRemoteOutput = { [weak self, weak sshSession] data in
			guard let self, let sshSession, self.sshSession === sshSession else { return }
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
			logConnectionEvent("Attempt \(attempt): connection established with password")
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startTmuxIfNeeded(using: sshSession, attempt: attempt)
		} catch {
			guard self.sshSession === sshSession else { return }
			logConnectionEvent("Attempt \(attempt): password retry failed: \(error)")
			connectionError = "\(error)"
		}
	}

	func disconnect() {
		isConnected = false
		tmuxStartupTask?.cancel()
		tmuxStartupTask = nil
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
		configureTerminalView()
		terminalView.setDisplayActive(isDisplayActive)
	}

	func applyTheme(_ theme: AppTheme) {
		terminalView.applyTheme(theme)
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
	}

	func consumeReconnectOnActivation() -> Bool {
		let shouldReconnect = shouldReconnectOnActivation
		shouldReconnectOnActivation = false
		return shouldReconnect
	}

	func clearAppInactiveState() {
		wasConnectedWhenAppResignedActive = false
		shouldReconnectOnActivation = false
		backgroundReconnectGraceDeadline = nil
		reconnectGraceTask?.cancel()
		reconnectGraceTask = nil
	}

	func prepareForReconnectAfterBackgroundLoss() {
		logConnectionEvent("Preparing for reconnect after background loss")
		clearAppInactiveState()
		connectionError = nil
		needsPassword = false
		isRestoring = false
		disconnect()
		resetTerminalView()
	}

	private func shouldAutoReconnect(for message: String) -> Bool {
		guard case .remote = endpoint else { return false }
		let isTcpShutdown = message.localizedCaseInsensitiveContains("tcpShutdown")
			|| message.localizedCaseInsensitiveContains("tcp shutdown")
		guard isTcpShutdown else { return false }
		if !ApplicationActivity.isActive {
			return wasConnectedWhenAppResignedActive
		}
		guard let deadline = backgroundReconnectGraceDeadline else { return false }
		return Date() < deadline
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
		logConnectionEvent("Reconnect requested")
		onRequestReconnect?()
	}

	func noteConnectingOverlayWithoutActiveAttempt() {
		logConnectionEvent("Connecting UI visible without an active connect attempt; retrying")
	}

	@discardableResult
	func requestDismissAuxiliaryUI() -> Bool {
		onRequestDismissAuxiliaryUI?() ?? false
	}

	private func handleSSHSessionClose(_ reason: SSHTerminalSession.CloseReason) {
		isConnected = false
		needsPassword = false
		isRestoring = false
		tmuxStartupTask?.cancel()
		tmuxStartupTask = nil

		switch reason {
		case .localDisconnect:
			logConnectionEvent("SSH session closed locally")
			clearAppInactiveState()
		case .cleanExit:
			logConnectionEvent("SSH session exited cleanly")
			clearAppInactiveState()
			terminalView.processExited()
			onRequestClose?()
		case let .error(message):
			logConnectionEvent("SSH session closed with error: \(message)")
			if shouldAutoReconnect(for: message) {
				logConnectionEvent("Scheduling automatic reconnect after transport shutdown")
				connectionError = nil
				if ApplicationActivity.isActive, terminalView.hasAttachedWindow {
					onRequestReconnect?()
				} else {
					shouldReconnectOnActivation = true
				}
			} else {
				clearAppInactiveState()
				connectionError = message
			}
		}
	}

	#if os(macOS)
	private func handleLocalShellClose(_ reason: LocalShellSession.CloseReason) {
		isConnected = false
		needsPassword = false
		isRestoring = false

		switch reason {
		case .localDisconnect:
			clearAppInactiveState()
		case .cleanExit:
			clearAppInactiveState()
			terminalView.processExited()
			onRequestClose?()
		case let .error(message):
			clearAppInactiveState()
			connectionError = message
		}
	}
	#endif
}
