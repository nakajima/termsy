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
	var uuid: String
	var hostname: String
	var username: String
	var tmuxSessionName: String?
	var autoconnect: Bool = true
	var port: Int = 22
	var createdAt: Date
	var updatedAt: Date
	var deletedAt: Date?
	var lastConnectedAt: Date?

	static let databaseTableName = "session"
}

extension Session {
	init(hostname: String, username: String, tmuxSessionName: String?, port: Int, autoconnect: Bool) {
		let now = Date()
		self.id = nil
		self.uuid = UUID().uuidString.lowercased()
		self.hostname = hostname
		self.username = username
		self.tmuxSessionName = tmuxSessionName
		self.port = port
		self.autoconnect = autoconnect
		self.createdAt = now
		self.updatedAt = now
		self.deletedAt = nil
		self.lastConnectedAt = nil
		normalizeConnectionTarget()
	}

	var isDeleted: Bool {
		deletedAt != nil
	}

	var normalizedHostname: String {
		Self.normalized(hostname, lowercased: true)
	}

	var normalizedUsername: String {
		Self.normalized(username, lowercased: true)
	}

	var normalizedTmuxSessionName: String? {
		Self.normalizedOptional(tmuxSessionName, lowercased: false)
	}

	var normalizedTargetKey: String {
		"\(normalizedUsername)@\(normalizedHostname):\(port)#\(normalizedTmuxSessionName ?? "")"
	}

	mutating func normalizeConnectionTarget() {
		hostname = Self.normalized(hostname, lowercased: false)
		username = Self.normalized(username, lowercased: false)
		tmuxSessionName = Self.normalizedOptional(tmuxSessionName, lowercased: false)
	}

	mutating func touch(at date: Date = Date()) {
		updatedAt = date
	}

	mutating func markDeleted(at date: Date = Date()) {
		deletedAt = date
		updatedAt = date
	}

	mutating func applySyncedFields(from other: Session) {
		hostname = other.hostname
		username = other.username
		tmuxSessionName = other.tmuxSessionName
		port = other.port
		autoconnect = other.autoconnect
		createdAt = other.createdAt
		updatedAt = other.updatedAt
		deletedAt = other.deletedAt
		normalizeConnectionTarget()
	}

	static func activeOrdered() -> QueryInterfaceRequest<Session> {
		Session
			.filter(Column("deletedAt") == nil)
			.order(Column("lastConnectedAt").desc, Column("createdAt").desc)
	}

	static func autoconnectingOrdered() -> QueryInterfaceRequest<Session> {
		Session
			.filter(Column("deletedAt") == nil)
			.filter(Column("autoconnect") == true)
			.order(Column("lastConnectedAt").desc, Column("createdAt").desc)
	}

	static func activeExactDuplicate(of candidate: Session, in db: Database, excludingUUID: String? = nil)
		throws -> Session?
	{
		try activeSessionsMatchingTarget(candidate, in: db, excludingUUID: excludingUUID)
			.sorted(by: canonicalSort)
			.first
	}

	static func mergeExactDuplicates(
		in db: Database,
		onDuplicateMergedIntoCanonical: ((Session, Session) -> Void)? = nil
	) throws {
		let activeSessions = try Session
			.filter(Column("deletedAt") == nil)
			.fetchAll(db)

		let groups = Dictionary(grouping: activeSessions, by: \.normalizedTargetKey)
		for group in groups.values where group.count > 1 {
			let ordered = group.sorted(by: canonicalSort)
			guard var canonical = ordered.first else { continue }

			canonical.createdAt = group.map(\.createdAt).min() ?? canonical.createdAt
			canonical.updatedAt = group.map(\.updatedAt).max() ?? canonical.updatedAt
			if let latestConnectedAt = group.compactMap(\.lastConnectedAt).max() {
				canonical.lastConnectedAt = latestConnectedAt
			}
			canonical.deletedAt = nil
			try canonical.update(db)

			let mergeDate = Date()
			for duplicate in ordered.dropFirst() {
				onDuplicateMergedIntoCanonical?(duplicate, canonical)
				var tombstone = duplicate
				tombstone.markDeleted(at: mergeDate)
				try tombstone.update(db)
			}
		}
	}

	private static func activeSessionsMatchingTarget(
		_ candidate: Session,
		in db: Database,
		excludingUUID: String?
	) throws -> [Session] {
		let sessions = try Session
			.filter(Column("deletedAt") == nil)
			.fetchAll(db)

		return sessions.filter { session in
			session.uuid != excludingUUID && session.normalizedTargetKey == candidate.normalizedTargetKey
		}
	}

	private static func canonicalSort(_ lhs: Session, _ rhs: Session) -> Bool {
		if lhs.updatedAt != rhs.updatedAt {
			return lhs.updatedAt > rhs.updatedAt
		}
		if lhs.createdAt != rhs.createdAt {
			return lhs.createdAt < rhs.createdAt
		}
		return lhs.uuid < rhs.uuid
	}

	private static func normalized(_ value: String, lowercased: Bool) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return lowercased ? trimmed.lowercased() : trimmed
	}

	private static func normalizedOptional(_ value: String?, lowercased: Bool) -> String? {
		guard let value else { return nil }
		let normalized = normalized(value, lowercased: lowercased)
		return normalized.isEmpty ? nil : normalized
	}
}
