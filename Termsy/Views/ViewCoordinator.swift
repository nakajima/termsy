//
//  ViewCoordinator.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import SwiftUI
import Observation

@Observable @MainActor
class ViewCoordinator {
	var path = NavigationPath()
	var isShowingConnectView = false
	var isShowingSessionPicker = false
	var isShowingSettings = false

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
			self?.isShowingSessionPicker = true
		}
		tabs.append(tab)
		selectTab(tab.id)
	}

	func selectTab(_ id: UUID?) {
		let previousID = selectedTabID
		selectedTabID = id

		// Background the previous tab
		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.id == previousID }) {
			prevTab.sshSession.enterBackground()
		}

		// Foreground the new tab
		if let id, let tab = tabs.first(where: { $0.id == id }) {
			tab.sshSession.enterForeground()
		}
	}

	func closeTab(_ id: UUID?) {
		guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
		let tab = tabs[index]
		tab.disconnect()
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
			tab.disconnect()
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
}

/// Represents a single open terminal tab.
@Observable @MainActor
class TerminalTab: Identifiable {
	let session: Session
	let sshSession: SSHTerminalSession
	var isConnected = false
	var connectionError: String?
	var needsPassword = false
	var onRequestClose: (() -> Void)?
	var onRequestNewTab: (() -> Void)?

	let id = UUID()

	init(session: Session) {
		self.session = session
		self.sshSession = SSHTerminalSession()
		self.sshSession.onClose = { [weak self] reason in
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
		guard let name = session.tmuxSessionName, !name.isEmpty else { return }
		let command = "tmux new-session -A -s \(name)\n"
		sshSession.connection.send(Data(command.utf8))
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
			Keychain.setPassword(password, for: session)
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

	func requestClose() {
		onRequestClose?()
	}

	func requestNewTab() {
		onRequestNewTab?()
	}

	private func handleSessionClose(_ reason: SSHTerminalSession.CloseReason) {
		isConnected = false
		needsPassword = false

		switch reason {
		case .localDisconnect:
			break
		case .cleanExit:
			onRequestClose?()
		case let .error(message):
			connectionError = message
		}
	}
}
