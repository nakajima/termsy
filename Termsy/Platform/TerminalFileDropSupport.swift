import Foundation

struct TerminalFileDropBatch: Identifiable, Equatable {
	let id: String
	let urls: [URL]

	init(urls: [URL], id: String = TerminalFileDropSupport.makeDropID()) {
		self.id = id
		self.urls = urls
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
