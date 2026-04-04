//
//  SessionListView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionsRequest: ValueObservationQueryable {
	static var defaultValue: [Session] { [] }

	func fetch(_ db: Database) throws -> [Session] {
		try Session.order(Column("lastConnectedAt").descNullsFirst).fetchAll(db)
	}
}

struct SessionListView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Query(SessionsRequest()) var sessions: [Session]

	var body: some View {
		List {
			ForEach(sessions) { session in
				Button {
					coordinator.openTab(for: session)
				} label: {
					VStack(alignment: .leading) {
						Text("\(session.username)@\(session.hostname)")
					}
				}
			}
			.onDelete { index in
				let session = sessions[index.first!]
				_ = try? dbContext.writer.write { try session.delete($0) }
			}
		}
		
		.navigationTitle("Termsy")
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					coordinator.isShowingConnectView = true
				} label: {
					Label("New Session", systemImage: "plus")
				}
			}
		}
		.onAppear {
			if sessions.isEmpty {
				coordinator.isShowingConnectView = true
			}
		}
	}
}
