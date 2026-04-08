//
//  DB.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//
import Foundation
import GRDB

struct DB {
	let queue: DatabaseQueue

	static func memory() -> DB {
		try! DB(queue: DatabaseQueue(path: ":memory:"))
	}

	static func path(_ path: String) -> DB {
		let db = try! DB(queue: DatabaseQueue(path: path))
		try! db.migrate()
		return db
	}

	func migrate() throws {
		var migrator = DatabaseMigrator()

		migrator.registerMigration("CreateSession") { db in
			try db.create(table: "session") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("hostname", .text).notNull()
				t.column("username", .text).notNull()
				t.column("port", .integer).defaults(to: 22).notNull()
				t.column("autoconnect", .boolean).notNull().defaults(to: true)
				t.column("tmuxSessionName", .text)
				t.column("createdAt", .datetime).notNull()
				t.column("lastConnectedAt", .datetime)
			}
		}

		migrator.registerMigration("AddSessionSyncFields") { db in
			try db.alter(table: "session") { t in
				t.add(column: "uuid", .text)
				t.add(column: "updatedAt", .datetime)
				t.add(column: "deletedAt", .datetime)
			}

			let rows = try Row.fetchAll(db, sql: "SELECT id, createdAt FROM session")
			for row in rows {
				let id: Int64 = row["id"]
				let createdAt: Date = row["createdAt"]
				try db.execute(
					sql: "UPDATE session SET uuid = ?, updatedAt = ? WHERE id = ?",
					arguments: [UUID().uuidString.lowercased(), createdAt, id]
				)
			}

			try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS session_uuid_idx ON session(uuid)")
			try db.execute(sql: "CREATE INDEX IF NOT EXISTS session_deleted_at_idx ON session(deletedAt)")
			try db.execute(sql: "CREATE INDEX IF NOT EXISTS session_updated_at_idx ON session(updatedAt)")
		}

		migrator.registerMigration("SoftDeleteExactDuplicateSessions") { db in
			try Session.mergeExactDuplicates(in: db)
		}

		try migrator.migrate(queue)
	}
}
