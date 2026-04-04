//
//  Keychain.swift
//  Termsy
//

import Foundation
import Security

enum Keychain {
	private static func service() -> String { "com.termsy.ssh" }

	private static func account(for session: Session) -> String {
		"\(session.username)@\(session.hostname):\(session.port)"
	}

	static func password(for session: Session) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service(),
			kSecAttrAccount as String: account(for: session),
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	static func setPassword(_ password: String, for session: Session) {
		let account = account(for: session)
		let data = Data(password.utf8)

		// Try to update first
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

	static func removePassword(for session: Session) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service(),
			kSecAttrAccount as String: account(for: session),
		]
		SecItemDelete(query as CFDictionary)
	}
}
