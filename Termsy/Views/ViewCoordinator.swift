//
//  ViewCoordinator.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import GRDB
import GRDBQuery
import Observation
import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif

@Observable @MainActor
class ViewCoordinator {
	private enum WorkspacePersistence {
		static let selectedSessionIDKey = "workspace.selectedSessionID"
	}

	var path = NavigationPath()
	var isShowingConnectView = false {
		didSet { refreshDisplayActivity() }
	}

	var isShowingSessionPicker = false {
		didSet { refreshDisplayActivity() }
	}

	var isShowingSettings = false {
		didSet { refreshDisplayActivity() }
	}

	var isPresentingAuxiliaryUI: Bool {
		isShowingConnectView || isShowingSessionPicker || isShowingSettings
	}

	private struct PersistedTerminalSnapshot {
		let sessionID: Int64
		let jpegData: Data
	}

	private var appIsActive = true
	private var databaseContext: DatabaseContext?
	private var isRestoringSavedWorkspace = false

	/// All open terminal tabs.
	var tabs: [TerminalTab] = []

	/// The currently selected tab, or nil if showing the session list.
	var selectedTabID: UUID?

	var selectedTab: TerminalTab? {
		tabs.first { $0.id == selectedTabID }
	}

	func configureDatabaseContext(_ databaseContext: DatabaseContext) {
		self.databaseContext = databaseContext
	}

	func restoreSavedWorkspace() {
		guard tabs.isEmpty else { return }
		guard let databaseContext else { return }

		let sessions: [Session]
		do {
			sessions = try databaseContext.reader.read { db in
				try Session.filter { $0.isOpen == true }.fetchAll(db)
			}
		} catch {
			print("[DB] failed to read saved workspace state: \(error)")
			return
		}

		isRestoringSavedWorkspace = true
		defer {
			isRestoringSavedWorkspace = false
			persistWorkspaceStateIfPossible()
		}

		for session in orderedWorkspaceSessions(sessions) {
			open(tab: TerminalTab(session: session), persistWorkspace: false)
		}

		guard let selectedSessionID = persistedSelectedSessionID else { return }
		guard let selectedTab = tabs.first(where: { $0.session?.id == selectedSessionID }) else {
			persistedSelectedSessionID = nil
			return
		}
		selectTab(selectedTab.id, persistWorkspace: false)
	}

	func openTab(for session: Session) {
		open(tab: TerminalTab(session: session))
	}

	func openPassivePreviewTab(
		for session: Session,
		transcript: String,
		screenshotReadyLabel: String? = nil
	) {
		let tab = TerminalTab(session: session)
		tab.preparePassivePreview(transcript: transcript, screenshotReadyLabel: screenshotReadyLabel)
		open(tab: tab)
	}

	#if os(macOS)
		func openLocalShellTab(profile: LocalShellProfile = .default) {
			open(tab: TerminalTab(localShellProfile: profile))
		}
	#endif

	private func open(tab: TerminalTab, persistWorkspace: Bool = true) {
		let tabID = tab.id
		tab.onRequestClose = { [weak self] in
			self?.closeTab(tabID)
		}
		tab.onRequestNewTab = { [weak self] in
			self?.openNewTabUI()
		}
		tab.onRequestSelectTab = { [weak self] index in
			self?.selectTabNumber(index)
		}
		tab.onRequestMoveTabSelection = { [weak self] offset in
			self?.moveTabSelection(by: offset)
		}
		tab.onRequestShowSettings = { [weak self] in
			self?.openSettings()
		}
		tab.onRequestDismissAuxiliaryUI = { [weak self] in
			self?.dismissPresentedUI() ?? false
		}
		tab.onConnectionEstablished = { [weak self] session in
			self?.persistLastConnectedAt(session)
		}
		tabs.append(tab)
		selectTab(tab.id, persistWorkspace: false)
		if persistWorkspace {
			persistWorkspaceStateIfPossible()
		}
	}

	func openSettings() {
		isShowingConnectView = false
		isShowingSessionPicker = false
		isShowingSettings = true
	}

	func openNewTabUI() {
		isShowingSettings = false
		if tabs.isEmpty {
			isShowingConnectView = true
			isShowingSessionPicker = false
		} else {
			isShowingConnectView = false
			isShowingSessionPicker = true
		}
	}

	@discardableResult
	func dismissPresentedUI() -> Bool {
		if isShowingSettings {
			isShowingSettings = false
			return true
		}
		if isShowingConnectView {
			isShowingConnectView = false
			return true
		}
		if isShowingSessionPicker {
			isShowingSessionPicker = false
			return true
		}
		return false
	}

	func appWillResignActive() {
		appIsActive = false
		ApplicationActivity.isActive = false
		for tab in tabs {
			tab.noteAppWillResignActive()
		}
		refreshDisplayActivity()
	}

	func appDidEnterBackground() {
		appIsActive = false
		ApplicationActivity.isActive = false
		for tab in tabs {
			tab.noteAppDidEnterBackground()
		}
		#if canImport(UIKit)
			persistWorkspaceStateIfPossible(snapshotRecords: capturePersistedTerminalSnapshots())
		#else
			persistWorkspaceStateIfPossible()
		#endif
		let backgroundExecutionTabs = tabs.filter(\.shouldRequestBackgroundExecution)
		if !backgroundExecutionTabs.isEmpty {
			let alreadyActive = ApplicationActivity.hasBackgroundExecution
			ApplicationActivity.onBackgroundExecutionExpiration = { [weak self] remaining in
				self?.noteBackgroundExecutionExpired(remaining: remaining)
			}
			let granted = ApplicationActivity.beginBackgroundExecution(name: "Teletype SSH")
			let remaining = ApplicationActivity.backgroundTimeRemaining
			for tab in backgroundExecutionTabs {
				tab.noteBackgroundExecutionRequested(
					granted: granted,
					alreadyActive: alreadyActive,
					remaining: remaining
				)
			}
		}
		refreshDisplayActivity()
	}

	func appDidBecomeActive() {
		appIsActive = true
		ApplicationActivity.isActive = true
		let hadBackgroundExecution = ApplicationActivity.hasBackgroundExecution
		let remaining = ApplicationActivity.backgroundTimeRemaining
		ApplicationActivity.endBackgroundExecution()
		ApplicationActivity.onBackgroundExecutionExpiration = nil
		if hadBackgroundExecution {
			for tab in tabs {
				tab.noteBackgroundExecutionEnded(remainingBeforeEnd: remaining)
			}
		}
		for tab in tabs {
			tab.noteAppDidBecomeActive()
		}
		refreshDisplayActivity()
	}

	private func noteBackgroundExecutionExpired(remaining: TimeInterval?) {
		for tab in tabs {
			tab.noteBackgroundExecutionExpired(remaining: remaining)
		}
	}

	func selectTab(_ id: UUID?, persistWorkspace: Bool = true) {
		let previousID = selectedTabID
		selectedTabID = id

		if let previousID, previousID != id,
		   let prevTab = tabs.first(where: { $0.id == previousID })
		{
			prevTab.enterBackground()
		}

		if let id, let tab = tabs.first(where: { $0.id == id }) {
			tab.enterForeground()
		}

		refreshDisplayActivity()
		if persistWorkspace {
			persistWorkspaceStateIfPossible()
		}
	}

	func selectTabNumber(_ number: Int) {
		guard number >= 1, number <= tabs.count else { return }
		selectTab(tabs[number - 1].id)
	}

	func moveTabSelection(by offset: Int) {
		guard !tabs.isEmpty, offset != 0 else { return }
		guard let selectedTabID,
		      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
		else {
			let fallbackIndex = offset > 0 ? 0 : tabs.count - 1
			selectTab(tabs[fallbackIndex].id)
			return
		}

		let wrappedOffset = offset % tabs.count
		let nextIndex = (selectedIndex + wrappedOffset + tabs.count) % tabs.count
		selectTab(tabs[nextIndex].id)
	}

	func closeTab(_ id: UUID?) {
		guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
		let tab = tabs[index]
		stopRecording(tabID: id)
		tab.close()
		tabs.remove(at: index)

		if selectedTabID == id {
			if tabs.isEmpty {
				selectedTabID = nil
				refreshDisplayActivity()
			} else {
				let newIndex = min(index, tabs.count - 1)
				selectTab(tabs[newIndex].id, persistWorkspace: false)
			}
		}
		persistWorkspaceStateIfPossible()
	}

	func closeOtherTabs(_ id: UUID?) {
		let toClose = tabs.filter { $0.id != id }
		for tab in toClose {
			stopRecording(tabID: tab.id)
			tab.close()
		}
		tabs.removeAll { $0.id != id }
		if let id {
			selectTab(id, persistWorkspace: false)
		} else {
			selectedTabID = nil
			refreshDisplayActivity()
		}
		persistWorkspaceStateIfPossible()
	}

	func renameTab(_ id: UUID?, to title: String?) {
		guard let id, let tab = tabs.first(where: { $0.id == id }) else { return }
		tab.rename(to: title)
	}

	@discardableResult
	func startRecording(tabID: UUID) -> URL? {
		guard let databaseContext else { return nil }
		guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
		guard !tab.isRecording else { return tab.recordingFileURL }

		var recording = tab.makeRecordingMetadata(startedAt: Date())
		do {
			try databaseContext.writer.write { db in
				try recording.save(db)
			}
			let recorder = try TerminalSessionRecorder(recording: recording)
			tab.startRecording(recorder)
			return recorder.fileURL
		} catch {
			if let id = recording.id {
				try? databaseContext.writer.write { db in
					_ = try TerminalRecording.deleteOne(db, key: id)
				}
			}
			print("[Recording] failed to start: \(error)")
			return nil
		}
	}

	@discardableResult
	func stopRecording(tabID: UUID) -> URL? {
		guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
		guard let completed = tab.stopRecording() else { return nil }
		persistCompletedRecording(completed)
		return completed.fileURL
	}

	private func persistLastConnectedAt(_ session: Session) {
		guard let databaseContext else { return }
		do {
			try databaseContext.writer.write { db in
				try db.execute(
					sql: "UPDATE session SET lastConnectedAt = ? WHERE id = ?",
					arguments: [session.lastConnectedAt ?? Date(), session.id]
				)
			}
		} catch {
			print("[DB] failed to persist lastConnectedAt for \(session.username)@\(session.hostname): \(error)")
		}
	}

	private func persistCompletedRecording(_ completed: TerminalSessionRecorder.Completed) {
		guard let databaseContext else { return }
		do {
			try databaseContext.writer.write { db in
				let recording = completed.recording
				try recording.update(db)
			}
		} catch {
			print("[Recording] failed to persist completed recording: \(error)")
		}
	}

	func moveTab(from source: IndexSet, to destination: Int) {
		tabs.move(fromOffsets: source, toOffset: destination)
		persistWorkspaceStateIfPossible()
	}

	func reorderTabs(_ orderedIDs: [UUID]) {
		var reordered: [TerminalTab] = []
		for id in orderedIDs {
			if let tab = tabs.first(where: { $0.id == id }) {
				reordered.append(tab)
			}
		}
		tabs = reordered
		persistWorkspaceStateIfPossible()
	}

	private func orderedWorkspaceSessions(_ sessions: [Session]) -> [Session] {
		sessions.sorted { lhs, rhs in
			let lhsOrder = lhs.tabOrder ?? Int.max
			let rhsOrder = rhs.tabOrder ?? Int.max
			if lhsOrder != rhsOrder {
				return lhsOrder < rhsOrder
			}
			if lhs.createdAt != rhs.createdAt {
				return lhs.createdAt < rhs.createdAt
			}
			return lhs.normalizedTargetKey < rhs.normalizedTargetKey
		}
	}

	private var persistedSelectedSessionID: Int64? {
		get {
			(UserDefaults.standard.object(forKey: WorkspacePersistence.selectedSessionIDKey) as? NSNumber)?.int64Value
		}
		set {
			if let newValue {
				UserDefaults.standard.set(NSNumber(value: newValue), forKey: WorkspacePersistence.selectedSessionIDKey)
			} else {
				UserDefaults.standard.removeObject(forKey: WorkspacePersistence.selectedSessionIDKey)
			}
		}
	}

	private func persistWorkspaceStateIfPossible(snapshotRecords: [PersistedTerminalSnapshot] = []) {
		guard !isRestoringSavedWorkspace else { return }
		guard let databaseContext else { return }

		let openSessions = tabs.enumerated().compactMap { index, tab -> (sessionID: Int64, tabOrder: Int)? in
			guard let sessionID = tab.session?.id else { return nil }
			return (sessionID: sessionID, tabOrder: index)
		}

		do {
			try databaseContext.writer.write { db in
				try db.execute(sql: "UPDATE session SET isOpen = 0, tabOrder = NULL")
				for openSession in openSessions {
					try db.execute(
						sql: "UPDATE session SET isOpen = 1, tabOrder = ? WHERE id = ?",
						arguments: [openSession.tabOrder, openSession.sessionID]
					)
				}
				for snapshotRecord in snapshotRecords {
					try db.execute(
						sql: "UPDATE session SET lastTerminalSnapshotJPEGData = ? WHERE id = ?",
						arguments: [snapshotRecord.jpegData, snapshotRecord.sessionID]
					)
				}
			}
			persistedSelectedSessionID = selectedTab?.session?.id
		} catch {
			print("[DB] failed to persist workspace state: \(error)")
		}
	}

	#if canImport(UIKit)
		private func capturePersistedTerminalSnapshots() -> [PersistedTerminalSnapshot] {
			tabs.compactMap { tab in
				guard let sessionID = tab.session?.id,
				      let jpegData = tab.capturePersistedSnapshotJPEGData()
				else {
					return nil
				}
				return PersistedTerminalSnapshot(sessionID: sessionID, jpegData: jpegData)
			}
		}
	#endif

	private func refreshDisplayActivity() {
		let activeTabID = appIsActive && !isPresentingAuxiliaryUI ? selectedTabID : nil
		for tab in tabs {
			tab.setDisplayActive(tab.id == activeTabID)
		}
	}
}
