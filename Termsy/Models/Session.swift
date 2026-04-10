//
//  Session.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Foundation
import GRDB

struct Session: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable,
	Hashable, Sendable
{
	var id: Int64?
	var hostname: String
	var username: String
	var tmuxSessionName: String?
	var customTitle: String?
	var autoconnect: Bool = true
	var port: Int = 22
	var createdAt: Date
	var lastConnectedAt: Date?

	static let databaseTableName = "session"
}

extension Session {
	enum Columns {
		static let id = Column(CodingKeys.id)
		static let hostname = Column(CodingKeys.hostname)
		static let username = Column(CodingKeys.username)
		static let tmuxSessionName = Column(CodingKeys.tmuxSessionName)
		static let customTitle = Column(CodingKeys.customTitle)
		static let autoconnect = Column(CodingKeys.autoconnect)
		static let port = Column(CodingKeys.port)
		static let createdAt = Column(CodingKeys.createdAt)
		static let lastConnectedAt = Column(CodingKeys.lastConnectedAt)
	}

	init(hostname: String, username: String, tmuxSessionName: String?, port: Int, autoconnect: Bool, customTitle: String? = nil) {
		let now = Date()
		self.id = nil
		self.hostname = hostname
		self.username = username
		self.tmuxSessionName = tmuxSessionName
		self.customTitle = customTitle
		self.port = port
		self.autoconnect = autoconnect
		self.createdAt = now
		self.lastConnectedAt = nil
	}

	var normalizedHostname: String {
		hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var normalizedUsername: String {
		username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	var normalizedTmuxSessionName: String {
		tmuxSessionName.map { $0.lowercased() } ?? "-"
	}

	var normalizedTargetKey: String {
		"\(normalizedUsername)@\(normalizedHostname):\(port)#\(normalizedTmuxSessionName)"
	}
}
