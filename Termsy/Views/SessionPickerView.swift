//
//  SessionPickerView.swift
//  Termsy
//
//  Shown in an inspector when tapping + in the tab bar.
//  Lists saved sessions to quickly open, plus a "New Session" option.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionPickerView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) var sessions: [Session]

	var body: some View {
		NavigationStack {
			List {
				if !sessions.isEmpty {
					Section("Saved Sessions") {
						ForEach(sessions) { session in
							let isOpen = coordinator.tabs.contains { $0.session.id == session.id }

							Button {
								coordinator.openTab(for: session)
								coordinator.isShowingSessionPicker = false
							} label: {
								HStack {
									VStack(alignment: .leading, spacing: 2) {
										Text("\(session.username)@\(session.hostname)")
											.font(.body)
											.foregroundStyle(theme.primaryText)
										if let tmux = session.tmuxSessionName, !tmux.isEmpty {
											Text("tmux • \(tmux)")
												.font(.caption)
												.foregroundStyle(theme.secondaryText)
										}
									}
									Spacer()
									if isOpen {
										Text("Open")
											.font(.caption)
											.foregroundStyle(theme.secondaryText)
									}
								}
							}
							.listRowBackground(theme.cardBackground)
						}
						.onDelete { index in
							let session = sessions[index.first!]
							_ = try? dbContext.writer.write { try session.delete($0) }
						}
					}
				}

				Section {
					Button {
						coordinator.isShowingSessionPicker = false
						coordinator.isShowingConnectView = true
					} label: {
						Label("New Session", systemImage: "plus.circle")
							.font(.body)
							.foregroundStyle(.tint)
					}
					.listRowBackground(theme.cardBackground)
				}
			}
			.scrollContentBackground(.hidden)
			.background(theme.background)
			.navigationTitle("Sessions")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") {
						coordinator.isShowingSessionPicker = false
					}
				}
			}
			.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
		}
	}
}
