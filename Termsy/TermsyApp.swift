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
	private let launchConfiguration: AppLaunchConfiguration

	init() {
		let launchConfiguration = AppLaunchConfiguration.current
		self.launchConfiguration = launchConfiguration
		self.db = DB.path(launchConfiguration.databasePath)
		launchConfiguration.preparePersistentStateIfNeeded(using: db)
		#if os(macOS)
			NSWindow.allowsAutomaticWindowTabbing = false
		#endif
	}

	private var theme: TerminalTheme {
		if launchConfiguration.isScreenshotMode {
			return .mocha
		}
		return TerminalTheme(rawValue: selectedTheme) ?? .mocha
	}

	@SceneBuilder
	var body: some Scene {
		#if os(macOS)
			Window("Teletype", id: "main") {
				AppRootView(
					db: db,
					coordinator: coordinator,
					theme: theme,
					launchConfiguration: launchConfiguration
				)
			}
		#else
			WindowGroup {
				AppRootView(
					db: db,
					coordinator: coordinator,
					theme: theme,
					launchConfiguration: launchConfiguration
				)
			}
		#endif
	}
}

private struct AppRootView: View {
	let db: DB
	let coordinator: ViewCoordinator
	let theme: TerminalTheme
	let launchConfiguration: AppLaunchConfiguration

	var body: some View {
		ContentView(launchConfiguration: launchConfiguration)
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
	return AppRootView(
		db: db,
		coordinator: coordinator,
		theme: .mocha,
		launchConfiguration: AppLaunchConfiguration(environment: [:])
	)
}
