import GRDB
import GRDBQuery
import SwiftUI

struct SessionsRequest: ValueObservationQueryable {
	static var defaultValue: [Session] { [] }

	func fetch(_ db: Database) throws -> [Session] {
		try Session.fetchSavedSessions(db)
	}
}

struct DirectSessionTarget: Hashable {
	let username: String
	let hostname: String
	let initialWorkingDirectory: String?
	let port: Int
	let tmuxSessionName: String?

	init?(_ input: String) {
		let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else { return nil }

		var tokens = trimmedInput.split(whereSeparator: \.isWhitespace).map(String.init)
		guard var targetText = tokens.first else { return nil }
		tokens.removeFirst()

		var port = 22
		var hasExplicitPort = false
		var tokenIndex = 0
		while tokenIndex < tokens.count {
			let token = tokens[tokenIndex]
			if token == "-p" {
				guard tokenIndex + 1 < tokens.count, let parsedPort = Self.parsePort(tokens[tokenIndex + 1]) else { return nil }
				port = parsedPort
				hasExplicitPort = true
				tokenIndex += 2
			} else if token.hasPrefix("-p"), let parsedPort = Self.parsePort(String(token.dropFirst(2))) {
				port = parsedPort
				hasExplicitPort = true
				tokenIndex += 1
			} else if token.hasPrefix("-"), let parsedPort = Self.parsePort(String(token.dropFirst())) {
				port = parsedPort
				hasExplicitPort = true
				tokenIndex += 1
			} else {
				return nil
			}
		}

		guard let atIndex = targetText.firstIndex(of: "@") else { return nil }

		let username = String(targetText[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
		targetText = String(targetText[targetText.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
		var initialWorkingDirectory: String?
		if let directorySeparator = targetText.firstIndex(of: ":") {
			let suffix = String(targetText[targetText.index(after: directorySeparator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
			guard !suffix.isEmpty else { return nil }
			hostname = String(targetText[..<directorySeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
			if !hasExplicitPort, let legacyPort = Self.parsePort(suffix) {
				port = legacyPort
			} else {
				initialWorkingDirectory = suffix
			}
		}

		guard !hostname.isEmpty, !hostname.contains(" ") else { return nil }
		guard !username.contains(" ") else { return nil }
		guard initialWorkingDirectory?.contains(" ") != true else { return nil }

		self.username = username
		self.hostname = hostname
		self.initialWorkingDirectory = initialWorkingDirectory
		self.port = port
		self.tmuxSessionName = tmuxSessionName
	}

	var session: Session {
		Session(
			hostname: hostname,
			username: username,
			tmuxSessionName: tmuxSessionName,
			initialWorkingDirectory: initialWorkingDirectory,
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

	private static func parsePort(_ text: String) -> Int? {
		guard let port = Int(text), (1 ... 65535).contains(port) else { return nil }
		return port
	}
}

private struct RemoteTmuxSessionLookupTarget: Hashable, Sendable {
	let username: String
	let hostname: String
	let port: Int

	nonisolated init(_ target: DirectSessionTarget) {
		self.username = target.username
		self.hostname = target.hostname
		self.port = target.port
	}

	nonisolated init(_ session: Session) {
		self.username = session.username
		self.hostname = session.hostname
		self.port = session.port
	}

	var normalizedUsername: String {
		username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var normalizedHostname: String {
		hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var displayTarget: String {
		let baseTitle = "\(username)@\(hostname)"
		guard port != 22 else { return baseTitle }
		return "\(baseTitle):\(port)"
	}

	func session(tmuxSessionName: String, initialWorkingDirectory: String?) -> Session {
		Session(
			hostname: hostname,
			username: username,
			tmuxSessionName: tmuxSessionName,
			initialWorkingDirectory: initialWorkingDirectory,
			port: port,
			autoconnect: false
		)
	}
}

private struct RemoteTmuxSessionCandidate: Identifiable, Hashable, Sendable {
	let lookupTarget: RemoteTmuxSessionLookupTarget
	let name: String
	let initialWorkingDirectory: String?

	var session: Session {
		lookupTarget.session(tmuxSessionName: name, initialWorkingDirectory: initialWorkingDirectory)
	}

	var id: String {
		session.normalizedTargetKey
	}
}

private enum RemoteTmuxSessionLookupState: Equatable {
	case idle
	case loading(RemoteTmuxSessionLookupTarget)
	case loaded(RemoteTmuxSessionLookupTarget, [String])
	case failed(RemoteTmuxSessionLookupTarget)
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
		case directConnection(String)
		case remoteTmuxSession(String)
		case session(String)
		case newSession
	}

	@Environment(\.databaseContext) private var dbContext
	@Environment(\.appTheme) private var theme
	@Query(SessionsRequest()) private var sessions: [Session]
	@State private var filterText = ""
	@State private var directConnectError: String?
	@State private var remoteTmuxLookupState: RemoteTmuxSessionLookupState = .idle
	@State private var selectedItemID: ItemID?
	@State private var isFilterFocused = true

	private let variant: Variant
	private let isSessionOpen: (Session) -> Bool
	private let onOpenSession: (Session) -> Void
	private let onOpenNewSession: () -> Void
	private let onClose: () -> Void
	private let onAppearWithSessions: ([Session]) -> Void
	private let selectionPageJump = 8
	private let rowHorizontalSpacing: CGFloat = 8
	private let rowTextSpacing: CGFloat = 2
	private let rowVerticalPadding: CGFloat = 2
	private let denseRowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)

	init(
		variant: Variant,
		isSessionOpen: @escaping (Session) -> Bool = { _ in false },
		onOpenSession: @escaping (Session) -> Void,
		onOpenNewSession: @escaping () -> Void = {},
		onClose: @escaping () -> Void = {},
		onAppearWithSessions: @escaping ([Session]) -> Void = { _ in }
	) {
		self.variant = variant
		self.isSessionOpen = isSessionOpen
		self.onOpenSession = onOpenSession
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
		parsedDirectTarget
	}

	private var remoteTmuxLookupTarget: RemoteTmuxSessionLookupTarget? {
		if let parsedDirectTarget {
			return RemoteTmuxSessionLookupTarget(parsedDirectTarget)
		}

		guard !normalizedFilterText.isEmpty else { return nil }
		let matchingTargets = Set(filteredSessions.map(RemoteTmuxSessionLookupTarget.init))
		guard matchingTargets.count == 1 else { return nil }
		return matchingTargets.first
	}

	private var remoteTmuxNameFilter: String? {
		guard let filter = parsedDirectTarget?.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !filter.isEmpty
		else {
			return nil
		}
		return filter.lowercased()
	}

	private var remoteTmuxSessions: [RemoteTmuxSessionCandidate] {
		guard let lookupTarget = remoteTmuxLookupTarget,
		      case let .loaded(loadedTarget, names) = remoteTmuxLookupState,
		      loadedTarget == lookupTarget
		else {
			return []
		}

		let savedTargetKeys = Set(sessions.map(\.normalizedTargetKey))
		return names.compactMap { name in
			if let remoteTmuxNameFilter, !name.lowercased().contains(remoteTmuxNameFilter) {
				return nil
			}

			let candidate = RemoteTmuxSessionCandidate(
				lookupTarget: lookupTarget,
				name: name,
				initialWorkingDirectory: parsedDirectTarget?.initialWorkingDirectory
			)
			guard !savedTargetKeys.contains(candidate.session.normalizedTargetKey) else { return nil }
			return candidate
		}
	}

	private var isLoadingRemoteTmuxSessions: Bool {
		guard let lookupTarget = remoteTmuxLookupTarget,
		      case let .loading(loadingTarget) = remoteTmuxLookupState
		else {
			return false
		}
		return loadingTarget == lookupTarget
	}

	private var shouldShowLocalShellRow: Bool { false }

	private var visibleItemIDs: [ItemID] {
		var ids: [ItemID] = []
		if let directConnectTarget {
			ids.append(.directConnection(directConnectTarget.normalizedTargetKey))
		}
		ids.append(contentsOf: remoteTmuxSessions.map { .remoteTmuxSession($0.id) })
		for group in groupedSessions {
			ids.append(contentsOf: group.sessions.map { itemID(for: $0) })
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

				if let directConnectTarget {
					Section {
						directConnectionRow(for: directConnectTarget)
					}
				}

				if isLoadingRemoteTmuxSessions {
					Section("Running tmux") {
						remoteTmuxLoadingRow()
					}
				} else if !remoteTmuxSessions.isEmpty {
					Section("Running tmux") {
						ForEach(remoteTmuxSessions) { remoteSession in
							remoteTmuxSessionRow(for: remoteSession)
						}
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
				DispatchQueue.main.async {
					isFilterFocused = true
				}
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
			.task(id: remoteTmuxLookupTarget) {
				await refreshRemoteTmuxSessions(for: remoteTmuxLookupTarget)
			}
		}
	}

	@ViewBuilder
	private func filterField() -> some View {
		VStack(alignment: .leading, spacing: 4) {
			SessionFilterTextField(
				text: $filterText,
				isFocused: $isFilterFocused,
				placeholder: "Filter or connect as user@host[:dir][#tmux] [-2222]",
				textColor: theme.primaryTextUIColor,
				onSubmit: submitFilter,
				onMoveSelection: moveSelection
			)
			.frame(minHeight: 24)
			.accessibilityIdentifier("field.sessionFilter")

			if let directConnectError {
				Text(directConnectError)
					.font(.caption)
					.foregroundStyle(theme.error)
			}
		}
		.listRowInsets(denseRowInsets)
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
			HStack(alignment: .top, spacing: rowHorizontalSpacing) {
				Image(systemName: "bolt.fill")
					.foregroundStyle(theme.accent)
				VStack(alignment: .leading, spacing: rowTextSpacing) {
					Text("Connect to \(target.displayTarget)")
						.font(variant.sessionTitleFont)
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					if let initialWorkingDirectory = target.initialWorkingDirectory {
						Text("cwd: \(initialWorkingDirectory)")
							.font(variant.sessionSubtitleFont)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
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
			.padding(.vertical, rowVerticalPadding)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("row.directSession")
		.accessibilityValue(isSelected ? "selected" : "not selected")
		.listRowInsets(denseRowInsets)
		.listRowBackground(rowBackground(isSelected: isSelected))
		.id(itemID)
	}

	@ViewBuilder
	private func remoteTmuxLoadingRow() -> some View {
		HStack(spacing: rowHorizontalSpacing) {
			ProgressView()
				.controlSize(.small)
			Text("Checking for tmux sessions...")
				.font(variant.sessionSubtitleFont)
				.foregroundStyle(theme.secondaryText)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, rowVerticalPadding)
		.listRowInsets(denseRowInsets)
		.listRowBackground(theme.cardBackground)
	}

	@ViewBuilder
	private func remoteTmuxSessionRow(for remoteSession: RemoteTmuxSessionCandidate) -> some View {
		let itemID = ItemID.remoteTmuxSession(remoteSession.id)
		let isSelected = selectedItemID == itemID
		let session = remoteSession.session

		Button {
			selectedItemID = itemID
			connect(to: session)
		} label: {
			HStack(alignment: .top, spacing: rowHorizontalSpacing) {
				Image(systemName: "terminal")
					.foregroundStyle(theme.accent)
				VStack(alignment: .leading, spacing: rowTextSpacing) {
					Text(remoteSession.name)
						.font(variant.sessionTitleFont)
						.foregroundStyle(theme.primaryText)
						.lineLimit(1)
					Text("Running tmux on \(remoteSession.lookupTarget.displayTarget)")
						.font(variant.sessionSubtitleFont)
						.foregroundStyle(theme.secondaryText)
						.lineLimit(1)
					if let initialWorkingDirectory = remoteSession.initialWorkingDirectory {
						Text("cwd: \(initialWorkingDirectory)")
							.font(variant.sessionSubtitleFont)
							.foregroundStyle(theme.secondaryText)
							.lineLimit(1)
					}
				}
				Spacer(minLength: 0)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, rowVerticalPadding)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("row.remoteTmuxSession.\(session.normalizedTargetKey)")
		.accessibilityValue(isSelected ? "selected" : "not selected")
		.listRowInsets(denseRowInsets)
		.listRowBackground(rowBackground(isSelected: isSelected))
		.id(itemID)
	}


	@ViewBuilder
	private func sessionRow(for session: Session) -> some View {
		let itemID = itemID(for: session)
		let isSelected = selectedItemID == itemID
		let isOpen = variant.showsOpenIndicator && isSessionOpen(session)

		Button {
			selectedItemID = itemID
			onOpenSession(session)
		} label: {
			HStack(alignment: .top, spacing: rowHorizontalSpacing) {
				VStack(alignment: .leading, spacing: rowTextSpacing) {
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
					.font(.caption2)
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
			.padding(.vertical, rowVerticalPadding)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("row.session.\(session.normalizedTargetKey)")
		.accessibilityValue(isSelected ? "selected" : "not selected")
		.listRowInsets(denseRowInsets)
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
				.padding(.vertical, rowVerticalPadding)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.keyboardShortcut("t", modifiers: .command)
		.listRowInsets(denseRowInsets)
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
		case let .directConnection(key):
			guard let target = directConnectTarget, target.normalizedTargetKey == key else {
				ensureValidSelection()
				return
			}
			connect(to: target)
		case let .remoteTmuxSession(key):
			guard let remoteSession = remoteTmuxSessions.first(where: { $0.id == key }) else {
				ensureValidSelection()
				return
			}
			connect(to: remoteSession.session)
		case .session:
			guard let session = sessions.first(where: { itemID(for: $0) == selectedItemID }) else {
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
			connect(to: parsedDirectTarget)
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

	private func itemID(for session: Session) -> ItemID {
		if let id = session.id {
			return .session("id:\(id)")
		}
		return .session("target:\(session.normalizedTargetKey)")
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
			session.trimmedInitialWorkingDirectory,
			String(session.port),
		]
		return searchableValues
			.compactMap { $0?.lowercased() }
			.contains { $0.contains(normalizedFilterText) }
	}

	@MainActor
	private func refreshRemoteTmuxSessions(for lookupTarget: RemoteTmuxSessionLookupTarget?) async {
		guard let lookupTarget else {
			remoteTmuxLookupState = .idle
			return
		}

		remoteTmuxLookupState = .loading(lookupTarget)

		do {
			try await Task.sleep(nanoseconds: 300_000_000)
		} catch {
			return
		}

		do {
			let names = try await RemoteTmuxSessionDiscovery.fetchSessionNames(
				host: lookupTarget.hostname,
				port: lookupTarget.port,
				username: lookupTarget.username,
				password: passwordForRemoteTmuxLookup(lookupTarget)
			)
			guard !Task.isCancelled else { return }
			remoteTmuxLookupState = .loaded(lookupTarget, names)
		} catch {
			guard !Task.isCancelled else { return }
			remoteTmuxLookupState = .failed(lookupTarget)
		}
	}

	private func passwordForRemoteTmuxLookup(_ lookupTarget: RemoteTmuxSessionLookupTarget) -> String? {
		for savedMatch in sessions where savedMatch.normalizedUsername == lookupTarget.normalizedUsername
			&& savedMatch.normalizedHostname == lookupTarget.normalizedHostname
			&& savedMatch.port == lookupTarget.port
		{
			if let password = Keychain.password(for: savedMatch) {
				return password
			}
		}

		let baseSession = Session(
			hostname: lookupTarget.hostname,
			username: lookupTarget.username,
			tmuxSessionName: nil,
			port: lookupTarget.port,
			autoconnect: false
		)
		return Keychain.password(for: baseSession)
	}

	@MainActor
	private func connect(to target: DirectSessionTarget) {
		connect(to: target.session)
	}

	@MainActor
	private func connect(to session: Session) {
		var session = session

		do {
			try dbContext.writer.write { db in
				try session.save(db)
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
	import UIKit

	private struct SessionFilterTextField: UIViewRepresentable {
		@Binding var text: String
		@Binding var isFocused: Bool
		let placeholder: String
		let textColor: PlatformColor
		let onSubmit: () -> Void
		let onMoveSelection: (Int) -> Void

		func makeCoordinator() -> Coordinator {
			Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit, onMoveSelection: onMoveSelection)
		}

		func makeUIView(context: Context) -> KeyHandlingTextField {
			let textField = KeyHandlingTextField()
			textField.borderStyle = .none
			textField.backgroundColor = .clear
			textField.autocorrectionType = .no
			textField.autocapitalizationType = .none
			textField.textContentType = .URL
			textField.returnKeyType = .go
			textField.font = .preferredFont(forTextStyle: .body)
			textField.adjustsFontForContentSizeCategory = true
			textField.delegate = context.coordinator
			textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
			return textField
		}

		func updateUIView(_ uiView: KeyHandlingTextField, context: Context) {
			context.coordinator.text = $text
			context.coordinator.isFocused = $isFocused
			context.coordinator.onSubmit = onSubmit
			context.coordinator.onMoveSelection = onMoveSelection
			uiView.onMoveSelection = onMoveSelection
			uiView.placeholder = placeholder
			uiView.textColor = textColor
			uiView.wantsFocus = isFocused
			if uiView.text != text {
				uiView.text = text
			}
			uiView.focusIfNeeded()
		}

		final class KeyHandlingTextField: UITextField {
			var wantsFocus = false
			var onMoveSelection: ((Int) -> Void)?

			override var keyCommands: [UIKeyCommand]? {
				[
					command(input: "n", action: #selector(moveDown), title: "Move Selection Down"),
					command(input: "p", action: #selector(moveUp), title: "Move Selection Up"),
				]
			}

			override func didMoveToWindow() {
				super.didMoveToWindow()
				focusIfNeeded()
			}

			override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
				guard !handleControlPresses(presses) else { return }
				super.pressesBegan(presses, with: event)
			}

			func focusIfNeeded() {
				guard wantsFocus, window != nil, !isFirstResponder else { return }
				DispatchQueue.main.async { [weak self] in
					guard let self, self.wantsFocus, self.window != nil, !self.isFirstResponder else { return }
					_ = self.becomeFirstResponder()
				}
			}

			private func command(input: String, action: Selector, title: String) -> UIKeyCommand {
				let command = UIKeyCommand(input: input, modifierFlags: .control, action: action)
				command.wantsPriorityOverSystemBehavior = true
				command.discoverabilityTitle = title
				return command
			}

			private func handleControlPresses(_ presses: Set<UIPress>) -> Bool {
				for press in presses {
					guard let key = press.key else { continue }
					let modifiers = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
					guard modifiers == .control else { continue }

					switch key.keyCode {
					case .keyboardN:
						onMoveSelection?(1)
						return true
					case .keyboardP:
						onMoveSelection?(-1)
						return true
					default:
						break
					}

					switch key.charactersIgnoringModifiers.lowercased() {
					case "n":
						onMoveSelection?(1)
						return true
					case "p":
						onMoveSelection?(-1)
						return true
					default:
						break
					}
				}

				return false
			}

			@objc private func moveDown() { onMoveSelection?(1) }
			@objc private func moveUp() { onMoveSelection?(-1) }
		}

		final class Coordinator: NSObject, UITextFieldDelegate {
			var text: Binding<String>
			var isFocused: Binding<Bool>
			var onSubmit: () -> Void
			var onMoveSelection: (Int) -> Void

			init(
				text: Binding<String>,
				isFocused: Binding<Bool>,
				onSubmit: @escaping () -> Void,
				onMoveSelection: @escaping (Int) -> Void
			) {
				self.text = text
				self.isFocused = isFocused
				self.onSubmit = onSubmit
				self.onMoveSelection = onMoveSelection
			}

			@objc func textDidChange(_ sender: UITextField) {
				text.wrappedValue = sender.text ?? ""
			}

			func textFieldDidBeginEditing(_: UITextField) {
				isFocused.wrappedValue = true
			}

			func textFieldDidEndEditing(_: UITextField) {
				isFocused.wrappedValue = false
			}

			func textField(
				_: UITextField,
				shouldChangeCharactersIn _: NSRange,
				replacementString string: String
			) -> Bool {
				switch string {
				case "\u{0E}":
					onMoveSelection(1)
					return false
				case "\u{10}":
					onMoveSelection(-1)
					return false
				default:
					return true
				}
			}

			func textFieldShouldReturn(_: UITextField) -> Bool {
				onSubmit()
				return false
			}
		}
	}

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
