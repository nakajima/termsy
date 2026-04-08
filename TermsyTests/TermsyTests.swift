//
//  TermsyTests.swift
//  TermsyTests
//
//  Created by Pat Nakajima on 4/2/26.
//

@testable import Termsy
import GRDB
import Testing

struct TermsyTests {
	@MainActor
	@Test func moveTabSelectionWrapsAcrossOpenTabs() {
		let coordinator = ViewCoordinator()
		let sessions = [
			Session(hostname: "one.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "two.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "three.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false)
		]

		sessions.forEach { coordinator.openTab(for: $0) }
		let ids = coordinator.tabs.map(\.id)

		coordinator.selectTab(ids[1])
		coordinator.moveTabSelection(by: 1)
		#expect(coordinator.selectedTabID == ids[2])

		coordinator.moveTabSelection(by: 1)
		#expect(coordinator.selectedTabID == ids[0])

		coordinator.moveTabSelection(by: -1)
		#expect(coordinator.selectedTabID == ids[2])
	}

	@Test func sameHostDifferentTmuxNamesPersistAsSeparateSessions() throws {
		let db = DB.memory()
		try db.migrate()

		var apiSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: false
		)
		var workerSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "worker",
			port: 22,
			autoconnect: false
		)

		try db.queue.write { database in
			try apiSession.save(database)
			#expect(try Session.activeExactDuplicate(of: workerSession, in: database) == nil)

			try workerSession.save(database)
			let sessions = try Session.activeOrdered().fetchAll(database)

			#expect(sessions.count == 2)
			#expect(Set(sessions.compactMap(\.normalizedTmuxSessionName)) == Set(["api", "worker"]))
		}
	}

	@Test func exactDuplicateDetectionStillReusesMatchingTmuxSession() throws {
		let db = DB.memory()
		try db.migrate()

		var original = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: false
		)
		let duplicate = Session(
			hostname: " prod.example.com ",
			username: "PAT",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true
		)

		try db.queue.write { database in
			try original.save(database)
			let existing = try Session.activeExactDuplicate(of: duplicate, in: database)
			#expect(existing?.uuid == original.uuid)
		}
	}
}
