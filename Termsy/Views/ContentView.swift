//
//  ContentView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/2/26.
//

import GRDB
import GRDBQuery
import SwiftUI
#if os(macOS)
	import AppKit
#endif

struct ContentView: View {
	let launchConfiguration: AppLaunchConfiguration

	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) private var dbContext
	@Environment(\.appTheme) private var theme
	@Environment(\.scenePhase) private var scenePhase
	@State private var didAutoconnect = false

	var body: some View {
		@Bindable var coordinator = coordinator
		Group {
			if coordinator.tabs.isEmpty {
				NavigationStack(path: $coordinator.path) {
					SessionListView()
						.toolbar {
							ToolbarItem(placement: .termsyPrimaryAction) {
								Button {
									coordinator.openSettings()
								} label: {
									Label("Settings", systemImage: "gearshape")
								}
								.keyboardShortcut(",", modifiers: .command)
							}
						}
						.termsyNavigationBarAppearance(theme)
				}
			} else {
				ZStack(alignment: .top) {
					theme.background.ignoresSafeArea()
					TerminalContainer()
						.padding(.top, 44)
					TabBarRepresentable()
						.frame(height: 44)
				}
			}
		}
		.background(theme.background.ignoresSafeArea())
		.overlay(alignment: .topLeading) {
			if !coordinator.tabs.isEmpty {
				TabKeyboardShortcuts()
					.environment(coordinator)
			}
		}
		.overlay {
			if !coordinator.tabs.isEmpty, coordinator.isShowingSessionPicker {
				SessionPickerPanelOverlay()
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.animation(.easeInOut(duration: 0.2), value: coordinator.isShowingSessionPicker)
		.environment(coordinator)
		.sheet(isPresented: $coordinator.isShowingConnectView) {
			NavigationStack {
				ConnectView { session in
					coordinator.openTab(for: session)
				}
				.termsyNavigationBarAppearance(theme)
			}
		}
		.sheet(isPresented: $coordinator.isShowingSettings) {
			SettingsView()
				.environment(coordinator)
		}
		#if os(macOS)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			coordinator.appDidBecomeActive()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
			coordinator.appWillResignActive()
		}
		.task {
			if NSApp.isActive {
				coordinator.appDidBecomeActive()
			} else {
				coordinator.appWillResignActive()
			}
		}
		#else
		.onChange(of: scenePhase, initial: true) { _, phase in
			switch phase {
			case .active:
				coordinator.appDidBecomeActive()
			case .background, .inactive:
				coordinator.appWillResignActive()
			@unknown default:
				break
			}
		}
		.onChange(of: coordinator.tabs.map(\.id), initial: false) { _, _ in
			persistTabOrder()
		}
		#endif
		.task {
			guard !didAutoconnect else { return }
			didAutoconnect = true

			if launchConfiguration.isScreenshotMode {
				applyScreenshotScenarioIfNeeded()
				return
			}

			let sessions = try? dbContext.reader.read { db in
				try Session.filter { $0.autoconnect == true }.fetchAll(db)
			}

			for session in orderedAutoconnectSessions(sessions ?? []) {
				coordinator.openTab(for: session)
			}
		}
	}

	private func applyScreenshotScenarioIfNeeded() {
		guard let scenario = launchConfiguration.screenshotScenario else { return }
		let seededSessions = (try? dbContext.reader.read { db in
			try Session.fetchAll(db)
		}) ?? []
		guard !seededSessions.isEmpty else { return }

		coordinator.path = NavigationPath()
		coordinator.dismissPresentedUI()
		coordinator.tabs = []
		coordinator.selectedTabID = nil

		switch scenario {
		case .savedSessions:
			announceScreenshotReadiness("saved-sessions")
		case .newSession:
			coordinator.isShowingConnectView = true
			announceScreenshotReadiness("new-session")
		case .settings:
			coordinator.isShowingSettings = true
			announceScreenshotReadiness("settings")
		case .terminal:
			openScreenshotTerminal(using: seededSessions)
		case .sessionPicker:
			openScreenshotTerminal(using: seededSessions)
			coordinator.isShowingSessionPicker = true
			announceScreenshotReadiness("session-picker")
		}
	}

	private func announceScreenshotReadiness(_ label: String) {
		guard launchConfiguration.isScreenshotMode else { return }
		print("[Screenshots] ready \(label)")
	}

	private func openScreenshotTerminal(using sessions: [Session]) {
		for session in sessions {
			coordinator.openTab(for: session)
		}
		guard let primarySession = sessions.first(where: { $0.hostname == AppStoreScreenshotFixtures.primaryHostname }) ?? sessions.first,
		      let primaryTab = coordinator.tabs.first(where: { $0.session?.normalizedTargetKey == primarySession.normalizedTargetKey })
		else { return }
		coordinator.selectTab(primaryTab.id)
		primaryTab.preparePassivePreview(transcript: AppStoreScreenshotFixtures.terminalTranscript)
	}

	private func orderedAutoconnectSessions(_ sessions: [Session]) -> [Session] {
		sessions.sorted { lhs, rhs in
			let lhsOrder = lhs.tabOrder ?? Int.max
			let rhsOrder = rhs.tabOrder ?? Int.max
			if lhsOrder != rhsOrder {
				return lhsOrder < rhsOrder
			}
			if lhs.createdAt != rhs.createdAt {
				return lhs.createdAt < rhs.createdAt
			}
			return lhs.normalizedTargetKey < rhs.normalizedTargetKey
		}
	}

	#if !os(macOS)
	private func persistTabOrder() {
		let orderedSessions = coordinator.tabs.enumerated().compactMap { index, tab -> Session? in
			guard var session = tab.session, session.id != nil else { return nil }
			session.tabOrder = index
			return session
		}
		guard !orderedSessions.isEmpty else { return }

		do {
			try dbContext.writer.write { db in
				for session in orderedSessions {
					try session.update(db)
				}
			}
		} catch {
			print("[DB] failed to persist tab order: \(error)")
		}
	}
	#endif
}

// MARK: - Terminal Container

private struct TerminalContainer: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) private var dbContext

	var body: some View {
		ZStack {
			ForEach(coordinator.tabs) { tab in
				let isSelected = tab.id == coordinator.selectedTabID
				TerminalHostRepresentable(tab: tab) { session in
					markSessionConnected(session)
				}
				.ignoresSafeArea(.container, edges: .bottom)
				.opacity(isSelected ? 1 : 0)
				.allowsHitTesting(isSelected)
				.accessibilityHidden(!isSelected)
				.zIndex(isSelected ? 1 : 0)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.accessibilityIdentifier("screen.terminal")
	}

	private func markSessionConnected(_ session: Session) {
		do {
			try dbContext.writer.write { db in
				try db.execute(
					sql: "UPDATE session SET lastConnectedAt = ? WHERE id = ?",
					arguments: [session.lastConnectedAt ?? Date(), session.id]
				)
			}
		} catch {
			print("[DB] failed to persist lastConnectedAt for \(session.username)@\(session.hostname): \(error)")
		}
	}
}

private struct TabKeyboardShortcuts: View {
	@Environment(ViewCoordinator.self) private var coordinator

	private var shortcutsEnabled: Bool {
		if coordinator.isPresentingAuxiliaryUI {
			return false
		}
		#if os(macOS)
			return true
		#else
			return !(coordinator.selectedTab?.terminalView.isFirstResponder ?? false)
		#endif
	}

	var body: some View {
		VStack(spacing: 0) {
			Button("Settings") {
				coordinator.openSettings()
			}
			.keyboardShortcut(",", modifiers: .command)
			.disabled(!shortcutsEnabled)

			Button("New Tab") {
				coordinator.openNewTabUI()
			}
			.keyboardShortcut("t", modifiers: .command)
			.disabled(!shortcutsEnabled)

			Button("Close Tab") {
				coordinator.closeTab(coordinator.selectedTabID)
			}
			.keyboardShortcut("w", modifiers: .command)
			.disabled(!shortcutsEnabled || coordinator.selectedTabID == nil)

			Button("Previous Tab") {
				coordinator.moveTabSelection(by: -1)
			}
			.keyboardShortcut("[", modifiers: [.command, .shift])
			.disabled(!shortcutsEnabled || coordinator.tabs.count < 2)

			Button("Next Tab") {
				coordinator.moveTabSelection(by: 1)
			}
			.keyboardShortcut("]", modifiers: [.command, .shift])
			.disabled(!shortcutsEnabled || coordinator.tabs.count < 2)

			ForEach(1 ... 9, id: \.self) { number in
				Button("Select Tab \(number)") {
					coordinator.selectTabNumber(number)
				}
				.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
				.disabled(!shortcutsEnabled || coordinator.tabs.count < number)
			}
		}
		.frame(width: 1, height: 1)
		.clipped()
		.opacity(0.001)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	let coordinator = ViewCoordinator()
	return ContentView(launchConfiguration: AppLaunchConfiguration(environment: [:]))
		.databaseContext(.readWrite { db.queue })
		.environment(coordinator)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
