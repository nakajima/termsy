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
				} else {
					BackgroundReconnectStatusView()
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

			if showsPasswordPrompt {
				Color.black.opacity(0.28)
					.ignoresSafeArea()
					.transition(.opacity)

				PasswordPromptView(
					detailText: tab.detailText,
					password: $password,
					onConnect: submitPassword,
					onCancel: cancelPasswordPrompt
				)
				.padding()
				.transition(.opacity.combined(with: .scale(scale: 0.98)))
				.zIndex(2)
			}

			TerminalFileDropOverlayView(
				state: tab.fileDropOverlayState,
				onDismissError: {
					tab.dismissFileDropError()
				}
			)
			.zIndex(3)
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
		.allowsHitTesting(tab.showsConnectionLogPanel || showsPasswordPrompt || tab.fileDropOverlayState.blocksInput)
		.animation(.easeInOut(duration: 0.16), value: showsPasswordPrompt)
		.onChange(of: tab.needsPassword) { _, needsPassword in
			if !needsPassword {
				password = ""
			}
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
				GeometryReader { proxy in
					let scale = min(
						1,
						min(proxy.size.width / snapshot.size.width, proxy.size.height / snapshot.size.height)
					)
					let fittedSize = CGSize(
						width: snapshot.size.width * scale,
						height: snapshot.size.height * scale
					)

					Image(uiImage: snapshot)
						.resizable()
						.frame(width: fittedSize.width, height: fittedSize.height)
						.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
						.clipped()
				}
				.background(theme.background)
				.clipped()
			} else {
				theme.background
			}
		#else
			theme.background
		#endif
	}

	private var showsConnectionLogToggle: Bool {
		tab.showsConnectionLogPanel
	}

	private var showsPasswordPrompt: Bool {
		tab.needsPassword && !tab.isLocalShell
	}

	private func submitPassword() {
		let pw = password
		password = ""
		onRetryWithPassword(pw)
	}

	private func cancelPasswordPrompt() {
		password = ""
		tab.connectionError = "Authentication cancelled"
	}
}

private struct PasswordPromptView: View {
	@Environment(\.appTheme) private var theme
	let detailText: String
	@Binding var password: String
	let onConnect: () -> Void
	let onCancel: () -> Void
	@FocusState private var passwordFieldFocused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 6) {
				Text("Password Required")
					.font(.headline)
					.foregroundStyle(theme.primaryText)

				Text(detailText)
					.font(.subheadline)
					.foregroundStyle(theme.secondaryText)
					.lineLimit(2)
			}

			SecureField("Password", text: $password)
				.textFieldStyle(.roundedBorder)
				.focused($passwordFieldFocused)
				.submitLabel(.go)
				.onSubmit(onConnect)
				.accessibilityIdentifier("passwordPrompt.field")

			HStack(spacing: 12) {
				Button("Cancel", role: .cancel, action: onCancel)
					.keyboardShortcut(.cancelAction)

				Spacer()

				Button("Connect", action: onConnect)
					.buttonStyle(.borderedProminent)
					.tint(theme.accent)
			}
		}
		.padding(22)
		.frame(maxWidth: 420)
		.background(theme.cardBackground.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
		.overlay {
			RoundedRectangle(cornerRadius: 16)
				.stroke(theme.divider, lineWidth: 1)
		}
		.shadow(color: .black.opacity(0.22), radius: 24, y: 12)
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("passwordPrompt")
		.onAppear {
			Task { @MainActor in
				await Task.yield()
				passwordFieldFocused = true
			}
		}
	}
}

private struct BackgroundReconnectStatusView: View {
	@Environment(\.appTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			ProgressView()
				.tint(theme.accent)
			Text("Reconnecting…")
				.font(.caption.weight(.semibold))
				.foregroundStyle(theme.primaryText)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.background(theme.cardBackground.opacity(0.94), in: .rect(cornerRadius: 12))
		.overlay {
			RoundedRectangle(cornerRadius: 12)
				.stroke(theme.divider, lineWidth: 1)
		}
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

#Preview("Background Reconnect Status") {
	BackgroundReconnectStatusView()
		.padding()
		.background(TerminalTheme.mocha.appTheme.background)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
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

#Preview("Password Prompt") {
	PasswordPromptView(
		detailText: "pat@example.local",
		password: .constant(""),
		onConnect: {},
		onCancel: {}
	)
	.padding()
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("Terminal Overlay Password") {
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
		tab.needsPassword = true
		return tab
	}()
	TerminalOverlay(tab: tab, onReconnect: {}, onRetryWithPassword: { _ in })
		.background(TerminalTheme.mocha.appTheme.background)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("Terminal Overlay Connection Log") {
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
