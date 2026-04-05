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
	@State private var didAutoconnect = false

	var body: some View {
		@Bindable var coordinator = coordinator
		Group {
			if coordinator.tabs.isEmpty {
				NavigationStack(path: $coordinator.path) {
					SessionListView()
						.toolbar {
							ToolbarItem(placement: .topBarTrailing) {
								Button {
									coordinator.openSettings()
								} label: {
									Label("Settings", systemImage: "gearshape")
								}
								.keyboardShortcut(",", modifiers: .command)
							}
						}
						.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
						.toolbarBackground(.visible, for: .navigationBar)
						.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
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
		.environment(coordinator)
		.sheet(isPresented: $coordinator.isShowingConnectView) {
			NavigationStack {
				ConnectView { session in
					coordinator.openTab(for: session)
				}
				.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
				.toolbarBackground(.visible, for: .navigationBar)
				.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
			}
		}
		.inspector(isPresented: $coordinator.isShowingSessionPicker) {
			SessionPickerView()
				.inspectorColumnWidth(min: 280, ideal: 320, max: 400)
		}
		.sheet(isPresented: $coordinator.isShowingSettings) {
			SettingsView()
				.environment(coordinator)
		}
		.task {
			guard !didAutoconnect else { return }
			didAutoconnect = true

			let sessions = try? dbContext.reader.read { db in
				try Session
					.filter(Column("autoconnect") == true)
					.order(Column("lastConnectedAt").descNullsFirst)
					.fetchAll(db)
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

	var body: some View {
		ZStack {
			if let tab = coordinator.selectedTab {
				TerminalHostRepresentable(tab: tab)
					.id(tab.id)
					.ignoresSafeArea(.container, edges: .bottom)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
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
