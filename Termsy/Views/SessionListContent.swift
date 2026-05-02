import GRDB
import GRDBQuery
import SwiftUI

struct SessionsRequest: ValueObservationQueryable {
	static var defaultValue: [Session] { [] }

	func fetch(_ db: Database) throws -> [Session] {
		try Session.fetchSavedSessions(db)
	}
}

private struct DirectSessionTarget: Hashable {
	let username: String
	let hostname: String
	let port: Int
	let tmuxSessionName: String?

	init?(_ input: String) {
		let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else { return nil }
		guard let atIndex = trimmedInput.firstIndex(of: "@") else { return nil }

		let username = String(trimmedInput[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
		var targetText = String(trimmedInput[trimmedInput.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !username.isEmpty, !targetText.isEmpty, !targetText.contains("@") else { return nil }

		let tmuxSessionName: String?
		if let tmuxSeparator = targetText.firstIndex(of: "#") {
			let tmuxText = String(targetText[targetText.index(after: tmuxSeparator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
			tmuxSessionName = tmuxText.isEmpty ? nil : tmuxText
			targetText = String(targetText[..<tmuxSeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
		} else {
			tmuxSessionName = nil
		}

		var hostname = targetText
		var port = 22
		if let portSeparator = targetText.lastIndex(of: ":") {
			let portText = String(targetText[targetText.index(after: portSeparator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
			guard let parsedPort = Int(portText), (1 ... 65535).contains(parsedPort) else { return nil }
			hostname = String(targetText[..<portSeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
			port = parsedPort
		}

		guard !hostname.isEmpty, !hostname.contains(" ") else { return nil }
		guard !username.contains(" ") else { return nil }

		self.username = username
		self.hostname = hostname
		self.port = port
		self.tmuxSessionName = tmuxSessionName
	}

	var session: Session {
		Session(
			hostname: hostname,
			username: username,
			tmuxSessionName: tmuxSessionName,
			port: port,
			autoconnect: false
		)
	}

	var displayTarget: String {
		session.displayTarget
	}

	var normalizedTargetKey: String {
		session.normalizedTargetKey
	}
}

struct SessionListContent: View {
	enum Variant {
		case savedSessions
		case picker

		var showsEmptySavedSessionsSection: Bool {
			switch self {
			case .savedSessions:
				true
			case .picker:
				false
			}
		}

		var showsNewSessionRow: Bool {
			switch self {
			case .savedSessions:
				false
			case .picker:
				true
			}
		}

		var showsOpenIndicator: Bool {
			switch self {
			case .savedSessions:
				false
			case .picker:
				true
			}
		}

		var handlesEscape: Bool {
			switch self {
			case .savedSessions:
				false
			case .picker:
				true
			}
		}

		var sessionTitleFont: Font {
			switch self {
			case .savedSessions:
				.headline
			case .picker:
				.body.weight(.medium)
			}
		}

		var sessionSubtitleFont: Font {
			switch self {
			case .savedSessions:
				.subheadline
			case .picker:
				.caption
			}
		}
	}

	private enum ItemID: Hashable {
		case localShell
		case directConnection(String)
		case session(String)
		case newSession
	}

	@Environment(\.databaseContext) private var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) private var sessions: [Session]
	@State private var filterText = ""
	@State private var directConnectError: String?
	@State private var selectedItemID: ItemID?
	@FocusState private var isFilterFocused: Bool

	private let variant: Variant
	private let isSessionOpen: (Session) -> Bool
	private let onOpenSession: (Session) -> Void
	private let onOpenLocalShell: () -> Void
	private let onOpenNewSession: () -> Void
	private let onClose: () -> Void
	private let onAppearWithSessions: ([Session]) -> Void
	private let selectionPageJump = 8

	init(
		variant: Variant,
		isSessionOpen: @escaping (Session) -> Bool = { _ in false },
		onOpenSession: @escaping (Session) -> Void,
		onOpenLocalShell: @escaping () -> Void = {},
		onOpenNewSession: @escaping () -> Void = {},
		onClose: @escaping () -> Void = {},
		onAppearWithSessions: @escaping ([Session]) -> Void = { _ in }
	) {
		self.variant = variant
		self.isSessionOpen = isSessionOpen
		self.onOpenSession = onOpenSession
		self.onOpenLocalShell = onOpenLocalShell
		self.onOpenNewSession = onOpenNewSession
		self.onClose = onClose
		self.onAppearWithSessions = onAppearWithSessions
	}

	private var normalizedFilterText: String {
		filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private var filteredSessions: [Session] {
		guard !normalizedFilterText.isEmpty else { return sessions }
		return sessions.filter { sessionMatchesFilter($0) }
	}

	private var groupedSessions: [SessionHostGroup] {
		Session.groupByHost(filteredSessions)
	}

	private var parsedDirectTarget: DirectSessionTarget? {
		DirectSessionTarget(filterText)
	}

	private var directConnectTarget: DirectSessionTarget? {
		guard let parsedDirectTarget else { return nil }
		guard existingSession(for: parsedDirectTarget) == nil else { return nil }
		return parsedDirectTarget
	}

	private var shouldShowLocalShellRow: Bool {
		#if os(macOS)
			guard !normalizedFilterText.isEmpty else { return true }
			return "local shell".contains(normalizedFilterText)
				|| LocalShellProfile.default.detailText.lowercased().contains(normalizedFilterText)
		#else
			return false
		#endif
	}

	private var visibleItemIDs: [ItemID] {
		var ids: [ItemID] = []
		#if os(macOS)
			if shouldShowLocalShellRow {
				ids.append(.localShell)
			}
		#endif
		if let directConnectTarget {
			ids.append(.directConnection(directConnectTarget.normalizedTargetKey))
		}
		for group in groupedSessions {
			ids.append(contentsOf: group.sessions.map { .session($0.normalizedTargetKey) })
		}
		if variant.showsNewSessionRow {
			ids.append(.newSession)
		}
		return ids
	}

	var body: some View {
		ScrollViewReader { proxy in
			List {
				Section {
					filterField()
				}

				#if os(macOS)
					if shouldShowLocalShellRow {
						Section("Local") {
							localShellRow()
						}
					}
				#endif

				if let directConnectTarget {
					Section {
						directConnectionRow(for: directConnectTarget)
					}
				}

				if groupedSessions.isEmpty {
					if variant.showsEmptySavedSessionsSection {
						Section("Saved Sessions") {
							EmptyView()
						}
					}
				} else {
					ForEach(groupedSessions) { group in
						Section(group.title) {
							ForEach(group.sessions, id: \.id) { session in
								sessionRow(for: session)
							}
							.onDelete { offsets in
								deleteSessions(at: offsets, from: group.sessions)
							}
						}
					}
				}

				if variant.showsNewSessionRow {
					Section {
						newSessionRow()
					}
				}
			}
			.scrollContentBackground(.hidden)
			.background(theme.background)
			.background {
				SessionListKeyboardHandler(
					isEnabled: !isFilterFocused,
					handlesClose: variant.handlesEscape,
					onMoveSelection: moveSelection,
					onMovePage: moveSelectionByPage,
					onMoveToBoundary: moveSelectionToBoundary,
					onActivateSelection: activateSelection,
					onClose: onClose
				)
				.frame(width: 0, height: 0)
				.allowsHitTesting(false)
			}
			.onAppear {
				onAppearWithSessions(sessions)
				ensureValidSelection()
				scrollSelectionIfNeeded(using: proxy, animated: false)
			}
			.onChange(of: filterText, initial: false) { _, _ in
				directConnectError = nil
				resetSelectionToFirstItem()
				scrollSelectionIfNeeded(using: proxy, animated: true)
			}
			.onChange(of: visibleItemIDs, initial: false) { _, _ in
				ensureValidSelection()
				scrollSelectionIfNeeded(using: proxy, animated: true)
			}
			.onChange(of: selectedItemID, initial: false) { _, _ in
				scrollSelectionIfNeeded(using: proxy, animated: true)
			}
		}
	}

	@ViewBuilder
	private func filterField() -> some View {
		VStack(alignment: .leading, spacing: 6) {
			TextField("Filter or connect as user@host[:port][#tmux]", text: $filterText)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.go)
				.focused($isFilterFocused)
				.foregroundStyle(theme.primaryText)
				.accessibilityIdentifier("field.sessionFilter")
				.onSubmit(submitFilter)

			if let directConnectError {
				Text(directConnectError)
					.font(.caption)
					.foregroundStyle(theme.error)
			}
		}
		.listRowBackground(theme.cardBackground)
	}

	@ViewBuilder
	private func directConnectionRow(for target: DirectSessionTarget) -> some View {
		let itemID = ItemID.directConnection(target.normalizedTargetKey)
		let isSelected = selectedItemID == itemID

		Button {
			selectedItemID = itemID
			connect(to: target)
		} label: {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "bolt.fill")
					.foregroundStyle(theme.accent)
				VStack(alignment: .leading, spacing: 5) {
					Text("Connect to \(target.displayTarget)")
						.font(variant.sessionTitleFont)
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					if let tmuxSessionName = target.tmuxSessionName {
						Text("tmux: \(tmuxSessionName)")
							.font(variant.sessionSubtitleFont)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
				}
				Spacer(minLength: 0)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.listRowBackground(rowBackground(isSelected: isSelected))
		.id(itemID)
	}

	#if os(macOS)
		@ViewBuilder
		private func localShellRow() -> some View {
			let isSelected = selectedItemID == .localShell

			Button {
				selectedItemID = .localShell
				onOpenLocalShell()
			} label: {
				localShellLabel(isSelected: isSelected)
			}
			.buttonStyle(.plain)
			.sessionListKeyboardShortcut("l", modifiers: .command, enabled: variant == .picker)
			.listRowBackground(rowBackground(isSelected: isSelected))
			.id(ItemID.localShell)
		}

		@ViewBuilder
		private func localShellLabel(isSelected: Bool) -> some View {
			switch variant {
			case .savedSessions:
				VStack(alignment: .leading, spacing: 4) {
					Text("Local Shell")
						.font(.headline)
						.foregroundStyle(theme.primaryText)
					Text(LocalShellProfile.default.detailText)
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 6)
			case .picker:
				Label("Local Shell", systemImage: "terminal")
					.font(.body)
					.foregroundStyle(isSelected ? theme.primaryText : theme.accent)
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
		}
	#endif

	@ViewBuilder
	private func sessionRow(for session: Session) -> some View {
		let itemID = ItemID.session(session.normalizedTargetKey)
		let isSelected = selectedItemID == itemID
		let isOpen = variant.showsOpenIndicator && isSessionOpen(session)

		Button {
			selectedItemID = itemID
			onOpenSession(session)
		} label: {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					Text(session.listTitle)
						.font(variant.sessionTitleFont)
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					if let subtitle = session.listSubtitle {
						Text(subtitle)
							.font(variant.sessionSubtitleFont)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
					HStack(spacing: 8) {
						if let lastConnectedAt = session.lastConnectedAt {
							Text(lastConnectedAt, style: .relative)
								.monospacedDigit()
						} else {
							Text("Never connected")
						}
					}
					.font(.caption)
					.foregroundStyle(theme.tertiaryText)
				}
				Spacer(minLength: 0)
				if isOpen {
					Text("Open")
						.font(.caption)
						.foregroundStyle(theme.secondaryText)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.listRowBackground(rowBackground(isSelected: isSelected))
		.id(itemID)
	}

	@ViewBuilder
	private func newSessionRow() -> some View {
		let isSelected = selectedItemID == .newSession

		Button {
			selectedItemID = .newSession
			onOpenNewSession()
		} label: {
			Label("New Session", systemImage: "plus.circle")
				.font(.body)
				.foregroundStyle(isSelected ? theme.primaryText : theme.accent)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.keyboardShortcut("t", modifiers: .command)
		.listRowBackground(rowBackground(isSelected: isSelected))
		.id(ItemID.newSession)
	}

	private func rowBackground(isSelected: Bool) -> Color {
		isSelected ? theme.selectedBackground : theme.cardBackground
	}

	private func moveSelection(by offset: Int) {
		guard !visibleItemIDs.isEmpty else { return }
		guard offset != 0 else { return }

		let currentIndex: Int
		if let selectedItemID, let index = visibleItemIDs.firstIndex(of: selectedItemID) {
			currentIndex = index
		} else {
			currentIndex = 0
		}

		let nextIndex = min(max(currentIndex + offset, 0), visibleItemIDs.count - 1)
		selectedItemID = visibleItemIDs[nextIndex]
	}

	private func moveSelectionByPage(_ direction: Int) {
		guard direction != 0 else { return }
		moveSelection(by: direction * selectionPageJump)
	}

	private func moveSelectionToBoundary(_ isMovingToEnd: Bool) {
		guard !visibleItemIDs.isEmpty else { return }
		selectedItemID = isMovingToEnd ? visibleItemIDs.last : visibleItemIDs.first
	}

	private func activateSelection() {
		guard let selectedItemID else {
			ensureValidSelection()
			return
		}

		switch selectedItemID {
		case .localShell:
			onOpenLocalShell()
		case let .directConnection(key):
			guard let target = directConnectTarget, target.normalizedTargetKey == key else {
				ensureValidSelection()
				return
			}
			connect(to: target)
		case let .session(key):
			guard let session = sessions.first(where: { $0.normalizedTargetKey == key }) else {
				ensureValidSelection()
				return
			}
			onOpenSession(session)
		case .newSession:
			onOpenNewSession()
		}
	}

	private func submitFilter() {
		if let parsedDirectTarget {
			if let existingSession = existingSession(for: parsedDirectTarget) {
				onOpenSession(existingSession)
			} else {
				connect(to: parsedDirectTarget)
			}
			return
		}

		guard normalizedFilterText.isEmpty || !filteredSessions.isEmpty else { return }
		activateSelection()
	}

	private func ensureValidSelection() {
		guard let firstItemID = visibleItemIDs.first else {
			selectedItemID = nil
			return
		}
		guard let selectedItemID, visibleItemIDs.contains(selectedItemID) else {
			self.selectedItemID = firstItemID
			return
		}
	}

	private func resetSelectionToFirstItem() {
		selectedItemID = visibleItemIDs.first
	}

	private func scrollSelectionIfNeeded(using proxy: ScrollViewProxy, animated: Bool) {
		guard let selectedItemID else { return }
		let scroll = {
			proxy.scrollTo(selectedItemID, anchor: .center)
		}
		if animated {
			withAnimation(.easeInOut(duration: 0.15), scroll)
		} else {
			scroll()
		}
	}

	private func existingSession(for target: DirectSessionTarget) -> Session? {
		sessions.first { $0.normalizedTargetKey == target.normalizedTargetKey }
	}

	private func sessionMatchesFilter(_ session: Session) -> Bool {
		let searchableValues = [
			session.listTitle,
			session.listSubtitle,
			session.displayTarget,
			session.normalizedTargetKey,
			session.hostname,
			session.username,
			session.trimmedTmuxSessionName,
			String(session.port),
		]
		return searchableValues
			.compactMap { $0?.lowercased() }
			.contains { $0.contains(normalizedFilterText) }
	}

	@MainActor
	private func connect(to target: DirectSessionTarget) {
		var session = target.session

		do {
			try dbContext.writer.write { db in
				if let existingSession = try Session.existing(session, in: db) {
					session = existingSession
				} else {
					try session.save(db)
				}
			}
			directConnectError = nil
			onOpenSession(session)
		} catch {
			directConnectError = error.localizedDescription
		}
	}

	@MainActor
	private func deleteSessions(at offsets: IndexSet, from groupSessions: [Session]) {
		let sessionsToDelete = offsets.map { groupSessions[$0] }
		guard !sessionsToDelete.isEmpty else { return }

		do {
			try dbContext.writer.write { db in
				for session in sessionsToDelete {
					try session.delete(db)
				}
			}
			sessionsToDelete.forEach(Keychain.removePassword)
		} catch {
			print("[DB] failed to delete sessions: \(error)")
		}
	}
}

private extension View {
	@ViewBuilder
	func sessionListKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, enabled: Bool) -> some View {
		if enabled {
			keyboardShortcut(key, modifiers: modifiers)
		} else {
			self
		}
	}
}

#if canImport(UIKit)
	private struct SessionListKeyboardHandler: UIViewRepresentable {
		let isEnabled: Bool
		let handlesClose: Bool
		let onMoveSelection: (Int) -> Void
		let onMovePage: (Int) -> Void
		let onMoveToBoundary: (Bool) -> Void
		let onActivateSelection: () -> Void
		let onClose: () -> Void

		func makeUIView(context _: Context) -> KeyCommandView {
			let view = KeyCommandView()
			view.backgroundColor = .clear
			return view
		}

		func updateUIView(_ uiView: KeyCommandView, context _: Context) {
			uiView.acceptsKeyCommands = isEnabled
			uiView.handlesClose = handlesClose
			uiView.onMoveSelection = onMoveSelection
			uiView.onMovePage = onMovePage
			uiView.onMoveToBoundary = onMoveToBoundary
			uiView.onActivateSelection = onActivateSelection
			uiView.onClose = onClose
			if isEnabled {
				uiView.activateIfPossible()
			} else {
				uiView.deactivateIfNeeded()
			}
		}

		final class KeyCommandView: UIView {
			var acceptsKeyCommands = true
			var handlesClose = false
			var onMoveSelection: ((Int) -> Void)?
			var onMovePage: ((Int) -> Void)?
			var onMoveToBoundary: ((Bool) -> Void)?
			var onActivateSelection: (() -> Void)?
			var onClose: (() -> Void)?

			override var canBecomeFirstResponder: Bool { true }

			override var keyCommands: [UIKeyCommand]? {
				guard acceptsKeyCommands else { return nil }
				var commands = [
					command(input: UIKeyCommand.inputUpArrow, modifiers: [], action: #selector(moveUp), title: "Move Selection Up"),
					command(input: UIKeyCommand.inputDownArrow, modifiers: [], action: #selector(moveDown), title: "Move Selection Down"),
					command(input: "p", modifiers: .control, action: #selector(moveUp), title: "Move Selection Up"),
					command(input: "n", modifiers: .control, action: #selector(moveDown), title: "Move Selection Down"),
					command(input: UIKeyCommand.inputPageUp, modifiers: [], action: #selector(movePageUp), title: "Page Up"),
					command(input: UIKeyCommand.inputPageDown, modifiers: [], action: #selector(movePageDown), title: "Page Down"),
					command(input: UIKeyCommand.inputHome, modifiers: [], action: #selector(moveToStart), title: "Move to First Item"),
					command(input: UIKeyCommand.inputEnd, modifiers: [], action: #selector(moveToEnd), title: "Move to Last Item"),
					command(input: UIKeyCommand.inputUpArrow, modifiers: .command, action: #selector(moveToStart), title: "Move to First Item"),
					command(input: UIKeyCommand.inputDownArrow, modifiers: .command, action: #selector(moveToEnd), title: "Move to Last Item"),
					command(input: "\r", modifiers: [], action: #selector(activateSelection), title: "Open Selection"),
				]
				if handlesClose {
					commands.append(command(input: UIKeyCommand.inputEscape, modifiers: [], action: #selector(close), title: "Close"))
				}
				return commands
			}

			private func command(input: String, modifiers: UIKeyModifierFlags, action: Selector, title: String) -> UIKeyCommand {
				let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
				command.wantsPriorityOverSystemBehavior = true
				command.discoverabilityTitle = title
				return command
			}

			override func didMoveToWindow() {
				super.didMoveToWindow()
				activateIfPossible()
			}

			func activateIfPossible() {
				guard acceptsKeyCommands, window != nil else { return }
				DispatchQueue.main.async { [weak self] in
					guard let self, self.acceptsKeyCommands, self.window != nil else { return }
					_ = self.becomeFirstResponder()
				}
			}

			func deactivateIfNeeded() {
				if isFirstResponder {
					resignFirstResponder()
				}
			}

			@objc private func moveUp() { onMoveSelection?(-1) }
			@objc private func moveDown() { onMoveSelection?(1) }
			@objc private func movePageUp() { onMovePage?(-1) }
			@objc private func movePageDown() { onMovePage?(1) }
			@objc private func moveToStart() { onMoveToBoundary?(false) }
			@objc private func moveToEnd() { onMoveToBoundary?(true) }
			@objc private func activateSelection() { onActivateSelection?() }
			@objc private func close() { onClose?() }
		}
	}

#elseif canImport(AppKit)
	import AppKit

	private struct SessionListKeyboardHandler: NSViewRepresentable {
		let isEnabled: Bool
		let handlesClose: Bool
		let onMoveSelection: (Int) -> Void
		let onMovePage: (Int) -> Void
		let onMoveToBoundary: (Bool) -> Void
		let onActivateSelection: () -> Void
		let onClose: () -> Void

		func makeNSView(context _: Context) -> KeyCommandView {
			KeyCommandView()
		}

		func updateNSView(_ nsView: KeyCommandView, context _: Context) {
			nsView.acceptsKeyCommands = isEnabled
			nsView.handlesClose = handlesClose
			nsView.onMoveSelection = onMoveSelection
			nsView.onMovePage = onMovePage
			nsView.onMoveToBoundary = onMoveToBoundary
			nsView.onActivateSelection = onActivateSelection
			nsView.onClose = onClose
			if isEnabled {
				nsView.activateIfPossible()
			} else {
				nsView.deactivateIfNeeded()
			}
		}

		final class KeyCommandView: NSView {
			var acceptsKeyCommands = true
			var handlesClose = false
			var onMoveSelection: ((Int) -> Void)?
			var onMovePage: ((Int) -> Void)?
			var onMoveToBoundary: ((Bool) -> Void)?
			var onActivateSelection: (() -> Void)?
			var onClose: (() -> Void)?

			override var acceptsFirstResponder: Bool { true }

			override func viewDidMoveToWindow() {
				super.viewDidMoveToWindow()
				activateIfPossible()
			}

			func activateIfPossible() {
				guard acceptsKeyCommands, let window else { return }
				DispatchQueue.main.async { [weak self, weak window] in
					guard let self, self.acceptsKeyCommands, let window, self.window === window else { return }
					window.makeFirstResponder(self)
				}
			}

			func deactivateIfNeeded() {
				guard window?.firstResponder === self else { return }
				window?.makeFirstResponder(nil)
			}

			override func keyDown(with event: NSEvent) {
				guard acceptsKeyCommands else {
					nextResponder?.keyDown(with: event)
					return
				}
				guard !handle(event) else { return }
				nextResponder?.keyDown(with: event)
			}

			private func handle(_ event: NSEvent) -> Bool {
				let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
				let hasNoModifiers = modifiers.isEmpty

				switch event.keyCode {
				case 126 where hasNoModifiers:
					onMoveSelection?(-1)
					return true
				case 125 where hasNoModifiers:
					onMoveSelection?(1)
					return true
				case 116 where hasNoModifiers:
					onMovePage?(-1)
					return true
				case 121 where hasNoModifiers:
					onMovePage?(1)
					return true
				case 115 where hasNoModifiers:
					onMoveToBoundary?(false)
					return true
				case 119 where hasNoModifiers:
					onMoveToBoundary?(true)
					return true
				case 126 where modifiers == .command:
					onMoveToBoundary?(false)
					return true
				case 125 where modifiers == .command:
					onMoveToBoundary?(true)
					return true
				case 36, 76 where hasNoModifiers:
					onActivateSelection?()
					return true
				case 53 where hasNoModifiers && handlesClose:
					onClose?()
					return true
				default:
					break
				}

				if modifiers == .control {
					switch event.charactersIgnoringModifiers?.lowercased() {
					case "p":
						onMoveSelection?(-1)
						return true
					case "n":
						onMoveSelection?(1)
						return true
					default:
						break
					}
				}

				return false
			}
		}
	}
#else
	private struct SessionListKeyboardHandler: View {
		let isEnabled: Bool
		let handlesClose: Bool
		let onMoveSelection: (Int) -> Void
		let onMovePage: (Int) -> Void
		let onMoveToBoundary: (Bool) -> Void
		let onActivateSelection: () -> Void
		let onClose: () -> Void

		var body: some View {
			Color.clear
		}
	}
#endif

#Preview("Saved Sessions") {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true,
			customTitle: "Production"
		)
		session.lastConnectedAt = .now
		try session.save(db)
	}

	return SessionListContent(
		variant: .savedSessions,
		onOpenSession: { _ in }
	)
	.databaseContext(.readWrite { db.queue })
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("Session Picker") {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var session = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true
		)
		session.lastConnectedAt = .now
		try session.save(db)
	}

	return SessionListContent(
		variant: .picker,
		isSessionOpen: { _ in true },
		onOpenSession: { _ in },
		onOpenNewSession: {}
	)
	.databaseContext(.readWrite { db.queue })
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
