#if os(macOS)
	import Foundation

	struct MacTerminalSceneValue: Hashable, Codable, Identifiable {
		enum Kind: Hashable, Codable {
			case localShell
			case ssh(Session)
		}

		let id: UUID
		let kind: Kind
		let customTitle: String?

		init(id: UUID = UUID(), kind: Kind, customTitle: String? = nil) {
			self.id = id
			self.kind = kind
			self.customTitle = customTitle
		}

		static func localShell(customTitle: String? = nil) -> MacTerminalSceneValue {
			MacTerminalSceneValue(kind: .localShell, customTitle: customTitle)
		}

		static func ssh(_ session: Session, customTitle: String? = nil) -> MacTerminalSceneValue {
			MacTerminalSceneValue(kind: .ssh(session), customTitle: customTitle)
		}

		var terminalSource: MacTerminalTab.Source {
			switch kind {
			case .localShell:
				return .localShell
			case let .ssh(session):
				return .ssh(session)
			}
		}
	}
#endif
