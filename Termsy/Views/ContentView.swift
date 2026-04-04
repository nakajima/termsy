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
				}
			} else {
				TerminalTabBarRepresentable()
			}
		}
		.environment(coordinator)
		.sheet(isPresented: $coordinator.isShowingConnectView) {
			NavigationStack {
				ConnectView { session in
					coordinator.openTab(for: session)
				}
			}
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

#Preview {
	ContentView()
}
