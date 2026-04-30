//
//  TerminalOverlay.swift
//  Termsy
//

import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif

struct TerminalOverlay: View {
	@Environment(\.appTheme) private var theme
	let tab: TerminalTab
	var onReconnect: () -> Void
	var onRetryWithPassword: (String) -> Void

	@State private var password = ""
	@State private var isShowingConnectionLog = false

	var body: some View {
		ZStack {
			switch tab.overlayState {
			case let .restoring(mode):
				snapshotBackdrop
				if mode.showsProgress {
					ProgressView("Restoring session…")
						.tint(theme.accent)
						.foregroundStyle(theme.primaryText)
				}
			case .connecting:
				snapshotBackdrop
				if tab.displaySnapshot == nil {
					ProgressView(tab.progressTitle)
						.tint(theme.accent)
						.foregroundStyle(theme.primaryText)
				}
			case .connected, .awaitingPassword, .failed:
				EmptyView()
			}

			if case let .failed(error) = tab.overlayState {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(theme.error)
					Text(tab.failureTitle)
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
		.safeAreaInset(edge: .bottom) {
			if showsConnectionLogToggle {
				ConnectionLogPanel(
					connectionLogText: tab.connectionLogText,
					isShowingConnectionLog: $isShowingConnectionLog
				)
				.padding(.horizontal)
				.padding(.bottom)
			}
		}
		.allowsHitTesting(!tab.isConnected || tab.connectionError != nil || tab.isRestoring)
		.alert("Password Required", isPresented: .init(
			get: { tab.needsPassword && !tab.isLocalShell },
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
			Text(tab.detailText)
		}
		.onChange(of: tab.connectionError) { _, error in
			if error != nil {
				isShowingConnectionLog = true
			}
		}
	}

	@ViewBuilder
	private var snapshotBackdrop: some View {
		#if canImport(UIKit)
			if let snapshot = tab.displaySnapshot {
				Image(uiImage: snapshot)
					.resizable()
					.scaledToFill()
					.ignoresSafeArea()
			} else {
				theme.background
			}
		#else
			theme.background
		#endif
	}


	private var showsConnectionLogToggle: Bool {
		!tab.isConnected || tab.connectionError != nil || tab.isRestoring
	}

}

private struct ConnectionLogPanel: View {
	@Environment(\.appTheme) private var theme
	let connectionLogText: String
	@Binding var isShowingConnectionLog: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				isShowingConnectionLog.toggle()
			} label: {
				HStack {
					Label("Connection Log", systemImage: "list.bullet.rectangle")
					Spacer()
					Image(systemName: isShowingConnectionLog ? "chevron.down" : "chevron.right")
				}
				.font(.caption.weight(.semibold))
			}
			.buttonStyle(.plain)
			.foregroundStyle(theme.primaryText)

			if isShowingConnectionLog {
				ScrollView {
					Text(connectionLogText.isEmpty ? "No connection events yet." : connectionLogText)
						.frame(maxWidth: .infinity, alignment: .leading)
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(theme.secondaryText)
						.textSelection(.enabled)
				}
				.frame(maxHeight: 180)
			}
		}
		.padding()
		.background(theme.cardBackground.opacity(0.95), in: .rect(cornerRadius: 12))
		.overlay {
			RoundedRectangle(cornerRadius: 12)
				.stroke(theme.divider, lineWidth: 1)
		}
	}
}

#Preview("Connection Log Panel") {
	ConnectionLogPanel(
		connectionLogText: "[SSH] Connecting to example.local\n[SSH] Host key verified\n[SSH] Waiting for password",
		isShowingConnectionLog: .constant(true)
	)
	.padding()
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
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
