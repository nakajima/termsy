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
			selectedTabID = existing.session.id
			return
		}

		let tab = TerminalTab(session: session)
		tabs.append(tab)
		selectedTabID = session.id
	}

	func closeTab(_ id: Session.ID?) {
		guard let id, let index = tabs.firstIndex(where: { $0.session.id == id }) else { return }
		let tab = tabs[index]
		tab.sshSession.disconnect()
		tabs.remove(at: index)

		// If we closed the selected tab, select an adjacent one
		if selectedTabID == id {
			if tabs.isEmpty {
				selectedTabID = nil
			} else {
				let newIndex = min(index, tabs.count - 1)
				selectedTabID = tabs[newIndex].session.id
			}
		}
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
		do {
			try await sshSession.connect(
				host: session.hostname,
				port: session.port,
				username: session.username,
				password: nil
			)
			isConnected = true
		} catch SSHConnectionError.authenticationFailed {
			print("[SSH] auth failed, prompting for password")
			needsPassword = true
		} catch {
			print("[SSH] connection error: \(error)")
			connectionError = "\(error)"
		}
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
		} catch {
			print("[SSH] connection error: \(error)")
			connectionError = "\(error)"
		}
	}
}
