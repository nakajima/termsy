//
//  SessionRecordSync.swift
//  Termsy
//

import GRDBQuery

enum SessionRecordSync {
	@MainActor
	static func scheduleSync(dbContext _: DatabaseContext, reason _: String) {}
}
