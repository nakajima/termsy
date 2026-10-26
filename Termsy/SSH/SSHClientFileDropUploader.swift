//
//  SSHClientFileDropUploader.swift
//  Termsy
//
//  Uploads dropped files through an `ssh` client the user started in a local shell,
//  by re-running that client with the same options and destination.
//

#if os(macOS)
	import Darwin
	import Foundation

	/// An interactive `ssh` client invocation: options plus a destination, with no remote command.
	struct SSHClientInvocation: Equatable {
		let executablePath: String
		let options: [String]
		let destination: String
		let environment: [String: String]

		private static let flagsWithValues = Set("BbcDEeFIiJLlmOoPpQRSWw")
		private static let nonInteractiveFlags = Set("fGNOQsVW")

		/// `arguments` is the full argv, including argv[0].
		init?(executablePath: String, arguments: [String], environment: [String: String] = [:]) {
			guard URL(fileURLWithPath: executablePath).lastPathComponent == "ssh" else { return nil }

			var options: [String] = []
			var destination: String?
			var optionsTerminated = false
			var index = 1
			while index < arguments.count {
				let argument = arguments[index]
				index += 1
				if !optionsTerminated, argument == "--" {
					optionsTerminated = true
					continue
				}
				guard !optionsTerminated, argument.count > 1, argument.hasPrefix("-") else {
					// A second positional argument is a remote command, so there is no shell to drop into.
					guard destination == nil else { return nil }
					destination = argument
					continue
				}

				options.append(argument)
				let flags = Array(argument.dropFirst())
				for (offset, flag) in flags.enumerated() {
					if Self.nonInteractiveFlags.contains(flag) { return nil }
					guard Self.flagsWithValues.contains(flag) else { continue }
					if offset == flags.count - 1 {
						guard index < arguments.count else { return nil }
						options.append(arguments[index])
						index += 1
					}
					break
				}
			}

			guard let destination else { return nil }
			self.executablePath = executablePath
			self.options = options
			self.destination = destination
			self.environment = environment
		}

		func arguments(forRemoteCommand command: String) -> [String] {
			// BatchMode comes first because ssh keeps the first value it sees for an option.
			// -T comes last so it overrides any -t, keeping binary stdin away from a remote pty.
			["-o", "BatchMode=yes"] + options + ["-T", "--", destination, command]
		}
	}

	struct SSHClientFileDropUploader {
		let invocation: SSHClientInvocation

		func prepareFileDropDirectory(dropID: String) async throws -> String {
			let result = try await run(TerminalFileDropSupport.fileDropDirectoryCommand(dropID: dropID), inputURL: nil) { _ in }
			return try TerminalFileDropSupport.remoteDirectory(from: result)
		}

		func uploadFileForDrop(
			localURL: URL,
			remoteDirectory: String,
			remoteFileName: String,
			posixPermissions: Int,
			onProgress: @escaping @Sendable (Int64) -> Void
		) async throws -> String {
			let command = TerminalFileDropSupport.fileUploadCommand(
				remoteDirectory: remoteDirectory,
				remoteFileName: remoteFileName,
				posixPermissions: posixPermissions
			)
			let result = try await run(command, inputURL: localURL, onProgress: onProgress)
			return try TerminalFileDropSupport.uploadedRemotePath(from: result)
		}

		private func run(
			_ command: String,
			inputURL: URL?,
			onProgress: @escaping @Sendable (Int64) -> Void
		) async throws -> SSHCommandResult {
			let executablePath = invocation.executablePath
			let arguments = invocation.arguments(forRemoteCommand: command)
			let environment = invocation.environment
			return try await withCheckedThrowingContinuation { continuation in
				DispatchQueue.global(qos: .utility).async {
					continuation.resume(with: Result {
						try Self.runProcess(
							executablePath: executablePath,
							arguments: arguments,
							environment: environment,
							inputURL: inputURL,
							onProgress: onProgress
						)
					})
				}
			}
		}

		private final class OutputBuffer: @unchecked Sendable {
			var data = Data()
		}

		private nonisolated static func runProcess(
			executablePath: String,
			arguments: [String],
			environment: [String: String],
			inputURL: URL?,
			onProgress: @Sendable (Int64) -> Void
		) throws -> SSHCommandResult {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: executablePath)
			process.arguments = arguments
			if !environment.isEmpty {
				process.environment = environment
			}
			// Merge stderr into stdout, matching how detached SSH channel output is collected.
			let outputPipe = Pipe()
			process.standardOutput = outputPipe
			process.standardError = outputPipe
			let inputPipe = inputURL.map { _ in Pipe() }
			process.standardInput = inputPipe ?? FileHandle.nullDevice
			try process.run()

			let output = OutputBuffer()
			let outputFinished = DispatchSemaphore(value: 0)
			let outputReader = outputPipe.fileHandleForReading
			DispatchQueue.global(qos: .utility).async {
				output.data = outputReader.readDataToEndOfFile()
				outputFinished.signal()
			}

			var inputError: Error?
			if let inputURL, let writer = inputPipe?.fileHandleForWriting {
				// Report EPIPE instead of crashing if ssh exits before reading all input.
				_ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
				do {
					try streamFile(at: inputURL, to: writer, onProgress: onProgress)
				} catch {
					inputError = error
				}
				try? writer.close()
			}

			outputFinished.wait()
			process.waitUntilExit()

			let exited = process.terminationReason == .exit
			let result = SSHCommandResult(
				output: String(decoding: output.data, as: UTF8.self),
				exitStatus: exited ? Int(process.terminationStatus) : nil,
				exitSignal: exited ? nil : "signal \(process.terminationStatus)"
			)
			// A failed exit explains itself through its output. A clean exit after a
			// local read error means the remote file is truncated.
			if let inputError, result.exitStatus == 0 {
				throw TerminalFileDropError.fileAccess("Could not read dropped file \(inputURL?.lastPathComponent ?? ""): \(inputError.localizedDescription)")
			}
			return result
		}

		private nonisolated static func streamFile(
			at url: URL,
			to writer: FileHandle,
			onProgress: @Sendable (Int64) -> Void
		) throws {
			let reader = try FileHandle(forReadingFrom: url)
			defer { try? reader.close() }
			var sentBytes: Int64 = 0
			while let data = try reader.read(upToCount: TerminalFileDropSupport.uploadChunkSize), !data.isEmpty {
				try writer.write(contentsOf: data)
				sentBytes += Int64(data.count)
				onProgress(sentBytes)
			}
		}
	}
#endif
