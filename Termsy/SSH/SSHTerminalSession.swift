//
//  SSHTerminalSession.swift
//  Termsy
//
//  Owns the SSH transport for a terminal tab.
//  Surface state lives in the tab's persistent TerminalView.
//

import Foundation

@MainActor
final class SSHTerminalSession {
	enum CloseReason {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	let connection: SSHConnection

	/// Called with raw bytes received from the remote shell.
	var onRemoteOutput: ((Data) -> Void)?

	/// Whether the terminal tab is the selected foreground tab.
	private(set) var isForeground = true

	var onClose: ((CloseReason) -> Void)?

	init() {
		nonisolated(unsafe) var sessionRef: SSHTerminalSession?

		self.connection = SSHConnection(
			onData: { data in
				let ref = sessionRef
				DispatchQueue.main.async {
					ref?.handleIncomingData(data)
				}
			},
			onClose: { reason in
				let ref = sessionRef
				DispatchQueue.main.async {
					ref?.handleConnectionClose(reason)
				}
			}
		)
		sessionRef = self
	}

	private(set) var terminalSize = TerminalWindowSize.default

	func updateTerminalSize(_ size: TerminalWindowSize) {
		guard size.columns > 0, size.rows > 0 else { return }
		terminalSize = size
		connection.resize(size)
	}

	func connect(host: String, port: Int, username: String, password: String?) async throws {
		try await connection.connect(host: host, port: port, username: username, password: password)
		try await connection.startShell(size: terminalSize)
	}

	func disconnect() {
		connection.disconnect()
	}

	// MARK: - Foreground / Background

	func enterForeground() {
		guard !isForeground else { return }
		isForeground = true
	}

	func enterBackground() {
		guard isForeground else { return }
		isForeground = false
	}

	// MARK: - Private

	private func handleConnectionClose(_ reason: SSHConnection.CloseReason) {
		switch reason {
		case .localDisconnect:
			onClose?(.localDisconnect)
		case .cleanExit:
			onClose?(.cleanExit)
		case let .error(message):
			onClose?(.error(message))
		}
	}

	private func handleIncomingData(_ data: Data) {
		onRemoteOutput?(data)
	}
}
