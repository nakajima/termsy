//
//  Keychain.swift
//  Termsy
//

import Foundation
import Security

enum Keychain {
	private nonisolated static func service() -> String { "com.termsy.ssh" }

	private nonisolated static func hostAccount(for session: Session) -> String {
		"host:\(session.normalizedSSHHostKey)"
	}

	private nonisolated static func sessionAccount(for session: Session) -> String? {
		guard let id = session.id else { return nil }
		return "session:\(id)"
	}

	private nonisolated static func normalizedTargetAccount(for session: Session) -> String {
		"target:\(session.normalizedTargetKey)"
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
		let canonicalAccount = hostAccount(for: session)
		if let password = readPassword(account: canonicalAccount) {
			removeLegacyPasswords(for: session)
			return password
		}

		for account in legacyAccounts(for: session) {
			guard let password = readPassword(account: account) else { continue }
			if upsertPassword(password, account: canonicalAccount) {
				removeLegacyPasswords(for: session)
			}
			return password
		}

		return nil
	}

	nonisolated static func setPassword(_ password: String, for session: Session) {
		if upsertPassword(password, account: hostAccount(for: session)) {
			removeLegacyPasswords(for: session)
		}
	}

	nonisolated static func removePassword(for session: Session, preservingHostPassword: Bool = false) {
		if !preservingHostPassword {
			removePassword(account: hostAccount(for: session))
		}
		removeLegacyPasswords(for: session)
	}

	nonisolated static func migratePasswords(for sessions: [Session]) {
		for session in sessions {
			_ = password(for: session)
		}
	}

	nonisolated static func migratePasswordIfNeeded(for session: Session) {
		_ = password(for: session)
	}

	private nonisolated static func legacyAccounts(for session: Session) -> [String] {
		var accounts: [String] = []
		if let sessionAccount = sessionAccount(for: session) {
			accounts.append(sessionAccount)
		}
		accounts.append(normalizedTargetAccount(for: session))

		let tmuxAwareAccount = legacyAccount(for: session)
		let accountWithoutTmux = legacyAccountWithoutTmux(for: session)
		if tmuxAwareAccount != accountWithoutTmux {
			accounts.append(tmuxAwareAccount)
		}
		accounts.append(accountWithoutTmux)
		return accounts
	}

	private nonisolated static func removeLegacyPasswords(for session: Session) {
		for account in legacyAccounts(for: session) {
			removePassword(account: account)
		}
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

	private nonisolated static func upsertPassword(_ password: String, account: String) -> Bool {
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
		if status == errSecSuccess {
			return true
		}
		guard status == errSecItemNotFound else { return false }

		var attrs = query
		attrs[kSecValueData as String] = data
		return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
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
