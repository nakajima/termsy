//
//  Session.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/3/26.
//

import Foundation
import GRDB

struct Session: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable,
	Hashable
{
	var id: Int64?
	var hostname: String
	var username: String
	var tmuxSessionName: String?
	var autoconnect: Bool = true
	var port: Int = 22
	var createdAt: Date
	var lastConnectedAt: Date?
}

extension Session {
	init(hostname: String, username: String, tmuxSessionName: String?, port: Int, autoconnect: Bool) {
		self.hostname = hostname
		self.username = username
		self.tmuxSessionName = tmuxSessionName
		self.port = port
		self.autoconnect = autoconnect
		self.createdAt = Date()
	}
}
