//
//  Keychain.swift
//  Termsy
//

import Foundation
import Security

enum Keychain {
	private nonisolated static func service() -> String { "com.termsy.ssh" }

	private nonisolated static func account(for session: Session) -> String {
		"session:\(session.id ?? 0)"
	}

	private nonisolated static func legacyAccount(for session: Session) -> String {
		let base = legacyAccountWithoutTmux(for: session)
		guard let tmuxSessionName = session.tmuxSessionName?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!tmuxSessionName.isEmpty
		else {
			return base
		}

		return "\(base)#\(tmuxSessionName)"
	}

	private nonisolated static func legacyAccountWithoutTmux(for session: Session) -> String {
		"\(session.username)@\(session.hostname):\(session.port)"
	}

	nonisolated static func password(for session: Session) -> String? {
		if let password = readPassword(account: account(for: session)) {
			return password
		}

		let tmuxAwareLegacyAccount = legacyAccount(for: session)
		if let legacyPassword = readPassword(account: tmuxAwareLegacyAccount) {
			setPassword(legacyPassword, for: session)
			removePassword(account: tmuxAwareLegacyAccount)
			return legacyPassword
		}

		guard session.normalizedTmuxSessionName == nil,
		      let legacyPassword = readPassword(account: legacyAccountWithoutTmux(for: session))
		else {
			return nil
		}

		setPassword(legacyPassword, for: session)
		removePassword(account: legacyAccountWithoutTmux(for: session))
		return legacyPassword
	}

	nonisolated static func setPassword(_ password: String, for session: Session) {
		upsertPassword(password, account: account(for: session))
	}

	nonisolated static func removePassword(for session: Session) {
		removePassword(account: account(for: session))
		removePassword(account: legacyAccount(for: session))
		removePassword(account: legacyAccountWithoutTmux(for: session))
	}

	nonisolated static func movePasswordIfNeeded(from source: Session, to destination: Session) {
		if password(for: destination) != nil {
			removePassword(for: source)
			return
		}

		guard let password = password(for: source) else { return }
		setPassword(password, for: destination)
		removePassword(for: source)
	}

	private nonisolated static func readPassword(account: String) -> String? {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service(),
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		#if os(macOS)
			// Avoid system keychain auth UI during automatic connection attempts.
			// If the item requires user interaction, treat it as unavailable and
			// fall back to the app's password prompt instead of stalling connect.
			query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
		#endif

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	private nonisolated static func upsertPassword(_ password: String, account: String) {
		let data = Data(password.utf8)
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service(),
			kSecAttrAccount as String: account,
		]
		let update: [String: Any] = [
			kSecValueData as String: data,
		]
		let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

		if status == errSecItemNotFound {
			var attrs = query
			attrs[kSecValueData as String] = data
			SecItemAdd(attrs as CFDictionary, nil)
		}
	}

	private nonisolated static func removePassword(account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service(),
			kSecAttrAccount as String: account,
		]
		SecItemDelete(query as CFDictionary)
	}
}
