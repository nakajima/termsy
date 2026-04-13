#if os(macOS)
	import Foundation

	struct MacTerminalWindowLayoutState: Codable {
		struct Group: Codable {
			let tabs: [MacTerminalSceneValue]
			let selectedTabID: UUID?
			let frame: CGRect?
		}

		let groups: [Group]
		let frontmostTabID: UUID?
	}
#endif
