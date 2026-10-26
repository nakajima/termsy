//
//  SSHClientFileDropTests.swift
//  TeletypeMacTests
//

import Foundation
@testable import Teletype
import Testing

@MainActor
struct SSHClientFileDropTests {
	@Test func parsesInteractiveSSHInvocations() {
		let cases: [(arguments: [String], options: [String], destination: String)] = [
			(["ssh", "host"], [], "host"),
			(["ssh", "-p", "2222", "-i", "/k", "me@host"], ["-p", "2222", "-i", "/k"], "me@host"),
			(["ssh", "-p2222", "host"], ["-p2222"], "host"),
			(["ssh", "-vAp", "2222", "host"], ["-vAp", "2222"], "host"),
			(["ssh", "host", "-p", "2222"], ["-p", "2222"], "host"),
			(["ssh", "-t", "--", "host"], ["-t"], "host"),
		]
		for testCase in cases {
			let invocation = SSHClientInvocation(executablePath: "/usr/bin/ssh", arguments: testCase.arguments)
			#expect(invocation?.options == testCase.options, "\(testCase.arguments)")
			#expect(invocation?.destination == testCase.destination, "\(testCase.arguments)")
		}
	}

	@Test func rejectsNonInteractiveOrNonSSHProcesses() {
		let rejected: [(path: String, arguments: [String])] = [
			("/usr/bin/ssh", ["ssh"]),
			("/usr/bin/ssh", ["ssh", "host", "ls"]),
			("/usr/bin/ssh", ["ssh", "host", "--", "ls"]),
			("/usr/bin/ssh", ["ssh", "-N", "-L", "8080:localhost:80", "host"]),
			("/usr/bin/ssh", ["ssh", "-W", "target:22", "jump"]),
			("/usr/bin/ssh", ["ssh", "-p"]),
			("/usr/bin/vim", ["vim", "host"]),
		]
		for testCase in rejected {
			#expect(SSHClientInvocation(executablePath: testCase.path, arguments: testCase.arguments) == nil, "\(testCase.arguments)")
		}
	}

	@Test func remoteCommandArgumentsForceBatchModeAndNoPTY() throws {
		let invocation = try #require(SSHClientInvocation(executablePath: "/usr/bin/ssh", arguments: ["ssh", "-t", "-p", "2222", "host"]))
		#expect(invocation.arguments(forRemoteCommand: "cmd") == ["-o", "BatchMode=yes", "-t", "-p", "2222", "-T", "--", "host", "cmd"])
	}

	@Test func readsProcessArgumentsAndEnvironment() throws {
		let processArguments = try #require(LocalShellSession.processArguments(for: getpid()))
		#expect(processArguments.arguments == CommandLine.arguments)
		#expect(processArguments.environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
	}

	@Test(.timeLimit(.minutes(1))) func detectsSSHInForegroundOfLocalShell() async throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		// A copy of sleep named ssh stands in for a connected client. macOS kills copied
		// system binaries at launch, so the copy is re-signed ad hoc.
		let fakeSSH = directory.appendingPathComponent("ssh")
		try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: fakeSSH.path)
		let codesign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", fakeSSH.path])
		codesign.waitUntilExit()
		try #require(codesign.terminationStatus == 0)

		let session = LocalShellSession(profile: LocalShellProfile(shellPath: "/bin/sh", workingDirectory: directory.path))
		try session.start()
		defer { session.stop() }
		#expect(session.attachedSSHInvocation == nil)

		session.send(Data("exec '\(fakeSSH.path)' 30\n".utf8))
		var invocation: SSHClientInvocation?
		for _ in 0 ..< 100 where invocation == nil {
			try await Task.sleep(for: .milliseconds(50))
			invocation = session.attachedSSHInvocation
		}
		#expect(invocation?.destination == "30")
		#expect(invocation?.options == [])
		#expect(invocation.map { URL(fileURLWithPath: $0.executablePath).lastPathComponent } == "ssh")
	}

	@Test(.timeLimit(.minutes(1))) func uploadsThroughSSHClient() async throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let uploader = try makeUploader(in: directory, script: """
		#!/bin/sh
		[ "$TERMSY_TEST_MARKER" = "yes" ] || { echo "missing environment" >&2; exit 97; }
		while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
		shift 2
		exec /bin/sh -c "$1"
		""")

		let payload = Data((0 ..< 1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
		let localURL = directory.appendingPathComponent("payload.bin")
		try payload.write(to: localURL)

		let remoteDirectory = try await uploader.prepareFileDropDirectory(dropID: TerminalFileDropSupport.makeDropID())
		defer { try? FileManager.default.removeItem(atPath: remoteDirectory) }
		let progress = ProgressRecorder()
		let remotePath = try await uploader.uploadFileForDrop(
			localURL: localURL,
			remoteDirectory: remoteDirectory,
			remoteFileName: "payload copy.bin",
			posixPermissions: 0o640,
			onProgress: { progress.record($0) }
		)

		#expect(remotePath == remoteDirectory + "/payload copy.bin")
		#expect(FileManager.default.contents(atPath: remotePath) == payload)
		let attributes = try FileManager.default.attributesOfItem(atPath: remotePath)
		#expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
		#expect(progress.last == Int64(payload.count))
	}

	@Test(.timeLimit(.minutes(1))) func reportsSSHFailureWhenClientExitsBeforeReadingInput() async throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let uploader = try makeUploader(in: directory, script: """
		#!/bin/sh
		echo "me@host: Permission denied (publickey)." >&2
		exit 255
		""")

		// Larger than a pipe buffer, so writing hits the closed pipe.
		let localURL = directory.appendingPathComponent("big.bin")
		try Data(count: 4_000_000).write(to: localURL)

		let error = await #expect(throws: TerminalFileDropError.self) {
			try await uploader.uploadFileForDrop(
				localURL: localURL,
				remoteDirectory: "/tmp/unused",
				remoteFileName: "big.bin",
				posixPermissions: 0o600,
				onProgress: { _ in }
			)
		}
		#expect(error?.localizedDescription.contains("Permission denied (publickey).") == true)
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("termsy-ssh-client-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	/// Writes `script` as an executable named ssh and returns an uploader that runs it.
	private func makeUploader(in directory: URL, script: String) throws -> SSHClientFileDropUploader {
		let fakeSSH = directory.appendingPathComponent("ssh")
		try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
		let invocation = try #require(SSHClientInvocation(
			executablePath: fakeSSH.path,
			arguments: ["ssh", "-p", "2222", "me@example.com"],
			environment: ["PATH": "/usr/bin:/bin", "TERMSY_TEST_MARKER": "yes"]
		))
		return SSHClientFileDropUploader(invocation: invocation)
	}
}

private final class ProgressRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Int64] = []

	func record(_ value: Int64) {
		lock.lock()
		values.append(value)
		lock.unlock()
	}

	var last: Int64? {
		lock.lock()
		defer { lock.unlock() }
		return values.last
	}
}
