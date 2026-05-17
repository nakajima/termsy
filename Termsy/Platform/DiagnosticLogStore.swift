//
//  DiagnosticLogStore.swift
//  Termsy
//

import Foundation

final class DiagnosticLogStore: @unchecked Sendable {
	static let shared = DiagnosticLogStore()

	let fileURL: URL

	private let queue = DispatchQueue(label: "app.Termsy.diagnostic-log")
	private let fileManager: FileManager
	private let launchID = UUID().uuidString.prefix(8)
	private let maxFileBytes = 512 * 1024
	private let trimToFileBytes = 384 * 1024
	private let displayLimitBytes = 160 * 1024
	private let dateFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	private init(fileManager: FileManager = .default) {
		self.fileManager = fileManager
		let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? fileManager.temporaryDirectory
		let directoryURL = baseURL.appendingPathComponent("Diagnostics", isDirectory: true)
		self.fileURL = directoryURL.appendingPathComponent("termys-diagnostics.log", isDirectory: false)
		try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		ensureFileExists()
	}

	func record(_ event: String, metadata: [String: Any?] = [:]) {
		queue.async { [self] in
			append(event: event, metadata: metadata)
		}
	}

	func readDisplayText() -> String {
		queue.sync { [self] in
			ensureFileExists()
			guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return "No diagnostics recorded yet." }
			let isTruncated = data.count > displayLimitBytes
			let displayData = isTruncated ? Data(data.suffix(displayLimitBytes)) : data
			let text = String(data: displayData, encoding: .utf8) ?? "Unable to decode diagnostic log."
			if isTruncated {
				return "Showing the latest \(displayLimitBytes / 1024) KB. Use Share Log for the full file.\n\n" + text
			}
			return text
		}
	}

	func clear() {
		queue.sync { [self] in
			try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? Data().write(to: fileURL, options: .atomic)
			append(event: "diagnostics.clear", metadata: [:])
		}
	}

	func ensureShareableFile() -> URL {
		queue.sync { [self] in
			ensureFileExists()
			return fileURL
		}
	}

	private func append(event: String, metadata: [String: Any?]) {
		ensureFileExists()
		trimIfNeeded()
		let timestamp = dateFormatter.string(from: Date())
		let metadataText = Self.formatMetadata(metadata)
		let line = "\(timestamp) launch=\(launchID) event=\(event)\(metadataText)\n"
		guard let data = line.data(using: .utf8) else { return }
		guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
		handle.seekToEndOfFile()
		handle.write(data)
		try? handle.close()
	}

	private func ensureFileExists() {
		try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard !fileManager.fileExists(atPath: fileURL.path) else { return }
		fileManager.createFile(atPath: fileURL.path, contents: nil)
	}

	private func trimIfNeeded() {
		guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
		      let size = attributes[.size] as? NSNumber,
		      size.intValue > maxFileBytes,
		      let data = try? Data(contentsOf: fileURL)
		else {
			return
		}

		let trimmedData = Data(data.suffix(trimToFileBytes))
		let marker = "\n--- diagnostic log trimmed to latest \(trimToFileBytes / 1024) KB ---\n"
		let markerData = marker.data(using: .utf8) ?? Data()
		try? (markerData + trimmedData).write(to: fileURL, options: .atomic)
	}

	private static func formatMetadata(_ metadata: [String: Any?]) -> String {
		guard !metadata.isEmpty else { return "" }
		let pairs = metadata.keys.sorted().map { key in
			let value = metadata[key] ?? nil
			return "\(key)=\(formatValue(value))"
		}
		return " " + pairs.joined(separator: " ")
	}

	private static func formatValue(_ value: Any?) -> String {
		guard let value else { return "nil" }
		let raw = String(describing: value)
		let escaped = raw
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\r")
		if escaped.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !escaped.isEmpty {
			return escaped
		}
		return "\"\(escaped)\""
	}
}
