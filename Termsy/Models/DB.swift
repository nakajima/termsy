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

		migrator.registerMigration("AddSessionCustomTitle") { db in
			try db.alter(table: "session") { t in
				t.add(column: "customTitle", .text)
			}
		}

		migrator.registerMigration("AddSessionTabOrder") { db in
			try db.alter(table: "session") { t in
				t.add(column: "tabOrder", .integer)
			}
		}

		migrator.registerMigration("AddSessionIsOpen") { db in
			try db.alter(table: "session") { t in
				t.add(column: "isOpen", .boolean).notNull().defaults(to: false)
			}
		}

		migrator.registerMigration("AddSessionLastTerminalSnapshotJPEGData") { db in
			try db.alter(table: "session") { t in
				t.add(column: "lastTerminalSnapshotJPEGData", .blob)
			}
		}

		migrator.registerMigration("AddSessionInitialWorkingDirectory") { db in
			try db.alter(table: "session") { t in
				t.add(column: "initialWorkingDirectory", .text)
			}
		}

		migrator.registerMigration("CreateTerminalRecording") { db in
			try db.create(table: "terminalRecording") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("sessionID", .integer).references("session", onDelete: .setNull)
				t.column("source", .text).notNull()
				t.column("targetDescription", .text).notNull()
				t.column("title", .text).notNull()
				t.column("startedAt", .datetime).notNull()
				t.column("endedAt", .datetime)
				t.column("initialColumns", .integer).notNull()
				t.column("initialRows", .integer).notNull()
				t.column("fileName", .text).notNull().unique()
				t.column("eventCount", .integer).notNull().defaults(to: 0)
				t.column("outputByteCount", .integer).notNull().defaults(to: 0)
				t.column("createdAt", .datetime).notNull()
			}
		}

		migrator.registerMigration("AddTerminalRecordingInputByteCount") { db in
			try db.alter(table: "terminalRecording") { t in
				t.add(column: "inputByteCount", .integer).notNull().defaults(to: 0)
			}
		}

		try migrator.migrate(queue)
	}
}
