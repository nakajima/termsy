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
	var selectedTabID: Session.ID?

	var selectedTab: TerminalTab? {
		tabs.first { $0.session.id == selectedTabID }
	}

	func openTab(for session: Session) {
		// Don't open a duplicate tab for the same session
		if let existing = tabs.first(where: { $0.session.id == session.id }) {
			selectTab(existing.session.id)
			return
		}

		let tab = TerminalTab(session: session)
		tabs.append(tab)
		selectTab(session.id)
	}

	func selectTab(_ id: Session.ID?) {
		let previousID = selectedTabID
		selectedTabID = id

		// Background the previous tab
		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.session.id == previousID }) {
			prevTab.sshSession.enterBackground()
		}

		// Foreground the new tab
		if let id, let tab = tabs.first(where: { $0.session.id == id }) {
			tab.sshSession.enterForeground()
		}
	}

	func closeTab(_ id: Session.ID?) {
		guard let id, let index = tabs.firstIndex(where: { $0.session.id == id }) else { return }
		let tab = tabs[index]
		tab.sshSession.disconnect()
		tabs.remove(at: index)

		if selectedTabID == id {
			if tabs.isEmpty {
				selectedTabID = nil
			} else {
				let newIndex = min(index, tabs.count - 1)
				selectTab(tabs[newIndex].session.id)
			}
		}
	}

	func closeOtherTabs(_ id: Session.ID?) {
		let toClose = tabs.filter { $0.session.id != id }
		for tab in toClose {
			tab.sshSession.disconnect()
		}
		tabs.removeAll { $0.session.id != id }
		if let id { selectTab(id) }
	}

	func moveTab(from source: IndexSet, to destination: Int) {
		tabs.move(fromOffsets: source, toOffset: destination)
	}

	func reorderTabs(_ orderedIDs: [Int64]) {
		var reordered: [TerminalTab] = []
		for id in orderedIDs {
			if let tab = tabs.first(where: { $0.session.id == id }) {
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

	var id: Session.ID? { session.id }

	init(session: Session) {
		self.session = session
		self.sshSession = SSHTerminalSession()
	}

	func connect() async {
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
		sshSession.disconnect()
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
}
