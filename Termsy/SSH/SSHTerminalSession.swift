//
//  SSHTerminalSession.swift
//  Termsy
//
//  Bridges an SSH connection to a TerminalView.
//  When no terminal surface exists, all terminal output is recorded to disk.
//  When a surface is recreated, the transcript is replayed to restore state.
//

import Foundation

@MainActor
final class SSHTerminalSession {
	enum CloseReason {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	private enum Transcript {
		static let chunkSize = 64 * 1024
	}

	let connection: SSHConnection

	/// Set by the terminal host controller when the view is created.
	weak var terminalView: TerminalView?

	/// Whether the terminal surface is active (tab is selected).
	private(set) var isForeground = true

	/// Whether we're currently replaying the transcript into a fresh surface.
	private(set) var isReplaying = false

	var onClose: ((CloseReason) -> Void)?

	private var transcriptFileHandle: FileHandle?
	private var transcriptURL: URL?

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
		resetTranscript()
		try await connection.connect(host: host, port: port, username: username, password: password)
		try await connection.startShell(size: terminalSize)
	}

	func disconnect() {
		connection.disconnect()
		cleanupTranscript()
	}

	// MARK: - Foreground / Background

	/// Call when this tab becomes the selected tab.
	func enterForeground() {
		guard !isForeground else { return }
		isForeground = true
	}

	/// Call when another tab is selected (this tab goes to background).
	func enterBackground() {
		guard isForeground else { return }
		isForeground = false
		// The caller is responsible for destroying the TerminalView/surface.
		terminalView = nil
	}

	/// Replays the full transcript into a fresh terminal view. While replaying,
	/// newly arriving data is still appended to the transcript and is caught up
	/// before replay finishes.
	func replayIfNeeded() async {
		guard let terminalView else { return }
		guard let transcriptURL, FileManager.default.fileExists(atPath: transcriptURL.path) else { return }
		guard transcriptSize(at: transcriptURL) > 0 else { return }

		isReplaying = true
		defer { isReplaying = false }

		var replayedBytes: UInt64 = 0
		while true {
			let size = transcriptSize(at: transcriptURL)
			guard size > replayedBytes else { break }
			await replayTranscript(at: transcriptURL, from: replayedBytes, to: size, into: terminalView)
			replayedBytes = size
		}
	}

	// MARK: - Private

	private func handleConnectionClose(_ reason: SSHConnection.CloseReason) {
		switch reason {
		case .localDisconnect:
			onClose?(.localDisconnect)
		case .cleanExit:
			terminalView?.processExited()
			onClose?(.cleanExit)
		case let .error(message):
			terminalView?.processExited()
			onClose?(.error(message))
		}
	}

	private func handleIncomingData(_ data: Data) {
		appendToTranscript(data)

		if let terminalView, !isReplaying {
			terminalView.feedData(data)
		}
	}

	private func replayTranscript(
		at url: URL,
		from startOffset: UInt64,
		to endOffset: UInt64,
		into terminalView: TerminalView
	) async {
		guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
		defer {
			try? fileHandle.close()
		}

		try? fileHandle.seek(toOffset: startOffset)
		var remaining = endOffset - startOffset

		while remaining > 0 {
			let count = Int(min(UInt64(Transcript.chunkSize), remaining))
			guard let chunk = try? fileHandle.read(upToCount: count), !chunk.isEmpty else {
				break
			}
			terminalView.feedData(chunk)
			remaining -= UInt64(chunk.count)
			await Task.yield()
		}
	}

	private func appendToTranscript(_ data: Data) {
		guard !data.isEmpty else { return }
		guard let fileHandle = ensureTranscriptFile() else { return }
		fileHandle.seekToEndOfFile()
		fileHandle.write(data)
	}

	private func ensureTranscriptFile() -> FileHandle? {
		if let transcriptFileHandle {
			return transcriptFileHandle
		}

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("termsy-transcript-\(UUID().uuidString).bin")
		FileManager.default.createFile(atPath: url.path, contents: nil)
		guard let fileHandle = try? FileHandle(forWritingTo: url) else { return nil }
		transcriptURL = url
		transcriptFileHandle = fileHandle
		return fileHandle
	}

	private func transcriptSize(at url: URL) -> UInt64 {
		let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
		return size?.uint64Value ?? 0
	}

	private func resetTranscript() {
		cleanupTranscript()
		_ = ensureTranscriptFile()
	}

	private func cleanupTranscript() {
		transcriptFileHandle?.closeFile()
		transcriptFileHandle = nil
		if let url = transcriptURL {
			try? FileManager.default.removeItem(at: url)
			transcriptURL = nil
		}
	}

	deinit {
		transcriptFileHandle?.closeFile()
	}
}
