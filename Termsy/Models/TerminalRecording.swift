//
//  TerminalRecording.swift
//  Termsy
//

import Foundation
import GRDB

struct TerminalRecording: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
	var id: Int64?
	var sessionID: Int64?
	var source: String
	var targetDescription: String
	var title: String
	var startedAt: Date
	var endedAt: Date?
	var initialColumns: Int
	var initialRows: Int
	var fileName: String
	var eventCount: Int
	var outputByteCount: Int64
	var inputByteCount: Int64
	var createdAt: Date

	static let databaseTableName = "terminalRecording"
}

extension TerminalRecording {
	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}

	enum Source: String, Sendable {
		case remote
		case localShell
	}

	enum Columns {
		static let id = Column(CodingKeys.id)
		static let sessionID = Column(CodingKeys.sessionID)
		static let source = Column(CodingKeys.source)
		static let targetDescription = Column(CodingKeys.targetDescription)
		static let title = Column(CodingKeys.title)
		static let startedAt = Column(CodingKeys.startedAt)
		static let endedAt = Column(CodingKeys.endedAt)
		static let initialColumns = Column(CodingKeys.initialColumns)
		static let initialRows = Column(CodingKeys.initialRows)
		static let fileName = Column(CodingKeys.fileName)
		static let eventCount = Column(CodingKeys.eventCount)
		static let outputByteCount = Column(CodingKeys.outputByteCount)
		static let inputByteCount = Column(CodingKeys.inputByteCount)
		static let createdAt = Column(CodingKeys.createdAt)
	}

	init(
		sessionID: Int64?,
		source: Source,
		targetDescription: String,
		title: String,
		startedAt: Date,
		initialColumns: Int,
		initialRows: Int,
		fileName: String
	) {
		self.id = nil
		self.sessionID = sessionID
		self.source = source.rawValue
		self.targetDescription = targetDescription
		self.title = title
		self.startedAt = startedAt
		self.endedAt = nil
		self.initialColumns = initialColumns
		self.initialRows = initialRows
		self.fileName = fileName
		self.eventCount = 0
		self.outputByteCount = 0
		self.inputByteCount = 0
		self.createdAt = startedAt
	}

	var fileURL: URL {
		TerminalRecordingStorage.fileURL(fileName: fileName)
	}

	var dataByteCount: Int64 {
		outputByteCount + inputByteCount
	}
}

enum TerminalRecordingByteCountFormatter {
	static func string(for byteCount: Int64) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		formatter.includesActualByteCount = false
		return formatter.string(fromByteCount: byteCount)
	}
}

enum TerminalRecordingStorage {
	private static let directoryName = "Recordings"

	static var directoryURL: URL {
		let fileManager = FileManager.default
		let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? fileManager.temporaryDirectory
		let appDirectory = baseDirectory.appendingPathComponent(
			Bundle.main.bundleIdentifier ?? "fm.folder.Termsy",
			isDirectory: true
		)
		return appDirectory.appendingPathComponent(directoryName, isDirectory: true)
	}

	static func ensureDirectoryExists() throws {
		try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
	}

	static func fileURL(fileName: String) -> URL {
		directoryURL.appendingPathComponent(fileName, isDirectory: false)
	}

	static func makeFileName(startedAt: Date, title: String) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let timestamp = formatter.string(from: startedAt)
		let safeTitle = sanitizedFileNameComponent(title)
		let suffix = UUID().uuidString.prefix(8).lowercased()
		return "\(timestamp)-\(safeTitle)-\(suffix).cast"
	}

	private static func sanitizedFileNameComponent(_ value: String) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		let scalars = trimmed.unicodeScalars.map { scalar -> Character in
			switch scalar.value {
			case 48 ... 57, 65 ... 90, 97 ... 122:
				Character(scalar)
			case 45, 46, 95:
				Character(scalar)
			default:
				"-"
			}
		}
		let collapsed = String(scalars)
			.split(separator: "-", omittingEmptySubsequences: true)
			.joined(separator: "-")
		let fallback = collapsed.isEmpty ? "session" : collapsed
		return String(fallback.prefix(48))
	}
}

final class TerminalSessionRecorder {
	struct Completed: Sendable {
		let recording: TerminalRecording
		let fileURL: URL
	}

	enum RecorderError: Error, LocalizedError {
		case fileAlreadyExists(URL)

		var errorDescription: String? {
			switch self {
			case let .fileAlreadyExists(url):
				"Recording file already exists: \(url.path)"
			}
		}
	}

	private let queue: DispatchQueue
	private let startedUptime: TimeInterval
	private var recording: TerminalRecording
	private var fileHandle: FileHandle?
	private var eventCount = 0
	private var outputByteCount: Int64 = 0
	private var inputByteCount: Int64 = 0
	private var isAcceptingEvents = true
	private var pendingOutputData = Data()
	private var pendingInputData = Data()
	private var lastResize: (columns: Int, rows: Int)?

	var fileURL: URL {
		recording.fileURL
	}

	init(recording: TerminalRecording) throws {
		try TerminalRecordingStorage.ensureDirectoryExists()
		let fileURL = recording.fileURL
		guard !FileManager.default.fileExists(atPath: fileURL.path) else {
			throw RecorderError.fileAlreadyExists(fileURL)
		}
		FileManager.default.createFile(atPath: fileURL.path, contents: nil)
		self.fileHandle = try FileHandle(forWritingTo: fileURL)
		self.recording = recording
		self.startedUptime = ProcessInfo.processInfo.systemUptime
		self.queue = DispatchQueue(label: "fm.folder.Termsy.TerminalSessionRecorder.\(recording.fileName)")
		self.lastResize = (recording.initialColumns, recording.initialRows)
		writeHeader()
	}

	func recordOutput(_ data: Data) {
		guard isAcceptingEvents, !data.isEmpty else { return }
		let elapsed = currentElapsedTime()
		queue.async { [weak self] in
			guard let self, self.fileHandle != nil else { return }
			self.pendingOutputData.append(data)
			self.outputByteCount += Int64(data.count)
			self.flushDecodableOutput(elapsed: elapsed, force: false)
		}
	}

	func recordInput(_ data: Data) {
		guard isAcceptingEvents, !data.isEmpty else { return }
		let elapsed = currentElapsedTime()
		queue.async { [weak self] in
			guard let self, self.fileHandle != nil else { return }
			self.pendingInputData.append(data)
			self.inputByteCount += Int64(data.count)
			self.flushDecodableInput(elapsed: elapsed, force: false)
		}
	}

	func recordResize(columns: Int, rows: Int) {
		guard isAcceptingEvents, columns > 0, rows > 0 else { return }
		if let lastResize, lastResize.columns == columns, lastResize.rows == rows {
			return
		}
		lastResize = (columns, rows)
		let elapsed = currentElapsedTime()
		queue.async { [weak self] in
			guard let self, self.fileHandle != nil else { return }
			self.flushDecodableOutput(elapsed: elapsed, force: false)
			self.flushDecodableInput(elapsed: elapsed, force: false)
			self.writeEvent(elapsed: elapsed, code: "r", data: "\(columns)x\(rows)")
			self.eventCount += 1
		}
	}

	func stop() -> Completed? {
		guard isAcceptingEvents else { return nil }
		isAcceptingEvents = false
		let endedAt = Date()
		let finalElapsed = currentElapsedTime()
		var completed: Completed?
		queue.sync {
			guard let fileHandle else { return }
			flushDecodableOutput(elapsed: finalElapsed, force: true)
			flushDecodableInput(elapsed: finalElapsed, force: true)
			fileHandle.synchronizeFile()
			fileHandle.closeFile()
			self.fileHandle = nil
			recording.endedAt = endedAt
			recording.eventCount = eventCount
			recording.outputByteCount = outputByteCount
			recording.inputByteCount = inputByteCount
			completed = Completed(recording: recording, fileURL: recording.fileURL)
		}
		return completed
	}

	private func writeHeader() {
		let header: [String: Any] = [
			"version": 2,
			"width": recording.initialColumns,
			"height": recording.initialRows,
			"timestamp": Int(recording.startedAt.timeIntervalSince1970),
			"title": recording.title,
			"env": [
				"TERM": "xterm-256color",
			],
		]
		writeJSONObjectLine(header)
	}

	private func writeEvent(elapsed: TimeInterval, code: String, data: String) {
		writeJSONObjectLine([roundedElapsed(elapsed), code, data])
	}

	private func flushDecodableOutput(elapsed: TimeInterval, force: Bool) {
		flushDecodableBytes(&pendingOutputData, elapsed: elapsed, code: "o", force: force)
	}

	private func flushDecodableInput(elapsed: TimeInterval, force: Bool) {
		flushDecodableBytes(&pendingInputData, elapsed: elapsed, code: "i", force: force)
	}

	private func flushDecodableBytes(_ pendingData: inout Data, elapsed: TimeInterval, code: String, force: Bool) {
		guard !pendingData.isEmpty else { return }
		let text: String
		if force {
			text = String(decoding: pendingData, as: UTF8.self)
			pendingData.removeAll(keepingCapacity: false)
		} else {
			guard let split = decodableUTF8Prefix(in: pendingData) else { return }
			text = split.text
			pendingData = split.remaining
		}
		guard !text.isEmpty else { return }
		writeEvent(elapsed: elapsed, code: code, data: text)
		eventCount += 1
	}

	private func decodableUTF8Prefix(in data: Data) -> (text: String, remaining: Data)? {
		let maxSuffixLength = min(3, data.count)
		for suffixLength in 0 ... maxSuffixLength {
			let prefixLength = data.count - suffixLength
			guard prefixLength > 0 else { continue }
			let prefix = data.prefix(prefixLength)
			if let text = String(data: prefix, encoding: .utf8) {
				return (text, Data(data.suffix(suffixLength)))
			}
		}

		return (String(decoding: data, as: UTF8.self), Data())
	}

	private func writeJSONObjectLine(_ object: Any) {
		guard let fileHandle else { return }
		do {
			let data = try JSONSerialization.data(withJSONObject: object, options: [])
			fileHandle.write(data)
			fileHandle.write(Data([0x0A]))
		} catch {
			print("[Recording] failed to encode event: \(error)")
		}
	}

	private func currentElapsedTime() -> TimeInterval {
		max(0, ProcessInfo.processInfo.systemUptime - startedUptime)
	}

	private func roundedElapsed(_ elapsed: TimeInterval) -> Double {
		(elapsed * 1_000_000).rounded() / 1_000_000
	}
}
