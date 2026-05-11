//
//  Session.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Foundation
import GRDB

struct Session: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable,
	Hashable, Sendable
{
	var id: Int64?
	var hostname: String
	var username: String
	var tmuxSessionName: String?
	var initialWorkingDirectory: String?
	var customTitle: String?
	var tabOrder: Int?
	var isOpen: Bool = false
	var lastTerminalSnapshotJPEGData: Data?
	var autoconnect: Bool = true
	var port: Int = 22
	var createdAt: Date
	var lastConnectedAt: Date?

	static let databaseTableName = "session"
}

struct SessionHostGroup: Identifiable, Equatable {
	let id: String
	let title: String
	var sessions: [Session]
}

extension Session {
	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}

	enum Columns {
		static let id = Column(CodingKeys.id)
		static let hostname = Column(CodingKeys.hostname)
		static let username = Column(CodingKeys.username)
		static let tmuxSessionName = Column(CodingKeys.tmuxSessionName)
		static let initialWorkingDirectory = Column(CodingKeys.initialWorkingDirectory)
		static let customTitle = Column(CodingKeys.customTitle)
		static let tabOrder = Column(CodingKeys.tabOrder)
		static let isOpen = Column(CodingKeys.isOpen)
		static let lastTerminalSnapshotJPEGData = Column(CodingKeys.lastTerminalSnapshotJPEGData)
		static let autoconnect = Column(CodingKeys.autoconnect)
		static let port = Column(CodingKeys.port)
		static let createdAt = Column(CodingKeys.createdAt)
		static let lastConnectedAt = Column(CodingKeys.lastConnectedAt)
	}

	init(
		hostname: String,
		username: String,
		tmuxSessionName: String?,
		initialWorkingDirectory: String? = nil,
		port: Int,
		autoconnect: Bool,
		customTitle: String? = nil,
		tabOrder: Int? = nil,
		isOpen: Bool = false
	) {
		let now = Date()
		self.id = nil
		self.hostname = hostname
		self.username = username
		self.tmuxSessionName = tmuxSessionName
		self.initialWorkingDirectory = initialWorkingDirectory
		self.customTitle = customTitle
		self.tabOrder = tabOrder
		self.isOpen = isOpen
		self.lastTerminalSnapshotJPEGData = nil
		self.port = port
		self.autoconnect = autoconnect
		self.createdAt = now
		self.lastConnectedAt = nil
	}

	static func existing(_ other: Session, in db: Database) throws -> Session? {
		try Session.fetchAll(db).first { $0.normalizedTargetKey == other.normalizedTargetKey }
	}

	static func fetchSavedSessions(_ db: Database) throws -> [Session] {
		try Session
			.order(
				Columns.lastConnectedAt.desc,
				Columns.createdAt.desc,
				Columns.id.desc
			)
			.fetchAll(db)
	}

	static func groupByHost(_ sessions: [Session]) -> [SessionHostGroup] {
		var groups: [SessionHostGroup] = []
		var indexByHost: [String: Int] = [:]

		for session in sessions {
			let hostKey = session.normalizedHostname
			if let existingIndex = indexByHost[hostKey] {
				groups[existingIndex].sessions.append(session)
			} else {
				let trimmedHostname = session.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
				groups.append(
					SessionHostGroup(
						id: hostKey,
						title: trimmedHostname.isEmpty ? session.hostname : trimmedHostname,
						sessions: [session]
					)
				)
				indexByHost[hostKey] = groups.count - 1
			}
		}

		return groups
	}

	var normalizedHostname: String {
		hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var normalizedUsername: String {
		username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var normalizedTmuxSessionName: String {
		guard let tmuxSessionName else { return "-" }
		let trimmed = tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? "-" : trimmed.lowercased()
	}

	private static func trimmedOptional(_ value: String?) -> String? {
		guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return value.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedCustomTitle: String? { Self.trimmedOptional(customTitle) }
	var trimmedTmuxSessionName: String? { Self.trimmedOptional(tmuxSessionName) }
	var trimmedInitialWorkingDirectory: String? { Self.trimmedOptional(initialWorkingDirectory) }

	var listTitle: String {
		trimmedTmuxSessionName ?? trimmedCustomTitle ?? displayTarget
	}

	var listSubtitle: String? {
		var parts: [String] = []
		if trimmedTmuxSessionName != nil || trimmedCustomTitle != nil {
			parts.append(displayTarget)
		}
		if let trimmedInitialWorkingDirectory {
			parts.append(trimmedInitialWorkingDirectory)
		}
		return parts.isEmpty ? nil : parts.joined(separator: " • ")
	}

	var displayTarget: String {
		let baseTitle = "\(username)@\(hostname)"
		guard port != 22 else { return baseTitle }
		return "\(baseTitle):\(port)"
	}

	var normalizedTargetKey: String {
		let baseKey = "\(normalizedUsername)@\(normalizedHostname):\(port)#\(normalizedTmuxSessionName)"
		guard let trimmedInitialWorkingDirectory else { return baseKey }
		return "\(baseKey)@cwd:\(trimmedInitialWorkingDirectory)"
	}
}
