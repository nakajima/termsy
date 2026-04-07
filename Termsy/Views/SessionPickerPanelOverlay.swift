//
//  SessionPickerPanelOverlay.swift
//  Termsy
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionPickerPanelOverlay: View {
	@Environment(ViewCoordinator.self) private var coordinator
	@Environment(\.appTheme) private var theme

	var body: some View {
		GeometryReader { proxy in
			let panelWidth = min(max(proxy.size.width * 0.33, 280), 400)

			ZStack(alignment: .trailing) {
				Color.clear
					.ignoresSafeArea()
					.contentShape(Rectangle())
					.onTapGesture {
						coordinator.isShowingSessionPicker = false
					}

				SessionPickerView()
					.frame(width: panelWidth)
					.frame(maxHeight: .infinity)
					.background(theme.background)
					.shadow(color: .black.opacity(0.2), radius: 16, x: -4, y: 0)
			}
		}
		.ignoresSafeArea()
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true
		)
		try session.save(db)
	}

	let coordinator = ViewCoordinator()
	coordinator.isShowingSessionPicker = true

	return ZStack(alignment: .trailing) {
		TerminalTheme.mocha.appTheme.background.ignoresSafeArea()
		SessionPickerPanelOverlay()
	}
	.databaseContext(.readWrite { db.queue })
	.environment(coordinator)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
