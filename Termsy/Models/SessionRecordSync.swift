//
//  SessionRecordSync.swift
//  Termsy
//

import CloudKit
import Foundation
import GRDB
import GRDBQuery

private enum SessionRecordSyncFields {
	nonisolated static let uuid = "uuid"
	nonisolated static let hostname = "hostname"
	nonisolated static let username = "username"
	nonisolated static let port = "port"
	nonisolated static let tmuxSessionName = "tmuxSessionName"
	nonisolated static let autoconnect = "autoconnect"
	nonisolated static let createdAt = "createdAt"
	nonisolated static let updatedAt = "updatedAt"
	nonisolated static let deletedAt = "deletedAt"
}

enum SessionRecordSync {
	nonisolated private static let recordType = "SessionRecord"
	nonisolated private static let container = CKContainer.default()
	@MainActor private static var syncTask: Task<Void, Never>?
	@MainActor private static var needsResync = false

	@MainActor
	static func scheduleSync(dbContext: DatabaseContext, reason: String) {
		guard syncTask == nil else {
			needsResync = true
			return
		}

		syncTask = Task { @MainActor in
			defer {
				syncTask = nil
				if needsResync {
					needsResync = false
					scheduleSync(dbContext: dbContext, reason: "coalesced")
				}
			}

			do {
				try await syncOnce(dbContext: dbContext, reason: reason)
			} catch {
				print("[Sync] session record sync failed (\(reason)): \(error)")
			}
		}
	}

	@MainActor
	private static func syncOnce(dbContext: DatabaseContext, reason: String) async throws {
		let remoteSessions = try await fetchRemoteSessions()

		try await dbContext.writer.write { db in
			try applyRemoteSessions(remoteSessions, in: db)
			try Session.mergeExactDuplicates(in: db) { duplicate, canonical in
				Keychain.movePasswordIfNeeded(from: duplicate, to: canonical)
			}
		}

		let localSessions = try await dbContext.reader.read { db in
			try Session.fetchAll(db)
		}
		try await pushLocalSessions(localSessions)
		print("[Sync] session record sync complete (\(reason)): \(localSessions.count) local rows")
	}

	nonisolated private static func applyRemoteSessions(_ remoteSessions: [Session], in db: Database) throws {
		let localSessions = try Session.fetchAll(db)
		let localByUUID = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.uuid, $0) })

		for remoteSession in remoteSessions {
			if var localSession = localByUUID[remoteSession.uuid] {
				guard shouldApplyRemote(remoteSession, over: localSession) else { continue }
				localSession.applySyncedFields(from: remoteSession)
				try localSession.update(db)
			} else {
				var inserted = remoteSession
				inserted.id = nil
				inserted.lastConnectedAt = nil
				try inserted.insert(db)
			}
		}
	}

	nonisolated private static func shouldApplyRemote(_ remote: Session, over local: Session) -> Bool {
		if remote.updatedAt != local.updatedAt {
			return remote.updatedAt > local.updatedAt
		}
		if remote.deletedAt != local.deletedAt {
			return remote.deletedAt != nil && local.deletedAt == nil
		}
		if remote.createdAt != local.createdAt {
			return remote.createdAt < local.createdAt
		}
		return false
	}

	nonisolated private static func fetchRemoteSessions() async throws -> [Session] {
		let database = container.privateCloudDatabase
		let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
		var sessions: [Session] = []
		var cursor: CKQueryOperation.Cursor?

		repeat {
			let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
				queryCursor: CKQueryOperation.Cursor?)
			if let cursor {
				page = try await database.records(continuingMatchFrom: cursor)
			} else {
				page = try await database.records(matching: query)
			}

			for (_, result) in page.matchResults {
				switch result {
				case let .success(record):
					guard let session = session(from: record) else {
						print("[Sync] skipping malformed session record: \(record.recordID.recordName)")
						continue
					}
					sessions.append(session)
				case let .failure(error):
					print("[Sync] failed to fetch remote session record: \(error)")
				}
			}

			cursor = page.queryCursor
		} while cursor != nil

		return sessions
	}

	nonisolated private static func pushLocalSessions(_ sessions: [Session]) async throws {
		guard !sessions.isEmpty else { return }

		let records = sessions.map(record(for:))
		let results = try await container.privateCloudDatabase.modifyRecords(
			saving: records,
			deleting: [],
			savePolicy: .allKeys,
			atomically: false
		)

		for (recordID, result) in results.saveResults {
			if case let .failure(error) = result {
				print("[Sync] failed to save remote session record \(recordID.recordName): \(error)")
			}
		}
	}

	nonisolated private static func record(for session: Session) -> CKRecord {
		let recordID = CKRecord.ID(recordName: session.uuid)
		let record = CKRecord(recordType: recordType, recordID: recordID)
		record[SessionRecordSyncFields.uuid] = session.uuid as CKRecordValue
		record[SessionRecordSyncFields.hostname] = session.hostname as CKRecordValue
		record[SessionRecordSyncFields.username] = session.username as CKRecordValue
		record[SessionRecordSyncFields.port] = session.port as NSNumber
		record[SessionRecordSyncFields.autoconnect] = session.autoconnect as NSNumber
		record[SessionRecordSyncFields.createdAt] = session.createdAt as NSDate
		record[SessionRecordSyncFields.updatedAt] = session.updatedAt as NSDate
		record[SessionRecordSyncFields.tmuxSessionName] = session.normalizedTmuxSessionName as NSString?
		record[SessionRecordSyncFields.deletedAt] = session.deletedAt as NSDate?
		return record
	}

	nonisolated private static func session(from record: CKRecord) -> Session? {
		guard let uuid = record[SessionRecordSyncFields.uuid] as? String,
		      let hostname = record[SessionRecordSyncFields.hostname] as? String,
		      let username = record[SessionRecordSyncFields.username] as? String,
		      let port = (record[SessionRecordSyncFields.port] as? NSNumber)?.intValue,
		      let autoconnect = (record[SessionRecordSyncFields.autoconnect] as? NSNumber)?.boolValue,
		      let createdAt = record[SessionRecordSyncFields.createdAt] as? Date,
		      let updatedAt = record[SessionRecordSyncFields.updatedAt] as? Date
		else {
			return nil
		}

		var session = Session(
			id: nil,
			uuid: uuid.lowercased(),
			hostname: hostname,
			username: username,
			tmuxSessionName: record[SessionRecordSyncFields.tmuxSessionName] as? String,
			autoconnect: autoconnect,
			port: port,
			createdAt: createdAt,
			updatedAt: updatedAt,
			deletedAt: record[SessionRecordSyncFields.deletedAt] as? Date,
			lastConnectedAt: nil
		)
		session.normalizeConnectionTarget()
		return session
	}
}
