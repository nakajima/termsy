#if os(macOS)
import Foundation

struct MacTerminalSceneValue: Hashable, Codable, Identifiable {
	enum Kind: Hashable, Codable {
		case localShell
		case ssh(Session)
	}

	let id: UUID
	let kind: Kind

	init(id: UUID = UUID(), kind: Kind) {
		self.id = id
		self.kind = kind
	}

	static func localShell() -> MacTerminalSceneValue {
		MacTerminalSceneValue(kind: .localShell)
	}

	static func ssh(_ session: Session) -> MacTerminalSceneValue {
		MacTerminalSceneValue(kind: .ssh(session))
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
