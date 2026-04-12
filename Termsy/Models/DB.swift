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

		try migrator.migrate(queue)
	}
}
