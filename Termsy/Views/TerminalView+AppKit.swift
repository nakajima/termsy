#if canImport(AppKit) && canImport(GhosttyTerminal) && !canImport(UIKit)
import AppKit
import GhosttyTerminal

@MainActor
final class TerminalView: NSView {
	var onWrite: ((Data) -> Void)?
	var onResize: ((UInt16, UInt16) -> Void)?
	var onCloseTabRequest: (() -> Void)?
	var onNewTabRequest: (() -> Void)?
	var onSelectTabRequest: ((Int) -> Void)?
	var onMoveTabSelectionRequest: ((Int) -> Void)?
	var onShowSettingsRequest: (() -> Void)?
	var onDismissAuxiliaryUIRequest: (() -> Bool)?

	private let controller: TerminalController
	private var terminalSession: InMemoryTerminalSession!
	private let platformView: GhosttyTerminal.TerminalView
	private var lastTerminalSize: TerminalWindowSize?
	private var acceptsTerminalOutput = true

	override init(frame frameRect: NSRect) {
		controller = TerminalController(
			configSource: .generated(GhosttyApp.buildConfigText(theme: TerminalTheme.current))
		)
		platformView = GhosttyTerminal.TerminalView(frame: frameRect)
		super.init(frame: frameRect)
		commonInit()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	var isFirstResponder: Bool {
		window?.firstResponder === platformView
	}

	var hasAttachedWindow: Bool {
		window != nil
	}

	private func commonInit() {
		wantsLayer = true
		layer?.backgroundColor = NSColor.clear.cgColor

		terminalSession = InMemoryTerminalSession(
			write: { [weak self] data in
				DispatchQueue.main.async {
					self?.onWrite?(data)
				}
			},
			resize: { [weak self] viewport in
				DispatchQueue.main.async {
					guard let self else { return }
					self.lastTerminalSize = TerminalWindowSize(
						columns: Int(viewport.columns),
						rows: Int(viewport.rows),
						pixelWidth: Int(viewport.widthPixels),
						pixelHeight: Int(viewport.heightPixels)
					)
					self.onResize?(viewport.columns, viewport.rows)
				}
			}
		)

		platformView.configuration = TerminalSurfaceOptions(
			backend: .inMemory(terminalSession)
		)
		platformView.controller = controller
		platformView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(platformView)

		NSLayoutConstraint.activate([
			platformView.leadingAnchor.constraint(equalTo: leadingAnchor),
			platformView.trailingAnchor.constraint(equalTo: trailingAnchor),
			platformView.topAnchor.constraint(equalTo: topAnchor),
			platformView.bottomAnchor.constraint(equalTo: bottomAnchor),
		])

		GhosttyApp.shared.register(controller)
		applyTheme(TerminalTheme.current.appTheme)
	}

	func applyTheme(_ theme: AppTheme) {
		layer?.backgroundColor = theme.backgroundUIColor.cgColor
		platformView.layer?.backgroundColor = theme.backgroundUIColor.cgColor
	}

	func start() {
		acceptsTerminalOutput = true
	}

	func stop() {
		acceptsTerminalOutput = false
		setDisplayActive(false)
	}

	func feedData(_ data: Data) {
		guard acceptsTerminalOutput, !data.isEmpty else { return }
		terminalSession.receive(data)
	}

	func processExited(code: UInt32 = 0, runtimeMs: UInt64 = 0) {
		guard acceptsTerminalOutput else { return }
		acceptsTerminalOutput = false
		terminalSession.finish(exitCode: code, runtimeMilliseconds: runtimeMs)
	}

	func setDisplayActive(_ isActive: Bool) {
		guard hasAttachedWindow else { return }
		if isActive {
			window?.makeFirstResponder(platformView)
		} else if window?.firstResponder === platformView {
			window?.makeFirstResponder(nil)
		}
	}

	func syncSizeAndReadBack() -> TerminalWindowSize? {
		platformView.fitToSize()
		return currentTerminalSize()
	}

	func currentTerminalSize() -> TerminalWindowSize? {
		lastTerminalSize
	}
}
#elseif canImport(AppKit) && !canImport(UIKit)
import AppKit

@MainActor
final class TerminalView: NSView {
	var onWrite: ((Data) -> Void)?
	var onResize: ((UInt16, UInt16) -> Void)?
	var onCloseTabRequest: (() -> Void)?
	var onNewTabRequest: (() -> Void)?
	var onSelectTabRequest: ((Int) -> Void)?
	var onMoveTabSelectionRequest: ((Int) -> Void)?
	var onShowSettingsRequest: (() -> Void)?
	var onDismissAuxiliaryUIRequest: (() -> Bool)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		applyTheme(TerminalTheme.current.appTheme)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	var isFirstResponder: Bool {
		window?.firstResponder === self
	}

	var hasAttachedWindow: Bool {
		window != nil
	}

	func applyTheme(_ theme: AppTheme) {
		layer?.backgroundColor = theme.backgroundUIColor.cgColor
	}

	func start() {}
	func stop() { setDisplayActive(false) }
	func feedData(_ data: Data) {}
	func processExited(code: UInt32 = 0, runtimeMs: UInt64 = 0) {}

	func setDisplayActive(_ isActive: Bool) {
		guard hasAttachedWindow else { return }
		if isActive {
			window?.makeFirstResponder(self)
		} else if window?.firstResponder === self {
			window?.makeFirstResponder(nil)
		}
	}

	func syncSizeAndReadBack() -> TerminalWindowSize? {
		currentTerminalSize()
	}

	func currentTerminalSize() -> TerminalWindowSize? {
		let width = max(Int(bounds.width), 1)
		let height = max(Int(bounds.height), 1)
		return TerminalWindowSize(
			columns: max(width / 8, 1),
			rows: max(height / 16, 1),
			pixelWidth: width,
			pixelHeight: height
		)
	}
}
#endif
