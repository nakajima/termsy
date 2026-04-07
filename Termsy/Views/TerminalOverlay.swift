//
//  TerminalOverlay.swift
//  Termsy
//

import SwiftUI

struct TerminalOverlay: View {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab
	var onReconnect: () -> Void
	var onRetryWithPassword: (String) -> Void

	@State private var password = ""

	var body: some View {
		ZStack {
			if !tab.isConnected, tab.connectionError == nil, !tab.needsPassword {
				theme.background
				ProgressView("Connecting to \(tab.session.hostname)…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if tab.isRestoring {
				theme.background
				ProgressView("Restoring session…")
					.tint(theme.accent)
					.foregroundStyle(theme.primaryText)
			}

			if let error = tab.connectionError {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(theme.error)
					Text("Connection Failed")
						.font(.headline)
						.foregroundStyle(theme.primaryText)
					Text(error)
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
						.multilineTextAlignment(.center)
					Button {
						onReconnect()
					} label: {
						Label("Reconnect", systemImage: "arrow.clockwise")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.tint(theme.accent)
				}
				.padding()
				.background(theme.cardBackground, in: .rect(cornerRadius: 12))
				.overlay {
					RoundedRectangle(cornerRadius: 12)
						.stroke(theme.divider, lineWidth: 1)
				}
			}
		}
		.allowsHitTesting(!tab.isConnected || tab.connectionError != nil || tab.isRestoring)
		.alert("Password Required", isPresented: .init(
			get: { tab.needsPassword },
			set: { if !$0 { tab.needsPassword = false } }
		)) {
			SecureField("Password", text: $password)
			Button("Connect") {
				let pw = password
				password = ""
				onRetryWithPassword(pw)
			}
			Button("Cancel", role: .cancel) {
				password = ""
				tab.connectionError = "Authentication cancelled"
			}
		} message: {
			Text("\(tab.session.username)@\(tab.session.hostname)")
		}
	}
}

#Preview("Terminal Overlay Error") {
	let tab: TerminalTab = {
		var session = Session(
			hostname: "example.local",
			username: "pat",
			tmuxSessionName: nil,
			port: 22,
			autoconnect: true
		)
		session.id = 1
		let tab = TerminalTab(session: session)
		tab.connectionError = "Host key verification failed"
		return tab
	}()
	TerminalOverlay(tab: tab, onReconnect: {}, onRetryWithPassword: { _ in })
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
