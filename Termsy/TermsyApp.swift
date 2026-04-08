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

	private var rootView: some View {
		ContentView()
			.databaseContext(.readWrite { self.db.queue })
			.environment(coordinator)
			.environment(\.appTheme, theme.appTheme)
			.preferredColorScheme(theme.appTheme.colorScheme)
			.tint(theme.appTheme.accent)
	}

	@SceneBuilder
	var body: some Scene {
		#if os(macOS)
		Window("Termsy", id: "main") {
			rootView
		}
		#else
		WindowGroup {
			rootView
		}
		#endif
	}
}
