//
//  ContentView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/2/26.
//

import GRDB
import GRDBQuery
import SwiftUI

struct ContentView: View {
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
		.onChange(of: scenePhase, initial: true) { _, phase in
			switch phase {
			case .active:
				coordinator.appDidBecomeActive()
				SessionRecordSync.scheduleSync(dbContext: dbContext, reason: "app did become active")
			case .inactive, .background:
				coordinator.appWillResignActive()
			@unknown default:
				break
			}
		}
		.task {
			SessionRecordSync.scheduleSync(dbContext: dbContext, reason: "initial load")
			guard !didAutoconnect else { return }
			didAutoconnect = true

			let sessions = try? dbContext.reader.read { db in
				try Session.autoconnectingOrdered().fetchAll(db)
			}

			for session in sessions ?? [] {
				coordinator.openTab(for: session)
			}
		}
	}
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
	}

	private func markSessionConnected(_ session: Session) {
		do {
			try dbContext.writer.write { db in
				try db.execute(
					sql: "UPDATE session SET lastConnectedAt = ? WHERE uuid = ?",
					arguments: [session.lastConnectedAt ?? Date(), session.uuid]
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
		!coordinator.isPresentingAuxiliaryUI && !(coordinator.selectedTab?.terminalView.isFirstResponder ?? false)
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
	return ContentView()
		.databaseContext(.readWrite { db.queue })
		.environment(coordinator)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
