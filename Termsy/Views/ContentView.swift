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
								SheetButton(buttonLabel: { Label("Settings", systemImage: "gearshape") }) {
									SettingsView()
										.environment(coordinator)
								}
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
		// Cmd+1–9 keyboard shortcuts
		.background {
			ForEach(Array(coordinator.tabs.enumerated()), id: \.element.id) { index, tab in
				if index < 9 {
					Button("") { coordinator.selectTab(tab.session.id) }
						.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
						.hidden()
				}
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
					.id(tab.session.id)
					.ignoresSafeArea(.container, edges: .bottom)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task(id: coordinator.selectedTab?.sshSession.isForeground) {
			if let tab = coordinator.selectedTab, tab.sshSession.isForeground {
				await tab.sshSession.replayIfNeeded()
			}
		}
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
