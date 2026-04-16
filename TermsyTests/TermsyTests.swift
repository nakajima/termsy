//
//  TermsyTests.swift
//  TermsyTests
//
//  Created by Pat Nakajima on 4/2/26.
//

import Foundation
import GRDB
@testable import Termsy
import Testing

struct TermsyTests {
	@MainActor
	@Test func resetTerminalViewPreservesDisplayActivity() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		let oldView = tab.terminalView

		tab.setDisplayActive(true)
		tab.resetTerminalView()

		#expect(tab.isDisplayActive)
		#expect(tab.terminalView !== oldView)
		#expect(tab.terminalView.isDisplayActive)
	}

	@MainActor
	@Test func moveTabSelectionWrapsAcrossOpenTabs() {
		let coordinator = ViewCoordinator()
		let sessions = [
			Session(hostname: "one.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "two.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "three.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
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

	@MainActor
	@Test func customTabTitlesOverrideAutomaticTitlesUntilReset() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)

		tab.reportedTitle = "vim"
		#expect(tab.displayTitle == "vim")

		tab.rename(to: "  deploy  ")
		#expect(tab.customTitle == "deploy")
		#expect(tab.session?.customTitle == "deploy")
		#expect(tab.displayTitle == "deploy")

		tab.reportedTitle = "htop"
		#expect(tab.displayTitle == "deploy")

		tab.rename(to: "   ")
		#expect(tab.customTitle == nil)
		#expect(tab.session?.customTitle == nil)
		#expect(tab.displayTitle == "htop")
	}

	@Test func screenshotTerminalTranscriptUsesCRLFLineEndings() {
		let transcript = AppStoreScreenshotFixtures.terminalTranscript
		let transcriptWithoutCRLF = transcript.replacingOccurrences(of: "\r\n", with: "")

		#expect(transcript.contains("\r\n"))
		#expect(!transcriptWithoutCRLF.contains("\n"))
	}

	@Test func sessionCustomTitlePersists() throws {
		let db = DB.memory()
		try db.migrate()

		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false,
			customTitle: "deploy"
		)

		try db.queue.write { database in
			try session.save(database)
			let savedSession = try Session.fetchOne(database, key: session.id)
			#expect(savedSession?.customTitle == "deploy")
		}
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
			#expect(try Session.existing(workerSession, in: database) == nil)

			try workerSession.save(database)
			let sessions = try Session.fetchAll(database)

			#expect(sessions.count == 2)
			#expect(Set(sessions.map(\.normalizedTmuxSessionName)) == Set(["api", "worker"]))
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
			let existing = try Session.existing(duplicate, in: database)
			#expect(existing?.id == original.id)
		}
	}
}
