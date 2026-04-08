//
//  SSHConnection.swift
//  Termsy
//

import Foundation
import NIOCore
import NIOFoundationCompat
@preconcurrency import NIOSSH
import NIOTransportServices

struct TerminalWindowSize: Sendable, Equatable {
	var columns: Int
	var rows: Int
	var pixelWidth: Int
	var pixelHeight: Int
}

enum SSHConnectionError: Error, LocalizedError, CustomStringConvertible {
	case notConnected
	case invalidChannelType
	case authenticationFailed
	case timedOut(String)

	var errorDescription: String? {
		switch self {
		case .notConnected: "Not connected"
		case .invalidChannelType: "Invalid SSH channel type"
		case .authenticationFailed: "Authentication failed"
		case let .timedOut(stage): "Timed out while \(stage)"
		}
	}

	var description: String {
		errorDescription ?? "SSH connection error"
	}
}

final nonisolated class SSHConnection: @unchecked Sendable {
	enum CloseReason: Sendable {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	private static let sessionStartupTimeout: TimeAmount = .seconds(10)
	private static let channelRequestTimeout: TimeAmount = .seconds(10)

	private let group = NIOTSEventLoopGroup()
	private var channel: Channel?
	private var sshChildChannel: Channel?
	private var authDelegate: PasswordOrNoneAuthDelegate?
	private var isDisconnecting = false
	private var pendingTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)

	private let onData: @Sendable (Data) -> Void
	private let onClose: @Sendable (CloseReason) -> Void
	private let onEvent: @Sendable (String) -> Void

	var isActive: Bool {
		channel?.isActive ?? false
	}

	init(
		onData: @escaping @Sendable (Data) -> Void,
		onClose: @escaping @Sendable (CloseReason) -> Void,
		onEvent: @escaping @Sendable (String) -> Void = { _ in }
	) {
		self.onData = onData
		self.onClose = onClose
		self.onEvent = onEvent
	}

	func connect(host: String, port: Int, username: String, password: String?) async throws {
		disconnect()
		log("connecting to \(host):\(port) as \(username)")
		channel = nil
		sshChildChannel = nil
		authDelegate = nil
		isDisconnecting = false

		let authDelegate = PasswordOrNoneAuthDelegate(
			username: username,
			password: password ?? "",
			logger: { [weak self] message in self?.log(message) }
		)
		self.authDelegate = authDelegate
		let hostKeyDelegate = AcceptAllHostKeysDelegate(
			logger: { [weak self] message in self?.log(message) }
		)

		let bootstrap = NIOTSConnectionBootstrap(group: group)
			.connectTimeout(.seconds(10))
			.channelInitializer { channel in
				self.log("TCP connected, adding SSH handler")
				return channel.pipeline.addHandler(
					NIOSSHHandler(
						role: .client(.init(
							userAuthDelegate: authDelegate,
							serverAuthDelegate: hostKeyDelegate
						)),
						allocator: channel.allocator,
						inboundChildChannelInitializer: nil
					)
				)
			}

		log("bootstrap.connect...")
		channel = try await bootstrap.connect(host: host, port: port).get()
		log("connected")
	}

	func startShell(size: TerminalWindowSize) async throws {
		pendingTerminalSize = size
		log("startShell \(size.columns)x\(size.rows) px=\(size.pixelWidth)x\(size.pixelHeight)")
		guard let channel else { throw SSHConnectionError.notConnected }

		let onData = self.onData
		let onClose = self.onClose

		do {
			// All channel/pipeline operations must run on the NIO event loop.
			let authDelegate = self.authDelegate
			let childChannel: Channel = try await withTimeout(
				channel.eventLoop.flatSubmit {
					self.log("creating session channel...")
					let sshHandler = try! channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
					let promise = channel.eventLoop.makePromise(of: Channel.self)

					// If auth already failed before we got here, fail immediately.
					if authDelegate?.hasFailed == true {
						promise.fail(SSHConnectionError.authenticationFailed)
						return promise.futureResult
					}

					// If auth fails after this point, fail the promise so we don't hang.
					authDelegate?.onExhausted = {
						promise.fail(SSHConnectionError.authenticationFailed)
					}

					sshHandler.createChannel(promise) { childChannel, channelType in
						self.log("child channel init, type=\(channelType)")
						guard channelType == .session else {
							return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
						}
						return childChannel.pipeline.addHandlers([
							SSHChannelDataHandler(onData: onData),
							SSHChannelLifecycleHandler(
								isDisconnecting: { [weak self] in self?.isDisconnecting ?? false },
								onClose: { [weak self] reason in
									self?.sshChildChannel = nil
									self?.channel = nil
									self?.authDelegate = nil
									onClose(reason)
								}
							),
						])
					}
					return promise.futureResult
				},
				on: channel.eventLoop,
				timeout: Self.sessionStartupTimeout,
				error: .timedOut("establishing the SSH session")
			).get()

			sshChildChannel = childChannel
			log("session channel open")

			// Request PTY
			let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
				wantReply: true,
				term: "xterm-256color",
				terminalCharacterWidth: size.columns,
				terminalRowHeight: size.rows,
				terminalPixelWidth: size.pixelWidth,
				terminalPixelHeight: size.pixelHeight,
				terminalModes: .init([:])
			)
			try await withTimeout(
				childChannel.triggerUserOutboundEvent(ptyReq),
				on: childChannel.eventLoop,
				timeout: Self.channelRequestTimeout,
				error: .timedOut("allocating a remote PTY")
			).get()
			log("PTY allocated")

			// Request shell
			let shellReq = SSHChannelRequestEvent.ShellRequest(wantReply: true)
			try await withTimeout(
				childChannel.triggerUserOutboundEvent(shellReq),
				on: childChannel.eventLoop,
				timeout: Self.channelRequestTimeout,
				error: .timedOut("starting the remote shell")
			).get()
			log("shell started")
			resize(pendingTerminalSize)
		} catch {
			disconnect()
			throw error
		}
	}

	func send(_ data: Data) {
		guard let sshChildChannel, sshChildChannel.isActive else { return }
		sshChildChannel.eventLoop.execute {
			guard sshChildChannel.isActive else { return }
			var buffer = sshChildChannel.allocator.buffer(capacity: data.count)
			buffer.writeBytes(data)
			let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
			sshChildChannel.writeAndFlush(channelData, promise: nil)
		}
	}

	func resize(_ size: TerminalWindowSize) {
		let previousSize = pendingTerminalSize
		pendingTerminalSize = size
		// Re-sending the same character grid can make remote TUIs redraw on tab switches.
		guard size.columns != previousSize.columns || size.rows != previousSize.rows else { return }
		guard let sshChildChannel, sshChildChannel.isActive else { return }
		sshChildChannel.eventLoop.execute {
			guard sshChildChannel.isActive else { return }
			let req = SSHChannelRequestEvent.WindowChangeRequest(
				terminalCharacterWidth: size.columns,
				terminalRowHeight: size.rows,
				terminalPixelWidth: size.pixelWidth,
				terminalPixelHeight: size.pixelHeight
			)
			sshChildChannel.triggerUserOutboundEvent(req, promise: nil)
		}
	}

	private func withTimeout<T>(
		_ future: EventLoopFuture<T>,
		on eventLoop: EventLoop,
		timeout: TimeAmount,
		error: SSHConnectionError
	) -> EventLoopFuture<T> {
		let promise = eventLoop.makePromise(of: T.self)
		var isComplete = false
		let timeoutTask = eventLoop.scheduleTask(in: timeout) {
			guard !isComplete else { return }
			isComplete = true
			promise.fail(error)
		}

		future.whenComplete { result in
			guard !isComplete else { return }
			isComplete = true
			timeoutTask.cancel()
			switch result {
			case let .success(value):
				promise.succeed(value)
			case let .failure(error):
				promise.fail(error)
			}
		}

		return promise.futureResult
	}

	private func log(_ message: String) {
		print("[SSH] \(message)")
		onEvent(message)
	}

	func disconnect() {
		isDisconnecting = true
		let childChannel = sshChildChannel
		let parentChannel = channel
		sshChildChannel = nil
		channel = nil
		authDelegate = nil
		childChannel?.close(mode: .all, promise: nil)
		parentChannel?.close(mode: .all, promise: nil)
	}

	deinit {
		disconnect()
		group.shutdownGracefully(queue: .global(qos: .utility)) { [onEvent] error in
			if let error {
				print("[SSH] failed to shut down event loop group: \(error)")
				onEvent("failed to shut down event loop group: \(error)")
			}
		}
	}
}

// MARK: - Auth Delegates

private final nonisolated class PasswordOrNoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
	private let username: String
	private let password: String
	private let logger: @Sendable (String) -> Void
	private var attemptedNone = false
	private var attemptedPassword = false
	var hasFailed = false
	var onExhausted: (() -> Void)?

	init(username: String, password: String, logger: @escaping @Sendable (String) -> Void) {
		self.username = username
		self.password = password
		self.logger = logger
	}

	func nextAuthenticationType(
		availableMethods: NIOSSHAvailableUserAuthenticationMethods,
		nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
	) {
		logger("auth callback: available=\(availableMethods) attemptedNone=\(attemptedNone) attemptedPassword=\(attemptedPassword)")

		// Always try "none" first — Tailscale SSH accepts this
		// when the client is an authorized tailnet node.
		if !attemptedNone {
			attemptedNone = true
			logger("trying none auth")
			nextChallengePromise.succeed(.init(
				username: username,
				serviceName: "",
				offer: .none
			))
			return
		}

		// Fall back to password if available
		if !attemptedPassword, !password.isEmpty, availableMethods.contains(.password) {
			attemptedPassword = true
			logger("trying password auth")
			nextChallengePromise.succeed(.init(
				username: username,
				serviceName: "",
				offer: .password(.init(password: password))
			))
			return
		}

		// No more methods
		logger("no more auth methods, failing")
		hasFailed = true
		onExhausted?()
		onExhausted = nil
		nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
	}
}

private final nonisolated class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
	private let logger: @Sendable (String) -> Void

	init(logger: @escaping @Sendable (String) -> Void) {
		self.logger = logger
	}

	func validateHostKey(
		hostKey: NIOSSHPublicKey,
		validationCompletePromise: EventLoopPromise<Void>
	) {
		logger("accepting host key: \(hostKey)")
		validationCompletePromise.succeed(())
	}
}

// MARK: - Channel Handlers

private final nonisolated class SSHChannelDataHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	let onData: @Sendable (Data) -> Void

	init(onData: @escaping @Sendable (Data) -> Void) {
		self.onData = onData
	}

	func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
		let channelData = unwrapInboundIn(data)
		guard case var .byteBuffer(buffer) = channelData.data,
		      let bytes = buffer.readData(length: buffer.readableBytes)
		else {
			return
		}
		onData(bytes)
	}
}

private final nonisolated class SSHChannelLifecycleHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	let isDisconnecting: @Sendable () -> Bool
	let onClose: @Sendable (SSHConnection.CloseReason) -> Void

	private var exitStatus: Int?
	private var exitSignal: SSHChannelRequestEvent.ExitSignal?
	private var caughtError: Error?

	init(
		isDisconnecting: @escaping @Sendable () -> Bool,
		onClose: @escaping @Sendable (SSHConnection.CloseReason) -> Void
	) {
		self.isDisconnecting = isDisconnecting
		self.onClose = onClose
	}

	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		switch event {
		case let event as SSHChannelRequestEvent.ExitStatus:
			exitStatus = event.exitStatus
		case let event as SSHChannelRequestEvent.ExitSignal:
			exitSignal = event
		default:
			break
		}
		context.fireUserInboundEventTriggered(event)
	}

	func errorCaught(context: ChannelHandlerContext, error: any Error) {
		caughtError = error
		context.fireErrorCaught(error)
	}

	func channelInactive(context: ChannelHandlerContext) {
		let reason: SSHConnection.CloseReason
		if isDisconnecting() {
			reason = .localDisconnect
		} else if let exitSignal {
			let message = exitSignal.errorMessage.isEmpty
				? "Shell terminated by signal \(exitSignal.signalName)"
				: "Shell terminated by signal \(exitSignal.signalName): \(exitSignal.errorMessage)"
			reason = .error(message)
		} else if let exitStatus {
			reason = exitStatus == 0 ? .cleanExit : .error("Shell exited with status \(exitStatus)")
		} else if let caughtError {
			reason = .error(String(describing: caughtError))
		} else {
			reason = .error("Connection closed unexpectedly")
		}

		onClose(reason)
		context.fireChannelInactive()
	}
}
