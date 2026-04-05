//
//  SSHTerminalSession.swift
//  Termsy
//
//  Bridges an SSH connection to a TerminalView.
//  When backgrounded (no surface), incoming data is buffered to disk.
//  When foregrounded, a new surface is created and the buffer is replayed.
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

	/// Set by the terminal representable when the view is created.
	weak var terminalView: TerminalView?

	/// Whether the terminal surface is active (tab is selected).
	private(set) var isForeground = true

	/// File handle for writing buffered data while backgrounded.
	private var bufferFileHandle: FileHandle?
	private var bufferURL: URL?

	/// Whether we're currently replaying buffered data.
	private(set) var isReplaying = false

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

	/// Last known grid size from the Ghostty surface.
	var lastCols: Int = 80
	var lastRows: Int = 24

	func connect(host: String, port: Int, username: String, password: String?) async throws {
		try await connection.connect(host: host, port: port, username: username, password: password)
		try await connection.startShell(cols: lastCols, rows: lastRows)
		// Re-send resize in case the surface reported a different size before the shell existed
		connection.resize(cols: lastCols, rows: lastRows)
	}

	func disconnect() {
		connection.disconnect()
		cleanupBuffer()
	}

	// MARK: - Foreground / Background

	/// Call when this tab becomes the selected tab.
	func enterForeground() {
		guard !isForeground else { return }
		isForeground = true
		// Replay happens after the TerminalView is created and calls replayIfNeeded()
	}

	/// Call when another tab is selected (this tab goes to background).
	func enterBackground() {
		guard isForeground else { return }
		isForeground = false
		startBuffering()
		// The caller is responsible for destroying the TerminalView/surface.
		terminalView = nil
	}

	/// Replays buffered data into the terminal view in chunks, yielding between
	/// each chunk so the run loop can render frames and handle input.
	func replayIfNeeded() async {
		guard let bufferURL, FileManager.default.fileExists(atPath: bufferURL.path) else { return }
		guard let view = terminalView else { return }

		// Close the write handle so all data is flushed
		bufferFileHandle?.closeFile()
		bufferFileHandle = nil

		guard let data = try? Data(contentsOf: bufferURL, options: .mappedIfSafe) else {
			cleanupBuffer()
			return
		}

		guard !data.isEmpty else {
			cleanupBuffer()
			return
		}

		isReplaying = true
		let chunkSize = 64 * 1024 // 64KB per chunk
		var offset = 0

		while offset < data.count {
			let end = min(offset + chunkSize, data.count)
			let chunk = data[offset..<end]
			view.feedData(Data(chunk))
			offset = end
			await Task.yield()
		}

		isReplaying = false
		cleanupBuffer()
	}

	// MARK: - Private

	private func handleConnectionClose(_ reason: SSHConnection.CloseReason) {
		switch reason {
		case .localDisconnect:
			onClose?(.localDisconnect)
		case .cleanExit:
			terminalView?.processExited()
			cleanupBuffer()
			onClose?(.cleanExit)
		case let .error(message):
			terminalView?.processExited()
			cleanupBuffer()
			onClose?(.error(message))
		}
	}

	private func handleIncomingData(_ data: Data) {
		if isForeground {
			terminalView?.feedData(data)
		} else {
			writeToBuffer(data)
		}
	}

	private func startBuffering() {
		cleanupBuffer()
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("termsy-buffer-\(UUID().uuidString).bin")
		FileManager.default.createFile(atPath: url.path, contents: nil)
		bufferFileHandle = try? FileHandle(forWritingTo: url)
		bufferURL = url
	}

	private func writeToBuffer(_ data: Data) {
		if bufferFileHandle == nil {
			startBuffering()
		}
		bufferFileHandle?.write(data)
	}

	private func cleanupBuffer() {
		bufferFileHandle?.closeFile()
		bufferFileHandle = nil
		if let url = bufferURL {
			try? FileManager.default.removeItem(at: url)
			bufferURL = nil
		}
	}

	deinit {
		// Can't call cleanupBuffer() directly since we might not be on MainActor.
		// The temp file will be cleaned up by the OS eventually.
		bufferFileHandle?.closeFile()
	}
}
