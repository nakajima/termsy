//
//  TermsyTests.swift
//  TermsyTests
//
//  Created by Pat Nakajima on 4/2/26.
//

import Foundation
import GRDB
import GRDBQuery
#if canImport(UIKit)
	import UIKit
#endif
@testable import Termsy
import Testing

@Suite(.serialized)
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
	@Test func prepareForReconnectAfterBackgroundLossResetsTerminalView() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		let oldView = tab.terminalView

		tab.prepareForReconnectAfterBackgroundLoss()

		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
		#expect(!tab.showsRestoringProgress)
		#expect(tab.terminalView !== oldView)
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

	#if canImport(UIKit)
		@Test func terminalTabNavigationUsesHardwareBracketPresses() {
			#expect(TerminalView.tabNavigationOffset(
				keyCode: .keyboardOpenBracket,
				modifierFlags: [.command, .shift],
				characters: "{",
				charactersIgnoringModifiers: "["
			) == -1)
			#expect(TerminalView.tabNavigationOffset(
				keyCode: .keyboardCloseBracket,
				modifierFlags: [.command, .shift],
				characters: "}",
				charactersIgnoringModifiers: "]"
			) == 1)
			#expect(TerminalView.tabNavigationOffset(
				keyCode: .keyboardOpenBracket,
				modifierFlags: .command,
				characters: "[",
				charactersIgnoringModifiers: "["
			) == nil)
			#expect(TerminalView.tabNavigationOffset(
				keyCode: .keyboardOpenBracket,
				modifierFlags: [.command, .shift, .control],
				characters: "{",
				charactersIgnoringModifiers: "["
			) == nil)
		}
	#endif

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

	@MainActor
	@Test func startupTmuxTabTitleIgnoresPromptDirectoryTitle() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)

		tab.reportedTitle = "~"

		#expect(tab.automaticTitle == "prod.example.com#api")
		#expect(tab.displayTitle == "prod.example.com#api")
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

	@Test func sessionInitialWorkingDirectoryPersists() throws {
		let db = DB.memory()
		try db.migrate()

		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			initialWorkingDirectory: "~/src/termsy",
			port: 22,
			autoconnect: false
		)

		try db.queue.write { database in
			try session.save(database)
			let savedSession = try Session.fetchOne(database, key: session.id)
			#expect(savedSession?.initialWorkingDirectory == "~/src/termsy")
		}
	}

	#if canImport(UIKit)
		@MainActor
		@Test func restoredOpenSessionLoadsPersistedSnapshot() throws {
			let db = DB.memory()
			try db.migrate()
			let snapshotData = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
				UIColor.systemGreen.setFill()
				context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
			}.jpegData(compressionQuality: 0.8)
			#expect(snapshotData != nil)

			var session = Session(
				hostname: "prod.example.com",
				username: "pat",
				tmuxSessionName: nil,
				port: 22,
				autoconnect: false
			)
			session.isOpen = true
			session.lastTerminalSnapshotJPEGData = snapshotData

			try db.queue.write { database in
				try session.save(database)
			}

			let restoredSession = try db.queue.read { database in
				try Session.fetchOne(database, key: session.id)
			}
			let tab = try TerminalTab(session: #require(restoredSession))
			#expect(tab.isRestoring)
			#expect(tab.restorationMode == .launch)
			#expect(tab.showsRestoringProgress)
			#expect(tab.displaySnapshot != nil)
		}
	#endif

	@MainActor
	@Test func appWillResignActiveDoesNotClearSavedWorkspace() throws {
		let db = DB.memory()
		try db.migrate()
		let coordinator = ViewCoordinator()
		coordinator.configureDatabaseContext(.readWrite { db.queue })

		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		session.isOpen = true
		session.tabOrder = 0
		try db.queue.write { database in
			try session.save(database)
		}

		coordinator.appWillResignActive()

		let savedSession = try db.queue.read { database in
			try Session.fetchOne(database, key: session.id)
		}
		#expect(savedSession?.isOpen == true)
		#expect(savedSession?.tabOrder == 0)
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

	@Test func shellTitleStateParserStripsInternalActivityPrefixes() {
		let promptTitle = ShellTitleState.parse("__TERMSY_TITLE_PROMPT__:~/src/app")
		#expect(promptTitle.title == "~/src/app")
		#expect(promptTitle.activityState == .prompt)

		let commandTitle = ShellTitleState.parse("__TERMSY_TITLE_COMMAND__:vim README.md")
		#expect(commandTitle.title == "vim README.md")
		#expect(commandTitle.activityState == .command)

		let normalTitle = ShellTitleState.parse("manual title")
		#expect(normalTitle.title == "manual title")
		#expect(normalTitle.activityState == nil)
	}

	@Test func remoteStartupCommandDoesNotRunBootstrapShellAsLoginShell() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: nil, initialWorkingDirectory: nil)

		#expect(command.hasPrefix("/bin/sh -c "))
		#expect(!command.hasPrefix("/bin/sh -lc "))
	}

	@Test func remoteStartupCommandIncludesInitialWorkingDirectory() {
		let command = ShellTitleIntegration.remoteStartupCommand(
			tmuxSessionName: "api",
			initialWorkingDirectory: "~/src/app"
		)

		#expect(command.contains("TERMSY_INITIAL_WORKING_DIRECTORY"))
		#expect(command.contains("~/src/app"))
		#expect(command.contains("termsy_initial_working_directory=\"$HOME/${termsy_initial_working_directory#~/}\""))
		#expect(command.contains("export TERMSY_TMUX_START_DIRECTORY=\"$PWD\""))
		#expect(command.contains("export TERMSY_TMUX_START_DIRECTORY=\"$termsy_initial_working_directory\""))
	}

	@Test func remoteStartupTmuxUsesInitialWorkingDirectoryAsStartDirectory() {
		let command = ShellTitleIntegration.remoteStartupCommand(
			tmuxSessionName: "api",
			initialWorkingDirectory: "~/src/app"
		)

		#expect(
			command.contains("__termsy_tmux_attach_or_create \"$__termsy_tmux_session\" \"$__termsy_tmux_start_directory\"")
		)
		#expect(command.contains("set -l start_directory"))
		#expect(command.contains("local start_directory=${TERMSY_TMUX_START_DIRECTORY-}"))
		#expect(command.contains("tmux new-session -d -s \"$session\" -c \"$start_directory\""))
		#expect(command.contains("__termsy_tmux_attach_or_create \"$session\" \"$start_directory\""))
		#expect(command.contains("_termsy_tmux_attach_or_create() {"))
		#expect(command.contains("unset TERMSY_STARTUP_TMUX_SESSION TERMSY_TMUX_START_DIRECTORY"))
	}

	@Test func remoteStartupCommandExpandsInternalTemplatePlaceholders() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: nil, initialWorkingDirectory: nil)

		#expect(!command.contains("__TERMSY_BOOTSTRAP_ENVIRONMENT__"))
		#expect(!command.contains("__TERMSY_GHOSTTY_TERMINFO_SOURCE__"))
		#expect(!command.contains("__TERMSY_BASH_SCRIPT__"))
		#expect(!command.contains("__TERMSY_FISH_SCRIPT__"))
		#expect(!command.contains("__TERMSY_ZSH_ENV_SCRIPT__"))
		#expect(!command.contains("__TERMSY_ZSH_PROFILE_SCRIPT__"))
		#expect(!command.contains("__TERMSY_ZSH_RC_SCRIPT__"))
		#expect(!command.contains("__TERMSY_ZSH_LOGIN_SCRIPT__"))
		#expect(!command.contains("__TERMSY_ZSH_INTEGRATION_SCRIPT__"))
	}

	@Test func remoteStartupCommandFailsOpenWhenIntegrationPreparationFails() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: nil, initialWorkingDirectory: nil)

		#expect(command.contains("termsy_exec_user_shell()"))
		#expect(command.contains("failed to prepare bash integration; starting normal shell"))
		#expect(command.contains("failed to prepare fish integration; starting normal shell"))
		#expect(command.contains("failed to prepare zsh integration; starting normal shell"))
	}

	@Test func remoteStartupCommandWritesFullZshStartupWrapperChain() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: nil, initialWorkingDirectory: nil)

		#expect(command.contains("cat >\"$zsh_dir/.zshenv\""))
		#expect(command.contains("cat >\"$zsh_dir/.zprofile\""))
		#expect(command.contains("cat >\"$zsh_dir/.zshrc\""))
		#expect(command.contains("cat >\"$zsh_dir/.zlogin\""))
		#expect(command.contains("cat >\"$zsh_dir/termsy-title.zsh\""))
		#expect(command.contains("builtin typeset _termsy_file=\"$_termsy_user_zdotdir/.zshrc\""))
	}

	@Test func remoteStartupCommandValidatesShellBeforeUsingIt() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: nil, initialWorkingDirectory: nil)

		#expect(command.contains("passwd_shell=$(termsy_passwd_shell || true)"))
		#expect(command.contains("if [ -z \"$shell_path\" ] || [ ! -x \"$shell_path\" ]; then"))
		#expect(command.contains("shell_path=/bin/sh"))
		#expect(command.contains("export SHELL=\"$shell_path\""))
	}

	@Test func remoteStartupTmuxPreparesSessionShellForNewWindows() {
		let command = ShellTitleIntegration.remoteStartupCommand(tmuxSessionName: "api", initialWorkingDirectory: nil)

		#expect(command.contains("tmux set-option -q -t \"$session\" default-shell \"$SHELL\""))
		#expect(command.contains("tmux set-environment -t \"$session\" SHELL \"$SHELL\""))
		#expect(command.contains("tmux set-environment -rt \"$session\" ZDOTDIR"))
		#expect(command.contains("exec tmux attach-session -t \"$session\""))
		#expect(!command.contains("TERMSY_TMUX_SHELL_COMMAND"))
	}

	@Test func tmuxStartupRequiresBootstrapCommandInsteadOfPlainShellFallback() {
		#expect(SSHTerminalSession.startupFallbackPolicy(tmuxSessionName: "api") == .requireStartupCommand)
		#expect(SSHTerminalSession.startupFallbackPolicy(tmuxSessionName: "  api  ") == .requireStartupCommand)
		#expect(SSHTerminalSession.startupFallbackPolicy(tmuxSessionName: nil) == .plainShellOnBootstrapFailure)
		#expect(SSHTerminalSession.startupFallbackPolicy(tmuxSessionName: "   ") == .plainShellOnBootstrapFailure)
	}

	@Test func directSessionTargetParsesWorkingDirectoryTmuxAndDashPort() throws {
		let target = try #require(DirectSessionTarget("fresh@example.com:pwd#work -2222"))

		#expect(target.username == "fresh")
		#expect(target.hostname == "example.com")
		#expect(target.initialWorkingDirectory == "pwd")
		#expect(target.tmuxSessionName == "work")
		#expect(target.port == 2222)
	}

	@Test func directSessionTargetParsesPortFlagForms() throws {
		let spacedPort = try #require(DirectSessionTarget("pat@example.com:src#api -p 2200"))
		let compactPort = try #require(DirectSessionTarget("pat@example.com:src#api -p2201"))

		#expect(spacedPort.initialWorkingDirectory == "src")
		#expect(spacedPort.tmuxSessionName == "api")
		#expect(spacedPort.port == 2200)
		#expect(compactPort.port == 2201)
	}

	@Test func directSessionTargetKeepsLegacyColonPortSupport() throws {
		let target = try #require(DirectSessionTarget("pat@example.com:2022#ops"))

		#expect(target.hostname == "example.com")
		#expect(target.initialWorkingDirectory == nil)
		#expect(target.tmuxSessionName == "ops")
		#expect(target.port == 2022)
	}

	@Test func directSessionTargetRejectsInvalidPort() {
		#expect(DirectSessionTarget("pat@example.com:src -70000") == nil)
		#expect(DirectSessionTarget("pat@example.com -p nope") == nil)
	}

	@Test func remoteTmuxSessionDiscoveryParsesSessionNames() {
		let output = "Welcome\n__TERMSY_TMUX_SESSION__=api\n__TERMSY_TMUX_SESSION__=worker\r\n" +
			"__TERMSY_TMUX_SESSION__=deploy app\n\n__TERMSY_TMUX_SESSION__=api\n  __TERMSY_TMUX_SESSION__=ops  \n"

		#expect(RemoteTmuxSessionDiscovery.parseListSessionsOutput(output) == ["api", "worker", "deploy app", "ops"])
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

	@Test func sameTargetDifferentInitialWorkingDirectoriesPersistAsSeparateSessions() throws {
		let db = DB.memory()
		try db.migrate()

		var homeSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: false
		)
		let worktreeSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			initialWorkingDirectory: "~/src/app",
			port: 22,
			autoconnect: false
		)

		try db.queue.write { database in
			try homeSession.save(database)
			#expect(try Session.existing(worktreeSession, in: database) == nil)
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
		tab.onRequestClose = { didClose = true }
		tab.isConnected = true

		ApplicationActivity.isActive = false
		defer { ApplicationActivity.isActive = true }
		tab.noteAppWillResignActive()

		tab.sshSession.onClose?(.cleanExit)

		#expect(!didClose)
		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
	}

	@MainActor
	@Test func inactiveConnectedSessionUsesBackgroundRestorationOnAppActivation() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		tab.isConnected = true

		tab.noteAppDidBecomeActive()

		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
		#expect(!tab.showsRestoringProgress)
		#expect(!tab.showsConnectingOverlay)
	}

	@MainActor
	@Test func terminalInputSendFailureUsesBackgroundRestorationReconnect() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		tab.isConnected = true
		let oldView = tab.terminalView

		tab.terminalView.onWrite?(Data("x".utf8))

		#expect(tab.connectionError == nil)
		#expect(tab.terminalView !== oldView)
		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
		#expect(!tab.showsRestoringProgress)
		#expect(!tab.showsConnectingOverlay)
	}

	@MainActor
	@Test func connectedSessionErrorReconnectUsesBackgroundRestoration() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)
		tab.isConnected = true

		ApplicationActivity.isActive = false
		defer { ApplicationActivity.isActive = true }
		tab.sshSession.onClose?(.error("connection reset"))

		#expect(tab.connectionError == nil)
		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
		#expect(!tab.showsRestoringProgress)
		#expect(!tab.showsConnectingOverlay)
	}

	@MainActor
	@Test func restoringReconnectKeepsPresentationAfterRecoverableClose() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		let tab = TerminalTab(session: session)

		tab.prepareForReconnectAfterBackgroundLoss()
		tab.sshSession.onClose?(.error("connection reset"))

		#expect(tab.connectionError == nil)
		#expect(tab.isRestoring)
		#expect(tab.restorationMode == .backgroundReconnect)
		#expect(!tab.showsConnectingOverlay)
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
		#expect(!tab.isRestoring)
	}

	@MainActor
	@Test func onConnectionEstablishedPersistsLastConnectedAtThroughCoordinator() throws {
		let db = DB.memory()
		try db.migrate()
		let coordinator = ViewCoordinator()
		coordinator.configureDatabaseContext(.readWrite { db.queue })

		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		try db.queue.write { database in
			try session.save(database)
		}

		coordinator.openTab(for: session)
		let tab = try #require(coordinator.tabs.first)

		// Simulate a connection being established
		let connectedDate = Date()
		session.lastConnectedAt = connectedDate
		tab.onConnectionEstablished?(session)

		let savedSession = try db.queue.read { database in
			try Session.fetchOne(database, key: session.id)
		}
		#expect(savedSession?.lastConnectedAt != nil)
	}

	#if canImport(UIKit)
		@MainActor
		@Test func didMoveToWindowAppliesDisplayActivitySynchronously() {
			let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

			// Mark display active before the view has a window.
			view.setDisplayActive(true)
			#expect(view.isDisplayActive)
			// Without a window, applyDisplayActivity sets isUserInteractionEnabled = false.
			#expect(!view.isUserInteractionEnabled)

			// Add the view to a window. didMoveToWindow() should synchronously call
			// applyDisplayActivity(), enabling interaction immediately without waiting
			// for the next runloop pass.
			let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
			window.addSubview(view)

			#expect(view.isUserInteractionEnabled)
		}
	#endif

	@Test func sessionTrimmedOptionalStripsWhitespaceAndReturnsNilForEmpty() {
		let session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "  api  ",
			initialWorkingDirectory: "  ~/src  ",
			port: 22,
			autoconnect: false,
			customTitle: "  deploy  "
		)
		#expect(session.trimmedCustomTitle == "deploy")
		#expect(session.trimmedTmuxSessionName == "api")
		#expect(session.trimmedInitialWorkingDirectory == "~/src")

		let emptySession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "   ",
			initialWorkingDirectory: "",
			port: 22,
			autoconnect: false,
			customTitle: "\t\n"
		)
		#expect(emptySession.trimmedCustomTitle == nil)
		#expect(emptySession.trimmedTmuxSessionName == nil)
		#expect(emptySession.trimmedInitialWorkingDirectory == nil)

		let nilSession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: false
		)
		#expect(nilSession.trimmedCustomTitle == nil)
		#expect(nilSession.trimmedTmuxSessionName == nil)
		#expect(nilSession.trimmedInitialWorkingDirectory == nil)
	}
}
