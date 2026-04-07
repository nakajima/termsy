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
		for tab in tabs {
			tab.noteAppWillResignActive()
		}
		refreshDisplayActivity()
	}

	func appDidBecomeActive() {
		appIsActive = true
		ApplicationActivity.isActive = true
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
	let sshSession = SSHTerminalSession()
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

	private var wasConnectedWhenAppResignedActive = false
	private var shouldReconnectOnActivation = false
	private var backgroundReconnectGraceDeadline: Date?
	private var reconnectGraceTask: Task<Void, Never>?

	let id = UUID()

	init(session: Session) {
		self.endpoint = .remote
		self.session = session
		self.terminalView = TerminalView(frame: .zero)
		#if os(macOS)
		self.localShellSession = nil
		#endif

		configureTerminalView()
		sshSession.onRemoteOutput = { [weak self] data in
			self?.terminalView.feedData(data)
		}
		sshSession.onClose = { [weak self] reason in
			self?.handleSSHSessionClose(reason)
		}
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
			return profile.displayName
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

	func connect() async {
		connectionError = nil
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
		let keychainPassword = Keychain.password(for: session)
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: keychainPassword
			)
			isConnected = true
			self.session?.lastConnectedAt = Date()
			clearAppInactiveState()
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startTmuxIfNeeded()
		} catch SSHConnectionError.authenticationFailed {
			print("[SSH] auth failed, prompting for password")
			needsPassword = true
		} catch {
			print("[SSH] connection error: \(error)")
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

	private func startTmuxIfNeeded() {
		guard let session,
		      let rawName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !rawName.isEmpty
		else { return }

		let escapedName = shellQuoted(rawName)
		let command = Data("tmux new-session -A -s \(escapedName)\r".utf8)

		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			guard let self, self.isConnected else { return }
			self.sshSession.connection.send(command)
		}
	}

	private func shellQuoted(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	func connectWithPassword(_ password: String) async {
		guard case .remote = endpoint, let session else { return }
		needsPassword = false
		connectionError = nil
		disconnect()
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: password
			)
			isConnected = true
			self.session?.lastConnectedAt = Date()
			clearAppInactiveState()
			Keychain.setPassword(password, for: session)
			if let session = self.session {
				onConnectionEstablished?(session)
			}
			startTmuxIfNeeded()
		} catch {
			print("[SSH] connection error: \(error)")
			connectionError = "\(error)"
		}
	}

	func disconnect() {
		isConnected = false
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
		terminalView.stop()
		terminalView.removeFromSuperview()
		terminalView = TerminalView(frame: .zero)
		configureTerminalView()
	}

	func applyTheme(_ theme: AppTheme) {
		terminalView.applyTheme(theme)
	}

	func setDisplayActive(_ isActive: Bool) {
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
	}

	func noteAppDidBecomeActive() {
		guard wasConnectedWhenAppResignedActive else { return }
		backgroundReconnectGraceDeadline = Date().addingTimeInterval(5)
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
		onRequestReconnect?()
	}

	@discardableResult
	func requestDismissAuxiliaryUI() -> Bool {
		onRequestDismissAuxiliaryUI?() ?? false
	}

	private func handleSSHSessionClose(_ reason: SSHTerminalSession.CloseReason) {
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
			if shouldAutoReconnect(for: message) {
				print("[SSH] TCP transport shut down around app switch; reconnecting: \(message)")
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
