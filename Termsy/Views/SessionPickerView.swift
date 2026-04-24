//
//  SessionPickerView.swift
//  Termsy
//
//  Shown in a trailing panel when tapping + in the tab bar.
//  Lists saved sessions to quickly open, plus a "New Session" option.
//

import GRDB
import GRDBQuery
import SwiftUI

struct SessionPickerView: View {
	private enum PickerItemID: Hashable {
		case localShell
		case session(String)
		case newSession
	}

	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) var sessions: [Session]

	@State private var selectedItemID: PickerItemID?

	private let selectionPageJump = 8

	private var groupedSessions: [SessionHostGroup] {
		Session.groupByHost(sessions)
	}

	private var pickerItemIDs: [PickerItemID] {
		let sessionItems = sessions.map { PickerItemID.session($0.normalizedTargetKey) }
		#if os(macOS)
			return [.localShell] + sessionItems + [.newSession]
		#else
			return sessionItems + [.newSession]
		#endif
	}

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				List {
					#if os(macOS)
						Section("Local") {
							LocalShellRow(
								isSelected: selectedItemID == .localShell,
								onOpen: openLocalShell,
								onSelect: { selectedItemID = .localShell }
							)
						}
					#endif

					if !groupedSessions.isEmpty {
						ForEach(groupedSessions) { group in
							Section(group.title) {
								ForEach(group.sessions) { session in
									sessionRow(for: session)
								}
								.onDelete { offsets in
									deleteSessions(at: offsets, from: group.sessions)
								}
							}
						}
					}

					Section {
						NewSessionRow(
							isSelected: selectedItemID == .newSession,
							onOpen: openNewSession,
							onSelect: { selectedItemID = .newSession }
						)
					}
				}
				.scrollContentBackground(.hidden)
				.background(theme.background)
				.navigationTitle("Sessions")
				.termsyInlineNavigationTitle()
				.toolbar {
					ToolbarItem(placement: .termsyPrimaryAction) {
						Button("Done") {
							coordinator.isShowingSessionPicker = false
						}
						.keyboardShortcut(.cancelAction)
					}
				}
				.termsyNavigationBarAppearance(theme)
				.background {
					SessionPickerKeyboardHandler(
						onMoveSelection: moveSelection,
						onMovePage: moveSelectionByPage,
						onMoveToBoundary: moveSelectionToBoundary,
						onActivateSelection: activateSelection,
						onClose: { coordinator.isShowingSessionPicker = false }
					)
					.frame(width: 0, height: 0)
					.allowsHitTesting(false)
				}
				.onAppear {
					ensureValidSelection()
					scrollSelectionIfNeeded(using: proxy, animated: false)
				}
				.onChange(of: sessions.map(\.id), initial: false) { _, _ in
					ensureValidSelection()
				}
				.onChange(of: selectedItemID, initial: false) { _, _ in
					scrollSelectionIfNeeded(using: proxy, animated: true)
				}
			}
		}
	}

	@ViewBuilder
	private func sessionRow(for session: Session) -> some View {
		let itemID = PickerItemID.session(session.normalizedTargetKey)
		let isOpen = coordinator.tabs.contains { $0.session?.normalizedTargetKey == session.normalizedTargetKey }
		let isSelected = selectedItemID == itemID

		Button {
			openSession(session)
		} label: {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					Text(session.listTitle)
						.font(.body.weight(.medium))
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					if let subtitle = session.listSubtitle {
						Text(subtitle)
							.font(.caption)
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
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.listRowBackground(isSelected ? theme.selectedBackground : theme.cardBackground)
		.id(itemID)
		.onTapGesture {
			selectedItemID = itemID
		}
	}

	#if os(macOS)
		fileprivate struct LocalShellRow: View {
			@Environment(\.appTheme) private var theme
			let isSelected: Bool
			var onOpen: () -> Void
			var onSelect: () -> Void

			var body: some View {
				Button {
					onOpen()
				} label: {
					Label("Local Shell", systemImage: "terminal")
						.font(.body)
						.foregroundStyle(isSelected ? theme.primaryText : theme.accent)
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.keyboardShortcut("l", modifiers: .command)
				.listRowBackground(isSelected ? theme.selectedBackground : theme.cardBackground)
				.id(PickerItemID.localShell)
				.onTapGesture(perform: onSelect)
			}
		}
	#endif

	fileprivate struct NewSessionRow: View {
		@Environment(\.appTheme) private var theme
		let isSelected: Bool
		var onOpen: () -> Void
		var onSelect: () -> Void

		var body: some View {
			Button {
				onOpen()
			} label: {
				Label("New Session", systemImage: "plus.circle")
					.font(.body)
					.foregroundStyle(isSelected ? theme.primaryText : theme.accent)
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.keyboardShortcut("t", modifiers: .command)
			.listRowBackground(isSelected ? theme.selectedBackground : theme.cardBackground)
			.id(PickerItemID.newSession)
			.onTapGesture(perform: onSelect)
		}
	}

	private func moveSelection(by offset: Int) {
		guard !pickerItemIDs.isEmpty else { return }
		guard offset != 0 else { return }

		let currentIndex: Int
		if let selectedItemID, let index = pickerItemIDs.firstIndex(of: selectedItemID) {
			currentIndex = index
		} else {
			currentIndex = 0
		}

		let nextIndex = min(max(currentIndex + offset, 0), pickerItemIDs.count - 1)
		selectedItemID = pickerItemIDs[nextIndex]
	}

	private func moveSelectionByPage(_ direction: Int) {
		guard direction != 0 else { return }
		moveSelection(by: direction * selectionPageJump)
	}

	private func moveSelectionToBoundary(_ isMovingToEnd: Bool) {
		guard !pickerItemIDs.isEmpty else { return }
		selectedItemID = isMovingToEnd ? pickerItemIDs.last : pickerItemIDs.first
	}

	private func activateSelection() {
		guard let selectedItemID else {
			ensureValidSelection()
			return
		}

		switch selectedItemID {
		case .localShell:
			#if os(macOS)
				openLocalShell()
			#else
				break
			#endif
		case let .session(key):
			guard let session = sessions.first(where: { $0.normalizedTargetKey == key }) else {
				ensureValidSelection()
				return
			}
			openSession(session)
		case .newSession:
			openNewSession()
		}
	}

	private func openSession(_ session: Session) {
		selectedItemID = .session(session.normalizedTargetKey)
		coordinator.openTab(for: session)
		coordinator.isShowingSessionPicker = false
	}

	#if os(macOS)
		private func openLocalShell() {
			selectedItemID = .localShell
			coordinator.isShowingSessionPicker = false
			coordinator.openLocalShellTab()
		}
	#endif

	private func openNewSession() {
		selectedItemID = .newSession
		coordinator.isShowingSessionPicker = false
		coordinator.isShowingConnectView = true
	}

	private func ensureValidSelection() {
		guard let firstItemID = pickerItemIDs.first else {
			selectedItemID = nil
			return
		}
		guard let selectedItemID, pickerItemIDs.contains(selectedItemID) else {
			self.selectedItemID = firstItemID
			return
		}
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

#if canImport(UIKit)
	private struct SessionPickerKeyboardHandler: UIViewRepresentable {
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
			uiView.onMoveSelection = onMoveSelection
			uiView.onMovePage = onMovePage
			uiView.onMoveToBoundary = onMoveToBoundary
			uiView.onActivateSelection = onActivateSelection
			uiView.onClose = onClose
			uiView.activateIfPossible()
		}

		final class KeyCommandView: UIView {
			var onMoveSelection: ((Int) -> Void)?
			var onMovePage: ((Int) -> Void)?
			var onMoveToBoundary: ((Bool) -> Void)?
			var onActivateSelection: (() -> Void)?
			var onClose: (() -> Void)?

			override var canBecomeFirstResponder: Bool { true }

			override var keyCommands: [UIKeyCommand]? {
				[
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
					command(input: UIKeyCommand.inputEscape, modifiers: [], action: #selector(close), title: "Close"),
				]
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
				guard window != nil else { return }
				DispatchQueue.main.async { [weak self] in
					guard let self, self.window != nil else { return }
					_ = self.becomeFirstResponder()
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
#else
	private struct SessionPickerKeyboardHandler: View {
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

#Preview {
	let db = DB.memory()
	try? db.migrate()
	try? db.queue.write { db in
		var primarySession = Session(
			hostname: "prod.example.com",
			username: "pat",
			tmuxSessionName: "api",
			port: 22,
			autoconnect: true,
			customTitle: "Production"
		)
		primarySession.lastConnectedAt = .now
		try primarySession.save(db)

		var secondarySession = Session(
			hostname: "staging.example.com",
			username: "pat",
			tmuxSessionName: nil,
			port: 2222,
			autoconnect: false
		)
		secondarySession.createdAt = Date.now.addingTimeInterval(-43_200)
		try secondarySession.save(db)
	}

	let coordinator = ViewCoordinator()
	return SessionPickerView()
		.databaseContext(.readWrite { db.queue })
		.environment(coordinator)
		.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("New Session Row") {
	SessionPickerView.NewSessionRow(
		isSelected: true,
		onOpen: {},
		onSelect: {}
	)
	.padding()
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#if os(macOS)
#Preview("Local Shell Row") {
	SessionPickerView.LocalShellRow(
		isSelected: true,
		onOpen: {},
		onSelect: {}
	)
	.padding()
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
#endif
