//
//  TermsyApp.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/2/26.
//

import GRDBQuery
import SwiftUI
#if os(macOS)
	import AppKit
#endif

@main
struct TermsyApp: App {
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@State private var coordinator = ViewCoordinator()

	let db: DB

	init() {
		self.db = DB.path(URL.documentsDirectory.appending(path: "termsy.db").path)
		#if os(macOS)
			NSWindow.allowsAutomaticWindowTabbing = false
		#endif
	}

	private var theme: TerminalTheme {
		TerminalTheme(rawValue: selectedTheme) ?? .mocha
	}

	@SceneBuilder
	var body: some Scene {
		#if os(macOS)
			Window("Termsy", id: "main") {
				AppRootView(db: db, coordinator: coordinator, theme: theme)
			}
		#else
			WindowGroup {
				AppRootView(db: db, coordinator: coordinator, theme: theme)
			}
		#endif
	}
}

private struct AppRootView: View {
	let db: DB
	let coordinator: ViewCoordinator
	let theme: TerminalTheme

	var body: some View {
		ContentView()
			.databaseContext(.readWrite { db.queue })
			.environment(coordinator)
			.environment(\.appTheme, theme.appTheme)
			.preferredColorScheme(theme.appTheme.colorScheme)
			.tint(theme.appTheme.accent)
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	let coordinator = ViewCoordinator()
	return AppRootView(db: db, coordinator: coordinator, theme: .mocha)
}
