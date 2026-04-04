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
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@State private var coordinator = ViewCoordinator()

	let db: DB

	init() {
		self.db = DB.path(URL.documentsDirectory.appending(path: "termsy.db").path)
	}

	private var theme: TerminalTheme {
		TerminalTheme(rawValue: selectedTheme) ?? .mocha
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
				.databaseContext(.readWrite { self.db.queue })
				.environment(coordinator)
				.environment(\.appTheme, theme.appTheme)
				.preferredColorScheme(theme.appTheme.colorScheme)
				.tint(theme.appTheme.accent)
		}
	}
}
