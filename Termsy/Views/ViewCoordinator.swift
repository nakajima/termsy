//
//  ViewCoordinator.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import UIKit
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
		let tab = TerminalTab(session: session)
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
		for tab in tabs {
			tab.noteAppWillResignActive()
		}
		refreshDisplayActivity()
	}

	func appDidBecomeActive() {
		appIsActive = true
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
		guard !selectedTab.sshSession.connection.isActive else { return }
		selectedTab.requestReconnect()
	}

	func selectTab(_ id: UUID?) {
		let previousID = selectedTabID
		selectedTabID = id

		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.id == previousID }) {
			prevTab.sshSession.enterBackground()
		}

		if let id, let tab = tabs.first(where: { $0.id == id }) {
			tab.sshSession.enterForeground()
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
	var session: Session
	let sshSession: SSHTerminalSession
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
		self.session = session
		self.sshSession = SSHTerminalSession()
		self.terminalView = TerminalView(frame: .zero)

		configureTerminalView()
		sshSession.onRemoteOutput = { [weak self] data in
			self?.terminalView.feedData(data)
		}
		sshSession.onClose = { [weak self] reason in
			self?.handleSessionClose(reason)
		}
	}

	func connect() async {
		connectionError = nil
		// Try none auth first, then fall back to keychain password
		let keychainPassword = Keychain.password(for: session)
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: keychainPassword
			)
			isConnected = true
			session.lastConnectedAt = Date()
			clearAppInactiveState()
			onConnectionEstablished?(session)
			startTmuxIfNeeded()
		} catch SSHConnectionError.authenticationFailed {
			print("[SSH] auth failed, prompting for password")
			needsPassword = true
		} catch {
			print("[SSH] connection error: \(error)")
			connectionError = "\(error)"
		}
	}

	private func startTmuxIfNeeded() {
		guard let rawName = session.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !rawName.isEmpty else { return }

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
			session.lastConnectedAt = Date()
			clearAppInactiveState()
			Keychain.setPassword(password, for: session)
			onConnectionEstablished?(session)
			startTmuxIfNeeded()
		} catch {
			print("[SSH] connection error: \(error)")
			connectionError = "\(error)"
		}
	}

	func disconnect() {
		isConnected = false
		sshSession.disconnect()
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
		let isTcpShutdown = message.localizedCaseInsensitiveContains("tcpShutdown")
			|| message.localizedCaseInsensitiveContains("tcp shutdown")
		guard isTcpShutdown else { return false }
		if UIApplication.shared.applicationState != .active {
			return wasConnectedWhenAppResignedActive
		}
		guard let deadline = backgroundReconnectGraceDeadline else { return false }
		return Date() < deadline
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
			self?.sshSession.connection.send(data)
		}
		terminalView.onResize = { [weak self] _, _ in
			guard let self, let size = self.terminalView.currentTerminalSize() else { return }
			self.sshSession.updateTerminalSize(size)
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

	private func handleSessionClose(_ reason: SSHTerminalSession.CloseReason) {
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
				if UIApplication.shared.applicationState == .active, terminalView.window != nil {
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
}
