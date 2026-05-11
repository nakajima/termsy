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
				.termsyTerminalSystemGestureBehavior()
			}
		}
		.background(theme.background.ignoresSafeArea())
		.overlay(alignment: .topLeading) {
			if !coordinator.tabs.isEmpty {
				TabKeyboardShortcuts()
					.environment(coordinator)
			}
		}
		.environment(coordinator)
		.onAppear {
			coordinator.configureDatabaseContext(dbContext)
		}
		.sheet(isPresented: $coordinator.isShowingSessionPicker) {
			SessionPickerView()
				.environment(coordinator)
		}
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
					case .inactive:
						coordinator.appWillResignActive()
					case .background:
						coordinator.appDidEnterBackground()
					@unknown default:
						break
					}
				}
		#endif
				.task {
					guard !didAutoconnect else { return }
					didAutoconnect = true

					if launchConfiguration.isScreenshotMode {
						applyScreenshotScenarioIfNeeded()
						return
					}

					coordinator.configureDatabaseContext(dbContext)
					coordinator.restoreSavedWorkspace()
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
			openScreenshotTerminal(using: seededSessions, readinessLabel: "terminal")
		case .backgroundReconnect:
			openScreenshotBackgroundReconnect(using: seededSessions, readinessLabel: "background-reconnect")
		case .sessionPicker:
			openScreenshotTerminal(using: seededSessions, readinessLabel: "session-picker")
			coordinator.isShowingSessionPicker = true
		}
	}

	private func announceScreenshotReadiness(_ label: String) {
		guard launchConfiguration.isScreenshotMode else { return }
		print("[Screenshots] ready \(label)")
	}

	private func openScreenshotTerminal(using sessions: [Session], readinessLabel: String) {
		guard let primarySession = sessions.first(where: { $0.hostname == AppStoreScreenshotFixtures.primaryHostname }) ?? sessions.first else {
			return
		}

		let usesInteractiveTerminal = launchConfiguration.usesInteractiveTerminalForUITests
		for session in sessions {
			coordinator.openTab(for: session)
			guard !usesInteractiveTerminal,
			      session.normalizedTargetKey != primarySession.normalizedTargetKey,
			      let tab = coordinator.tabs.first(where: { $0.session?.normalizedTargetKey == session.normalizedTargetKey })
			else {
				continue
			}
			tab.preparePassivePreview(transcript: "")
		}

		guard let primaryTab = coordinator.tabs.first(where: { $0.session?.normalizedTargetKey == primarySession.normalizedTargetKey }) else {
			return
		}
		if usesInteractiveTerminal {
			announceScreenshotReadiness(readinessLabel)
		} else {
			primaryTab.terminalView.setPresentationMode(.passivePreview)
			primaryTab.onFirstRemoteOutput = {
				announceScreenshotReadiness(readinessLabel)
			}
		}
		coordinator.selectTab(primaryTab.id)
		if launchConfiguration.startsTerminalRecording {
			coordinator.startRecording(tabID: primaryTab.id)
		}
	}

	private func openScreenshotBackgroundReconnect(using sessions: [Session], readinessLabel: String) {
		guard let primarySession = sessions.first(where: { $0.hostname == AppStoreScreenshotFixtures.primaryHostname }) ?? sessions.first else {
			return
		}

		coordinator.openPassivePreviewTab(
			for: primarySession,
			transcript: AppStoreScreenshotFixtures.terminalTranscript
		)
		guard let primaryTab = coordinator.tabs.first(where: { $0.session?.normalizedTargetKey == primarySession.normalizedTargetKey }) else {
			return
		}
		coordinator.selectTab(primaryTab.id)
		#if canImport(UIKit)
			primaryTab.prepareScreenshotBackgroundReconnect(readinessLabel: readinessLabel)
		#else
			announceScreenshotReadiness(readinessLabel)
		#endif
	}
}

// MARK: - Terminal Container

private struct TerminalContainer: View {
	@Environment(ViewCoordinator.self) var coordinator

	var body: some View {
		ZStack {
			ForEach(coordinator.tabs) { tab in
				let isSelected = tab.id == coordinator.selectedTabID
				TerminalHostRepresentable(tab: tab)
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
