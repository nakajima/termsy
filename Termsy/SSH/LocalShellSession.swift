#if os(macOS)
import Darwin
import Dispatch
import Foundation

final class LocalShellSession {
	enum CloseReason {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	let profile: LocalShellProfile
	var onRemoteOutput: ((Data) -> Void)?
	var onClose: ((CloseReason) -> Void)?

	private let queue = DispatchQueue(label: "fm.folder.Termsy.LocalShellSession")
	private var masterFD: Int32 = -1
	private var childPID: pid_t = 0
	private var readSource: DispatchSourceRead?
	private var processSource: DispatchSourceProcess?
	private var pendingTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
	private var startDate = Date()
	private var isDisconnecting = false

	init(profile: LocalShellProfile) {
		self.profile = profile
	}

	var isActive: Bool {
		childPID > 0
	}

	func start() throws {
		guard childPID == 0 else { return }

		var master: Int32 = -1
		var winsize = winsize(
			ws_row: UInt16(max(pendingTerminalSize.rows, 1)),
			ws_col: UInt16(max(pendingTerminalSize.columns, 1)),
			ws_xpixel: UInt16(max(pendingTerminalSize.pixelWidth, 0)),
			ws_ypixel: UInt16(max(pendingTerminalSize.pixelHeight, 0))
		)

		let pid = forkpty(&master, nil, nil, &winsize)
		if pid < 0 {
			throw NSError(
				domain: NSPOSIXErrorDomain,
				code: Int(errno),
				userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
			)
		}

		if pid == 0 {
			chdir(profile.workingDirectory)
			let shellPath = profile.shellPath
			let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
			let loginShellName = "-\(shellName)"
			setenv("SHELL", shellPath, 1)
			setenv("TERM", "xterm-256color", 1)
			setenv("COLORTERM", "truecolor", 1)
			setenv("TERM_PROGRAM", "Termsy", 1)
			var args: [UnsafeMutablePointer<CChar>?] = [strdup(loginShellName), nil]
			execv(shellPath, &args)
			if let command = args[0] { free(command) }
			_exit(127)
		}

		childPID = pid
		masterFD = master
		startDate = Date()
		isDisconnecting = false
		_ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
		installReadSource()
		installProcessSource()
		applyPendingResize()
	}

	func send(_ data: Data) {
		guard masterFD >= 0, !data.isEmpty else { return }
		queue.async { [masterFD] in
			data.withUnsafeBytes { buffer in
				guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
				var bytesRemaining = data.count
				var offset = 0
				while bytesRemaining > 0 {
					let written = write(masterFD, baseAddress.advanced(by: offset), bytesRemaining)
					if written <= 0 {
						if errno == EINTR { continue }
						break
					}
					bytesRemaining -= written
					offset += written
				}
			}
		}
	}

	func updateTerminalSize(_ size: TerminalWindowSize) {
		pendingTerminalSize = size
		guard masterFD >= 0 else { return }
		applyPendingResize()
	}

	func stop() {
		disconnect()
	}

	func disconnect() {
		guard childPID > 0 || masterFD >= 0 else { return }
		isDisconnecting = true
		if childPID > 0 {
			kill(childPID, SIGHUP)
		}
		if masterFD >= 0 {
			readSource?.cancel()
			readSource = nil
		}
		if childPID == 0 {
			processSource?.cancel()
			processSource = nil
		}
	}

	private func installReadSource() {
		guard masterFD >= 0 else { return }
		let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
		source.setEventHandler { [weak self] in
			self?.drainOutput()
		}
		source.setCancelHandler { [weak self] in
			guard let self else { return }
			if self.masterFD >= 0 {
				close(self.masterFD)
				self.masterFD = -1
			}
		}
		readSource = source
		source.resume()
	}

	private func installProcessSource() {
		guard childPID > 0 else { return }
		let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
		source.setEventHandler { [weak self] in
			self?.handleProcessExit()
		}
		source.setCancelHandler { }
		processSource = source
		source.resume()
	}

	private func drainOutput() {
		guard masterFD >= 0 else { return }
		var buffer = [UInt8](repeating: 0, count: 16 * 1024)
		while true {
			let count = read(masterFD, &buffer, buffer.count)
			switch count {
			case let n where n > 0:
				let data = Data(buffer.prefix(n))
				DispatchQueue.main.async { [weak self] in
					self?.onRemoteOutput?(data)
				}
			case 0:
				return
			default:
				if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
					return
				}
				return
			}
		}
	}

	private func handleProcessExit() {
		guard childPID > 0 else { return }
		var status: Int32 = 0
		let pid = waitpid(childPID, &status, 0)
		guard pid == childPID else { return }

		let wasDisconnecting = isDisconnecting
		let runtimeMs = UInt64(max(0, Date().timeIntervalSince(startDate)) * 1000)
		let reason: CloseReason
		if wasDisconnecting {
			reason = .localDisconnect
		} else {
			reason = .cleanExit
		}

		teardown(sendSignal: false)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			print("[LocalShell] exited runtimeMs=\(runtimeMs) reason=\(reason)")
			self.onClose?(reason)
		}
	}

	private func applyPendingResize() {
		guard masterFD >= 0 else { return }
		var winsize = winsize(
			ws_row: UInt16(max(pendingTerminalSize.rows, 1)),
			ws_col: UInt16(max(pendingTerminalSize.columns, 1)),
			ws_xpixel: UInt16(max(pendingTerminalSize.pixelWidth, 0)),
			ws_ypixel: UInt16(max(pendingTerminalSize.pixelHeight, 0))
		)
		_ = ioctl(masterFD, TIOCSWINSZ, &winsize)
	}

	private func teardown(sendSignal _: Bool) {
		readSource?.cancel()
		readSource = nil
		processSource?.cancel()
		processSource = nil
		if masterFD >= 0 {
			close(masterFD)
			masterFD = -1
		}
		childPID = 0
		isDisconnecting = false
	}
}
#endif
