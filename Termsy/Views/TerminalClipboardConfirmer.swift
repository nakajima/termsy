#if canImport(UIKit)
//
//  TerminalClipboardConfirmer.swift
//  Termsy
//
//  Queues clipboard read/write confirmation prompts from ghostty
//  and presents them one at a time as UIAlertControllers.
//

import TermsyGhosttyCore
import UIKit

@MainActor
final class TerminalClipboardConfirmer {
	private enum Action {
		case read(state: UnsafeMutableRawPointer, request: ghostty_clipboard_request_e)
		case write
	}

	private struct PendingConfirmation {
		let id = UUID()
		let kind: GhosttyClipboardConfirmationKind
		let text: String
		let action: Action
	}

	private var pending: [PendingConfirmation] = []
	private var active: PendingConfirmation?
	private weak var alertController: UIAlertController?

	private let presenter: () -> UIViewController?
	private let surface: () -> ghostty_surface_t?

	init(
		presenter: @escaping () -> UIViewController?,
		surface: @escaping () -> ghostty_surface_t?
	) {
		self.presenter = presenter
		self.surface = surface
	}

	func requestRead(
		text: String,
		state: UnsafeMutableRawPointer,
		request: ghostty_clipboard_request_e
	) {
		guard let kind = GhosttyClipboardConfirmationKind(request: request) else {
			// Unrecognized request kind: complete with empty payload so ghostty doesn't hang.
			guard let surface = surface() else { return }
			"".withCString { cString in
				ghostty_surface_complete_clipboard_request(surface, cString, state, true)
			}
			return
		}

		pending.append(
			PendingConfirmation(
				kind: kind,
				text: text,
				action: .read(state: state, request: request)
			)
		)
		presentNext()
	}

	func requestWrite(text: String) {
		pending.append(
			PendingConfirmation(
				kind: .osc52Write,
				text: text,
				action: .write
			)
		)
		presentNext()
	}

	func denyOutstandingReadConfirmations() {
		let confirmations = [active].compactMap { $0 } + pending
		if let surface = surface() {
			for confirmation in confirmations {
				if case let .read(state, _) = confirmation.action {
					"".withCString { cString in
						ghostty_surface_complete_clipboard_request(surface, cString, state, true)
					}
				}
			}
		}
		active = nil
		pending.removeAll()
		alertController?.dismiss(animated: false)
		alertController = nil
	}

	private func presentNext() {
		guard active == nil, !pending.isEmpty else { return }

		let confirmation = pending.removeFirst()
		active = confirmation

		guard let presenter = presenter() else {
			resolve(confirmation, allowed: false)
			return
		}

		let alert = UIAlertController(
			title: confirmation.kind.title,
			message: confirmation.kind.formattedMessage(for: confirmation.text),
			preferredStyle: .alert
		)
		alert.addAction(
			UIAlertAction(title: confirmation.kind.denyButtonTitle, style: .cancel) { [weak self] _ in
				self?.resolve(confirmation, allowed: false)
			}
		)
		alert.addAction(
			UIAlertAction(title: confirmation.kind.allowButtonTitle, style: .default) { [weak self] _ in
				self?.resolve(confirmation, allowed: true)
			}
		)
		alertController = alert
		presenter.present(alert, animated: true)
	}

	private func resolve(_ confirmation: PendingConfirmation, allowed: Bool) {
		guard active?.id == confirmation.id else { return }

		switch confirmation.action {
		case let .read(state, _):
			guard let surface = surface() else {
				finish(confirmation)
				return
			}
			let responseText = allowed ? confirmation.text : ""
			responseText.withCString { cString in
				ghostty_surface_complete_clipboard_request(surface, cString, state, true)
			}

		case .write:
			if allowed {
				UIPasteboard.general.string = confirmation.text
			}
		}

		finish(confirmation)
	}

	private func finish(_ confirmation: PendingConfirmation) {
		guard active?.id == confirmation.id else { return }
		active = nil
		alertController = nil
		presentNext()
	}
}
#endif
