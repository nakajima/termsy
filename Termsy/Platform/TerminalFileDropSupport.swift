import Foundation
import UniformTypeIdentifiers

struct TerminalFileDropBatch: Identifiable, Equatable {
	let id: String
	let urls: [URL]
	/// Holds copies of dropped files that only existed for the duration of the drop.
	let stagingDirectory: URL?

	init(urls: [URL], stagingDirectory: URL? = nil, id: String = TerminalFileDropSupport.makeDropID()) {
		self.id = id
		self.urls = urls
		self.stagingDirectory = stagingDirectory
	}

	func removeStagedFiles() {
		guard let stagingDirectory else { return }
		try? FileManager.default.removeItem(at: stagingDirectory)
	}
}

struct TerminalSSHUploadFile {
	let sourceURL: URL
	let displayName: String
	let remoteFileName: String
	let byteCount: Int64
	let posixPermissions: Int
}

struct TerminalPreparedSSHFileDropBatch {
	let files: [TerminalSSHUploadFile]
	private let securityScopedURLs: [URL]

	nonisolated init(files: [TerminalSSHUploadFile], securityScopedURLs: [URL]) {
		self.files = files
		self.securityScopedURLs = securityScopedURLs
	}

	func stopAccessingSecurityScopedResources() {
		for url in securityScopedURLs {
			url.stopAccessingSecurityScopedResource()
		}
	}
}

struct TerminalFileDropOverlayState: Equatable {
	enum Phase: Equatable {
		case idle
		case uploading
		case error(String)
	}

	var phase: Phase = .idle
	var activeFileCount = 0
	var queuedBatchCount = 0
	var completedBytes: Int64 = 0
	var totalBytes: Int64 = 0
	var currentFileName: String?

	static let idle = TerminalFileDropOverlayState()

	static func uploading(
		activeFileCount: Int,
		queuedBatchCount: Int,
		completedBytes: Int64,
		totalBytes: Int64,
		currentFileName: String?
	) -> TerminalFileDropOverlayState {
		TerminalFileDropOverlayState(
			phase: .uploading,
			activeFileCount: activeFileCount,
			queuedBatchCount: queuedBatchCount,
			completedBytes: max(completedBytes, 0),
			totalBytes: max(totalBytes, 0),
			currentFileName: currentFileName
		)
	}

	static func error(_ message: String) -> TerminalFileDropOverlayState {
		TerminalFileDropOverlayState(phase: .error(message))
	}

	var isPresented: Bool {
		switch phase {
		case .idle:
			false
		case .uploading, .error:
			true
		}
	}

	var blocksInput: Bool { isPresented }

	var errorMessage: String? {
		if case let .error(message) = phase { return message }
		return nil
	}

	var isUploading: Bool {
		if case .uploading = phase { return true }
		return false
	}

	var progressFraction: Double? {
		guard isUploading else { return nil }
		guard totalBytes > 0 else { return 1 }
		return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
	}
}

enum TerminalFileDropError: LocalizedError {
	case noFileURLs
	case unsupportedItem(String)
	case fileAccess(String)
	case notConnected
	case invalidRemoteResponse(String)
	case uploadFailed(String)

	var errorDescription: String? {
		switch self {
		case .noFileURLs:
			return "Drop contains no file URLs."
		case let .unsupportedItem(name):
			return "Unsupported dropped item: \(name). SSH drops support regular files only."
		case let .fileAccess(message):
			return message
		case .notConnected:
			return "SSH session is not connected."
		case let .invalidRemoteResponse(message):
			return "Invalid remote upload response: \(message)"
		case let .uploadFailed(message):
			return message
		}
	}
}

enum TerminalFileDropSupport {
	nonisolated static func makeDropID() -> String {
		UUID().uuidString.lowercased()
	}

	nonisolated static func shellQuote(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	nonisolated static func shellQuotedArgumentList(_ paths: [String]) -> String {
		guard !paths.isEmpty else { return "" }
		return paths.map(shellQuote).joined(separator: " ") + " "
	}

	/// Whether a dragged item is a file rather than, say, selected text. Apps like Files
	/// register in-place file representations instead of a `public.file-url` item.
	nonisolated static func itemProviderIsFile(_ provider: NSItemProvider) -> Bool {
		provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
			|| !provider.registeredTypeIdentifiers(fileOptions: [.openInPlace]).isEmpty
	}

	nonisolated static func makeStagingDirectory() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("termsy-file-drops", isDirectory: true)
			.appendingPathComponent(makeDropID(), isDirectory: true)
	}

	/// Copies a dropped file into `stagingDirectory`, since the source URL may vanish
	/// once the item provider's completion handler returns.
	nonisolated static func stageDroppedFile(at sourceURL: URL, preferredName: String?, in stagingDirectory: URL) throws -> URL {
		let name = sanitizedRemoteFileName(preferredName?.isEmpty == false ? preferredName! : sourceURL.lastPathComponent)
		let itemDirectory = stagingDirectory.appendingPathComponent(makeDropID(), isDirectory: true)
		try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
		let destinationURL = itemDirectory.appendingPathComponent(name, isDirectory: false)
		let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
		defer {
			if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
		}
		try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
		return destinationURL
	}

	nonisolated static func localShellInsertText(for urls: [URL]) throws -> String {
		let fileURLs = urls.filter(\.isFileURL)
		guard !fileURLs.isEmpty else { throw TerminalFileDropError.noFileURLs }
		return shellQuotedArgumentList(fileURLs.map(\.path))
	}

	nonisolated static func prepareSSHUploadBatch(urls: [URL]) throws -> TerminalPreparedSSHFileDropBatch {
		let fileURLs = urls.filter(\.isFileURL)
		guard fileURLs.count == urls.count, !fileURLs.isEmpty else {
			throw TerminalFileDropError.noFileURLs
		}

		var securityScopedURLs: [URL] = []
		var uploadFiles: [TerminalSSHUploadFile] = []

		do {
			for url in fileURLs {
				if url.startAccessingSecurityScopedResource() {
					securityScopedURLs.append(url)
				}

				let attributes = try regularFileAttributes(for: url)
				let displayName = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
				let byteCount = fileSize(from: attributes)
				let mode = posixPermissions(from: attributes) ?? 0o600
				uploadFiles.append(
					TerminalSSHUploadFile(
						sourceURL: url,
						displayName: displayName,
						remoteFileName: "",
						byteCount: byteCount,
						posixPermissions: mode
					)
				)
			}
		} catch {
			for url in securityScopedURLs {
				url.stopAccessingSecurityScopedResource()
			}
			throw error
		}

		let remoteNames = uniquedRemoteFileNames(for: uploadFiles.map(\.displayName))
		let namedFiles = zip(uploadFiles, remoteNames).map { file, remoteName in
			TerminalSSHUploadFile(
				sourceURL: file.sourceURL,
				displayName: file.displayName,
				remoteFileName: remoteName,
				byteCount: file.byteCount,
				posixPermissions: file.posixPermissions
			)
		}

		return TerminalPreparedSSHFileDropBatch(files: namedFiles, securityScopedURLs: securityScopedURLs)
	}

	nonisolated static func sanitizedRemoteFileName(_ name: String) -> String {
		let sanitizedScalars = name.unicodeScalars.map { scalar -> String in
			if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2F {
				return "_"
			}
			return String(scalar)
		}
		let sanitized = sanitizedScalars.joined()
		if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
			return "file"
		}
		return sanitized
	}

	nonisolated static func chmodModeString(_ mode: Int) -> String {
		String(mode & 0o7777, radix: 8)
	}

	nonisolated static let uploadChunkSize = 256 * 1024

	nonisolated static func remoteDirectory(from result: SSHCommandResult) throws -> String {
		guard result.exitStatus == 0, result.exitSignal == nil else {
			throw TerminalFileDropError.uploadFailed(commandFailureMessage(result, fallback: "Could not create remote upload directory."))
		}
		guard let directory = parseTaggedOutput(result.output, tag: "__TERMSY_DROP_DIR__") else {
			throw TerminalFileDropError.invalidRemoteResponse(result.output)
		}
		return directory
	}

	nonisolated static func uploadedRemotePath(from result: SSHCommandResult) throws -> String {
		guard result.exitStatus == 0, result.exitSignal == nil else {
			throw TerminalFileDropError.uploadFailed(commandFailureMessage(result, fallback: "Remote upload failed."))
		}
		guard let remotePath = parseTaggedOutput(result.output, tag: "__TERMSY_UPLOAD_PATH__") else {
			throw TerminalFileDropError.invalidRemoteResponse(result.output)
		}
		return remotePath
	}

	nonisolated static func fileDropDirectoryCommand(dropID: String) -> String {
		let safeDropID = dropID.filter { character in
			character.isLetter || character.isNumber || character == "-" || character == "_"
		}
		let directoryName = safeDropID.isEmpty ? makeDropID() : safeDropID
		let quotedDirectoryName = TerminalFileDropSupport.shellQuote(directoryName)
		let script = #"""
		set -eu
		uid="$(id -u 2>/dev/null || true)"
		user="${USER:-}"
		if [ -z "$user" ]; then
		  user="$(id -un 2>/dev/null || printf 'user')"
		fi
		try_root() {
		  root="$1"
		  [ -n "$root" ] || return 1
		  mkdir -p "$root" 2>/dev/null || return 1
		  chmod 700 "$root" 2>/dev/null || return 1
		  if [ -n "$uid" ]; then
		    owner="$(stat -c '%u' "$root" 2>/dev/null || stat -f '%u' "$root" 2>/dev/null || true)"
		    if [ -n "$owner" ] && [ "$owner" != "$uid" ]; then
		      return 1
		    fi
		  fi
		  [ -d "$root" ] && [ -r "$root" ] && [ -w "$root" ] && [ -x "$root" ] || return 1
		  return 0
		}
		root=""
		if try_root /tmp/termsy; then
		  root=/tmp/termsy
		elif [ -n "$uid" ] && try_root "/tmp/termsy-$uid"; then
		  root="/tmp/termsy-$uid"
		elif try_root "/tmp/termsy-$user"; then
		  root="/tmp/termsy-$user"
		else
		  printf 'Termsy: could not create a writable private upload directory under /tmp\n' >&2
		  exit 1
		fi
		drop_dir="$root"/__TERMSY_DROP_NAME__
		mkdir "$drop_dir"
		chmod 700 "$drop_dir"
		printf '__TERMSY_DROP_DIR__=%s\n' "$drop_dir"
		"""#.replacingOccurrences(of: "__TERMSY_DROP_NAME__", with: quotedDirectoryName)
		return "/bin/sh -c \(TerminalFileDropSupport.shellQuote(script))"
	}

	nonisolated static func fileUploadCommand(
		remoteDirectory: String,
		remoteFileName: String,
		posixPermissions: Int
	) -> String {
		let tempName = ".\(remoteFileName).termsy-upload-\(makeDropID()).tmp"
		let mode = TerminalFileDropSupport.chmodModeString(posixPermissions)
		let script = #"""
		set -eu
		dir=__TERMSY_REMOTE_DIR__
		name=__TERMSY_REMOTE_NAME__
		tmp_name=__TERMSY_TMP_NAME__
		mode=__TERMSY_MODE__
		final="$dir/$name"
		tmp="$dir/$tmp_name"
		trap 'rm -f "$tmp"' HUP INT TERM EXIT
		cat > "$tmp"
		chmod "$mode" "$tmp"
		mv -f "$tmp" "$final"
		trap - HUP INT TERM EXIT
		printf '__TERMSY_UPLOAD_PATH__=%s\n' "$final"
		"""#
		let filled = script
			.replacingOccurrences(of: "__TERMSY_REMOTE_DIR__", with: TerminalFileDropSupport.shellQuote(remoteDirectory))
			.replacingOccurrences(of: "__TERMSY_REMOTE_NAME__", with: TerminalFileDropSupport.shellQuote(remoteFileName))
			.replacingOccurrences(of: "__TERMSY_TMP_NAME__", with: TerminalFileDropSupport.shellQuote(tempName))
			.replacingOccurrences(of: "__TERMSY_MODE__", with: TerminalFileDropSupport.shellQuote(mode))
		return "/bin/sh -c \(TerminalFileDropSupport.shellQuote(filled))"
	}

	private nonisolated static func parseTaggedOutput(_ output: String, tag: String) -> String? {
		for line in output.components(separatedBy: .newlines) {
			guard line.hasPrefix(tag + "=") else { continue }
			return String(line.dropFirst(tag.count + 1))
		}
		return nil
	}

	private nonisolated static func commandFailureMessage(_ result: SSHCommandResult, fallback: String) -> String {
		let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmedOutput.isEmpty {
			return trimmedOutput
		}
		if let exitSignal = result.exitSignal {
			return "\(fallback) Remote command terminated by signal \(exitSignal)."
		}
		if let exitStatus = result.exitStatus {
			return "\(fallback) Remote command exited with status \(exitStatus)."
		}
		return fallback
	}

	private nonisolated static func regularFileAttributes(for url: URL) throws -> [FileAttributeKey: Any] {
		let resolvedURL = url.resolvingSymlinksInPath()
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
		} catch {
			throw TerminalFileDropError.fileAccess("Could not read dropped file \(url.lastPathComponent): \(error.localizedDescription)")
		}

		guard attributes[.type] as? FileAttributeType == .typeRegular else {
			throw TerminalFileDropError.unsupportedItem(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
		}
		return attributes
	}

	private nonisolated static func fileSize(from attributes: [FileAttributeKey: Any]) -> Int64 {
		if let value = attributes[.size] as? NSNumber {
			return value.int64Value
		}
		if let value = attributes[.size] as? Int64 {
			return value
		}
		if let value = attributes[.size] as? Int {
			return Int64(value)
		}
		return 0
	}

	private nonisolated static func posixPermissions(from attributes: [FileAttributeKey: Any]) -> Int? {
		if let value = attributes[.posixPermissions] as? NSNumber {
			return value.intValue
		}
		return attributes[.posixPermissions] as? Int
	}

	private nonisolated static func uniquedRemoteFileNames(for names: [String]) -> [String] {
		var seen: [String: Int] = [:]
		return names.map { name in
			let sanitized = sanitizedRemoteFileName(name)
			let nextCount = (seen[sanitized] ?? 0) + 1
			seen[sanitized] = nextCount
			guard nextCount > 1 else { return sanitized }
			return remoteFileName(sanitized, duplicateIndex: nextCount)
		}
	}

	private nonisolated static func remoteFileName(_ name: String, duplicateIndex: Int) -> String {
		let nsName = name as NSString
		let ext = nsName.pathExtension
		let base = nsName.deletingPathExtension
		let suffix = "-\(duplicateIndex)"
		guard !ext.isEmpty else { return base + suffix }
		return base + suffix + "." + ext
	}
}
