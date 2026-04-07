#if os(macOS)
import AppKit
import GRDBQuery
import GhosttyTerminal
import SwiftUI

struct MacRootView: View {
	@Environment(\.databaseContext) private var dbContext
	@Environment(\.appTheme) private var theme
	@Environment(\.openWindow) private var openWindow

	@State private var isShowingConnectSheet = false
	@State private var window: NSWindow?
	@State private var terminal: MacTerminalTab

	init(sceneValue: MacTerminalSceneValue) {
		_terminal = State(initialValue: MacTerminalTab(source: sceneValue.terminalSource))
	}

	var body: some View {
		ZStack {
			TerminalSurfaceView(context: terminal.viewState)
				.background(theme.background)
				.task(id: terminal.viewState.surfaceSize?.columns ?? 0) {
					guard terminal.viewState.surfaceSize != nil else { return }
					await terminal.startIfNeeded()
				}

			if terminal.isStarting {
				ProgressView(terminal.title)
					.controlSize(.large)
					.padding(24)
					.background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
			}

			if let connectionError = terminal.connectionError {
				VStack(spacing: 12) {
					Image(systemName: "xmark.circle")
						.font(.largeTitle)
						.foregroundStyle(theme.error)
					Text(terminal.title)
						.font(.headline)
						.foregroundStyle(theme.primaryText)
					Text(connectionError)
						.multilineTextAlignment(.center)
						.foregroundStyle(theme.secondaryText)
					Button("Close") {
						window?.performClose(nil)
					}
					.buttonStyle(.borderedProminent)
					.tint(theme.accent)
				}
				.padding(24)
				.background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
				.overlay {
					RoundedRectangle(cornerRadius: 16)
						.stroke(theme.divider, lineWidth: 1)
				}
			}
		}
		.frame(minWidth: 700, minHeight: 450)
		.background(theme.background)
		.sheet(isPresented: $isShowingConnectSheet) {
			MacConnectSheetView { session in
				openSSH(session)
			}
			.databaseContext(dbContext)
			.environment(\.appTheme, theme)
		}
		.background(MacWindowAccessor(window: $window))
		.onReceive(NotificationCenter.default.publisher(for: .termsyPresentSSHSessionSheet)) { notification in
			if let targetWindow = notification.object as? NSWindow {
				guard targetWindow === window else { return }
			} else {
				guard window?.isKeyWindow == true || window?.isMainWindow == true else { return }
			}
			isShowingConnectSheet = true
		}
		.onAppear {
			configureWindow()
		}
		.onChange(of: window) { _ in
			configureWindow()
		}
		.onDisappear {
			terminal.close()
		}
	}

	private func configureWindow() {
		guard let window else { return }
		window.title = terminal.title
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.isMovableByWindowBackground = true
		window.toolbar = nil
		window.backgroundColor = theme.backgroundUIColor
		window.tabbingMode = .preferred
		window.tabbingIdentifier = MacNativeTabCoordinator.tabbingIdentifier
		terminal.onRequestClose = { [weak window] in
			window?.performClose(nil)
		}
		MacNativeTabCoordinator.shared.attachIfNeeded(to: window)
	}

	private func openSSH(_ session: Session) {
		MacNativeTabCoordinator.shared.prepareForNewTab(from: window)
		openWindow(value: MacTerminalSceneValue.ssh(session))
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	return MacRootView(sceneValue: .localShell())
		.databaseContext(.readWrite { db.queue })
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
#endif
