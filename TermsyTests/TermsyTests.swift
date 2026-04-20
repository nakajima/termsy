//
//  TermsyTests.swift
//  TermsyTests
//
//  Created by Pat Nakajima on 4/2/26.
//

import Foundation
import GRDB
import GRDBQuery
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

	@Test func sessionWorkspaceStatePersists() throws {
		let db = DB.memory()
		try db.migrate()

		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		session.tabOrder = 2
		session.isOpen = true

		try db.queue.write { database in
			try session.save(database)
			let savedSession = try Session.fetchOne(database, key: session.id)
			#expect(savedSession?.tabOrder == 2)
			#expect(savedSession?.isOpen == true)
		}
	}

	@MainActor
	@Test func coordinatorPersistsWorkspaceStateForOpenTabs() throws {
		let db = DB.memory()
		try db.migrate()
		let coordinator = ViewCoordinator()
		coordinator.configureDatabaseContext(.readWrite { db.queue })

		var firstSession = Session(
			hostname: "one.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		var secondSession = Session(
			hostname: "two.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		try db.queue.write { database in
			try firstSession.save(database)
			try secondSession.save(database)
		}

		coordinator.openTab(for: firstSession)
		coordinator.openTab(for: secondSession)
		coordinator.selectTab(coordinator.tabs.first?.id)

		let persistedSessions = try db.queue.read { database in
			try Session.order(Session.Columns.id).fetchAll(database)
		}
		#expect(persistedSessions[0].isOpen)
		#expect(persistedSessions[0].tabOrder == 0)
		#expect(persistedSessions[1].isOpen)
		#expect(persistedSessions[1].tabOrder == 1)
	}

	@MainActor
	@Test func coordinatorRestoresSavedWorkspaceInPersistedOrder() throws {
		let db = DB.memory()
		try db.migrate()
		let coordinator = ViewCoordinator()
		coordinator.configureDatabaseContext(.readWrite { db.queue })
		let selectedSessionIDKey = "workspace.selectedSessionID"
		UserDefaults.standard.removeObject(forKey: selectedSessionIDKey)
		defer {
			UserDefaults.standard.removeObject(forKey: selectedSessionIDKey)
		}

		var firstSession = Session(
			hostname: "one.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		firstSession.tabOrder = 1
		firstSession.isOpen = true
		var secondSession = Session(
			hostname: "two.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		secondSession.tabOrder = 0
		secondSession.isOpen = true
		try db.queue.write { database in
			try firstSession.save(database)
			try secondSession.save(database)
		}
		UserDefaults.standard.set(NSNumber(value: firstSession.id!), forKey: selectedSessionIDKey)

		coordinator.restoreSavedWorkspace()

		#expect(coordinator.tabs.count == 2)
		#expect(coordinator.tabs[0].session?.id == secondSession.id)
		#expect(coordinator.tabs[1].session?.id == firstSession.id)
		#expect(coordinator.selectedTab?.session?.id == firstSession.id)
	}

	@Test func tmuxNameIsPrimarySavedSessionTitle() {
		let sessionWithTmux = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: false,
			customTitle: "Production"
		)
		#expect(sessionWithTmux.listTitle == "api")
		#expect(sessionWithTmux.listSubtitle == "pat@prod.example.com")
	}

	@Test func savedSessionsAreOrderedByMostRecentConnection() throws {
		let db = DB.memory()
		try db.migrate()

		var newestConnected = Session(
			hostname: "new.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		newestConnected.createdAt = Date(timeIntervalSince1970: 100)
		newestConnected.lastConnectedAt = Date(timeIntervalSince1970: 300)

		var olderConnected = Session(
			hostname: "old.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		olderConnected.createdAt = Date(timeIntervalSince1970: 200)
		olderConnected.lastConnectedAt = Date(timeIntervalSince1970: 250)

		var neverConnected = Session(
			hostname: "draft.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		neverConnected.createdAt = Date(timeIntervalSince1970: 400)

		try db.queue.write { database in
			try olderConnected.save(database)
			try neverConnected.save(database)
			try newestConnected.save(database)
		}

		let sessions = try db.queue.read { database in
			try Session.fetchSavedSessions(database)
		}
		#expect(sessions.map(\.hostname) == ["new.example.com", "old.example.com", "draft.example.com"])
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

	@MainActor
	@Test func cleanSSHExitWhileBackgroundedSchedulesReconnectInsteadOfClosingTab() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		var didClose = false
		var didRequestReconnect = false
		tab.onRequestClose = { didClose = true }
		tab.onRequestReconnect = { didRequestReconnect = true }
		tab.isConnected = true

		ApplicationActivity.isActive = false
		defer { ApplicationActivity.isActive = true }
		tab.noteAppWillResignActive()

		tab.sshSession.onClose?(.cleanExit)

		#expect(!didClose)
		#expect(!didRequestReconnect)
		#expect(tab.consumeReconnectOnActivation())
	}

	@MainActor
	@Test func cleanSSHExitWhileActiveStillClosesTab() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		var didClose = false
		tab.onRequestClose = { didClose = true }
		tab.isConnected = true

		ApplicationActivity.isActive = true
		tab.sshSession.onClose?(.cleanExit)

		#expect(didClose)
		#expect(!tab.consumeReconnectOnActivation())
	}
}
