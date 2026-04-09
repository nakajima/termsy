import Foundation

public enum GhosttyClipboardConfirmationKind: Equatable {
	case paste
	case osc52Read
	case osc52Write

	public init?(request: ghostty_clipboard_request_e) {
		switch request {
		case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
			self = .paste
		case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
			self = .osc52Read
		case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
			self = .osc52Write
		default:
			return nil
		}
	}

	public var title: String {
		switch self {
		case .paste:
			return "Confirm Paste"
		case .osc52Read:
			return "Allow Clipboard Read"
		case .osc52Write:
			return "Allow Clipboard Write"
		}
	}

	public var message: String {
		switch self {
		case .paste:
			return "Pasting this text to the terminal may be dangerous because it looks like commands may execute immediately."
		case .osc52Read:
			return "An application running in the terminal wants to read from the system clipboard."
		case .osc52Write:
			return "An application running in the terminal wants to write to the system clipboard."
		}
	}

	public var previewLabel: String {
		switch self {
		case .paste:
			return "Paste contents:"
		case .osc52Read:
			return "Clipboard contents:"
		case .osc52Write:
			return "Requested clipboard contents:"
		}
	}

	public var allowButtonTitle: String {
		switch self {
		case .paste:
			return "Paste"
		case .osc52Read:
			return "Allow Read"
		case .osc52Write:
			return "Allow Write"
		}
	}

	public var denyButtonTitle: String {
		switch self {
		case .paste:
			return "Cancel Paste"
		case .osc52Read:
			return "Deny Read"
		case .osc52Write:
			return "Deny Write"
		}
	}

	public func formattedMessage(for text: String, maxPreviewLength: Int = 500) -> String {
		let preview = Self.previewText(text, maxLength: maxPreviewLength)
		return "\(message)\n\n\(previewLabel)\n\(preview)"
	}

	private static func previewText(_ text: String, maxLength: Int) -> String {
		let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
		guard !normalized.isEmpty else { return "(empty)" }
		guard normalized.count > maxLength else { return normalized }
		let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
		return String(normalized[..<endIndex]) + "…"
	}
}
