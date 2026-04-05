//
//  TermsyTests.swift
//  TermsyTests
//
//  Created by Pat Nakajima on 4/2/26.
//

@testable import Termsy
import Testing

struct TermsyTests {
	@MainActor
	@Test func moveTabSelectionWrapsAcrossOpenTabs() {
		let coordinator = ViewCoordinator()
		let sessions = [
			Session(hostname: "one.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "two.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false),
			Session(hostname: "three.example.com", username: "pat", tmuxSessionName: nil, port: 22, autoconnect: false)
		]

		sessions.forEach { coordinator.openTab(for: $0) }
		let ids = coordinator.tabs.map(\.id)

		coordinator.selectTab(ids[1])
		coordinator.moveTabSelection(by: 1)
		#expect(coordinator.selectedTabID == ids[2])

		coordinator.moveTabSelection(by: 1)
		#expect(coordinator.selectedTabID == ids[0])

		coordinator.moveTabSelection(by: -1)
		#expect(coordinator.selectedTabID == ids[2])
	}
}
