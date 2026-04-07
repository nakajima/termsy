#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class MacWorkspace {
	var tabs: [MacTerminalTab] = []
	var selectedTabID: UUID?

	var selectedTab: MacTerminalTab? {
		tabs.first { $0.id == selectedTabID }
	}

	func openLocalShellIfNeeded() {
		guard tabs.isEmpty else { return }
		openLocalShell()
	}

	func openLocalShell() {
		let tab = MacTerminalTab(source: .localShell)
		register(tab)
	}

	func openSSH(_ session: Session) {
		if let existing = tabs.first(where: {
			guard case let .ssh(existingSession) = $0.source else { return false }
			return existingSession.uuid == session.uuid
		}) {
			selectedTabID = existing.id
			return
		}

		let tab = MacTerminalTab(source: .ssh(session))
		register(tab)
	}

	func selectTab(_ id: UUID) {
		selectedTabID = id
	}

	func closeTab(_ id: UUID) {
		guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
		let tab = tabs[index]
		tab.close()
		tabs.remove(at: index)

		if selectedTabID == id {
			selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
		}
	}

	private func register(_ tab: MacTerminalTab) {
		tab.onRequestClose = { [weak self, tabID = tab.id] in
			self?.closeTab(tabID)
		}
		tabs.append(tab)
		selectedTabID = tab.id
	}
}
#endif
