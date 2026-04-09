#if os(macOS)
import AppKit
import GRDBQuery
import SwiftUI

struct MacRootView: View {
	@Environment(\.databaseContext) private var dbContext
	@AppStorage("terminalTheme") private var selectedTheme = TerminalTheme.mocha.rawValue
	@AppStorage("cursorStyle") private var cursorStyle = "block"
	@AppStorage("cursorBlink") private var cursorBlink = true
	@AppStorage(TerminalFontSettings.familyKey) private var terminalFontFamily = ""
	@AppStorage(TerminalBackgroundSettings.opacityKey) private var backgroundOpacity = TerminalBackgroundSettings.defaultOpacity
	@AppStorage(TerminalBackgroundBlurSettings.key) private var backgroundBlurMode = TerminalBackgroundBlurSettings.default.rawValue

	@State private var isShowingConnectSheet = false
	@State private var window: NSWindow?

	let terminal: MacTerminalTab
	let onOpenSSH: (Session, NSWindow?) -> Void
	let onWindowTitleChange: (String) -> Void
	let onWindowAppearanceChange: () -> Void

	private var currentTerminalTheme: TerminalTheme {
		TerminalTheme(rawValue: selectedTheme) ?? .mocha
	}

	private var theme: AppTheme {
		currentTerminalTheme.appTheme
	}

	var body: some View {
		ZStack {
			MacTerminalHostRepresentable(terminal: terminal)
				.background(.clear)
				.task {
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
		.background(.clear)
		.sheet(isPresented: $isShowingConnectSheet) {
			MacConnectSheetView { session in
				onOpenSSH(session, window)
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
			terminal.applyTheme(theme)
			terminal.reloadConfiguration(theme: currentTerminalTheme)
			if !ensureBlurCompatibleOpacityIfNeeded() {
				onWindowAppearanceChange()
				onWindowTitleChange(terminal.windowTitle)
			}
		}
		.onChange(of: window) { _ in
			onWindowAppearanceChange()
			onWindowTitleChange(terminal.windowTitle)
		}
		.onChange(of: terminal.windowTitle) { _, title in
			onWindowTitleChange(title)
		}
		.onChange(of: selectedTheme) { _, _ in
			onWindowAppearanceChange()
			reloadTerminalConfiguration()
		}
		.onChange(of: cursorStyle) { _, _ in
			reloadTerminalConfiguration()
		}
		.onChange(of: cursorBlink) { _, _ in
			reloadTerminalConfiguration()
		}
		.onChange(of: terminalFontFamily) { _, _ in
			reloadTerminalConfiguration()
		}
		.onChange(of: backgroundOpacity) { _, _ in
			if ensureBlurCompatibleOpacityIfNeeded() { return }
			onWindowAppearanceChange()
			reloadTerminalConfiguration()
		}
		.onChange(of: backgroundBlurMode) { _, _ in
			if ensureBlurCompatibleOpacityIfNeeded() { return }
			onWindowAppearanceChange()
			reloadTerminalConfiguration()
		}
	}

	func presentConnectSheet() {
		isShowingConnectSheet = true
	}

	private func ensureBlurCompatibleOpacityIfNeeded() -> Bool {
		let blurMode = TerminalBackgroundBlurSettings(rawValue: backgroundBlurMode) ?? .default
		guard blurMode.requiresTransparency else { return false }
		guard TerminalBackgroundSettings.normalizedOpacity(backgroundOpacity) >= 0.999 else { return false }
		backgroundOpacity = TerminalBackgroundBlurSettings.recommendedOpacityWhenEnabled
		return true
	}

	private func reloadTerminalConfiguration() {
		terminal.reloadConfiguration(theme: currentTerminalTheme)
	}
}

private struct MacTerminalHostRepresentable: NSViewRepresentable {
	let terminal: MacTerminalTab

	func makeNSView(context: Context) -> MacTerminalHostView {
		let view = MacTerminalHostView()
		view.attach(terminal.terminalView)
		return view
	}

	func updateNSView(_ nsView: MacTerminalHostView, context: Context) {
		nsView.attach(terminal.terminalView)
	}
}

private final class MacTerminalHostView: NSView {
	func attach(_ terminalView: MacTerminalView) {
		guard terminalView.superview !== self else {
			terminalView.frame = bounds
			return
		}
		terminalView.removeFromSuperview()
		terminalView.frame = bounds
		terminalView.autoresizingMask = [.width, .height]
		addSubview(terminalView)
	}
}

#Preview {
	let db = DB.memory()
	try? db.migrate()
	let terminal = MacTerminalTab(source: .localShell)
	return MacRootView(
		terminal: terminal,
		onOpenSSH: { _, _ in },
		onWindowTitleChange: { _ in },
		onWindowAppearanceChange: {}
	)
	.databaseContext(.readWrite { db.queue })
}
#endif
