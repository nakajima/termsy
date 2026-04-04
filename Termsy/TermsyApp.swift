//
//  TermsyApp.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/2/26.
//

import GRDBQuery
import SwiftUI

@main
struct TermsyApp: App {
	@State private var coordinator = ViewCoordinator()
	
	let db: DB

	init() {
		self.db = DB.path(URL.documentsDirectory.appending(path: "termsy.db").path)
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
				.databaseContext(.readWrite { self.db.queue })
				.environment(coordinator)
		}
	}
}
