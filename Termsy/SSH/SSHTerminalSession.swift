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
	private final class CallbackRelay: @unchecked Sendable {
		weak var session: SSHTerminalSession?
	}

	enum CloseReason {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	let connection: SSHConnection

	/// Called with raw bytes received from the remote shell.
	var onRemoteOutput: ((Data) -> Void)?
	var onEvent: ((String) -> Void)?

	/// Whether the terminal tab is the selected foreground tab.
	private(set) var isForeground = true

	var onClose: ((CloseReason) -> Void)?

	init() {
		let relay = CallbackRelay()

		self.connection = SSHConnection(
			onData: { data in
				DispatchQueue.main.async {
					relay.session?.handleIncomingData(data)
				}
			},
			onClose: { reason in
				DispatchQueue.main.async {
					relay.session?.handleConnectionClose(reason)
				}
			},
			onEvent: { message in
				DispatchQueue.main.async {
					relay.session?.onEvent?(message)
				}
			}
		)
		relay.session = self
	}

	private(set) var terminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)

	func updateTerminalSize(_ size: TerminalWindowSize) {
		guard size.columns > 0, size.rows > 0 else { return }
		let previousSize = terminalSize
		terminalSize = size
		// Avoid redundant SSH window-change requests during tab/view churn.
		guard size.columns != previousSize.columns || size.rows != previousSize.rows else { return }
		connection.resize(size)
	}

	func connect(host: String, port: Int, username: String, password: String?, tmuxSessionName: String?) async throws {
		let startupOutputGraceNanoseconds: UInt64 = tmuxSessionName == nil ? 500_000_000 : 2_000_000_000
		try await connection.connect(host: host, port: port, username: username, password: password)
		try await connection.startShell(
			size: terminalSize,
			startupCommand: ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: tmuxSessionName),
			startupOutputGraceNanoseconds: startupOutputGraceNanoseconds
		)
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
