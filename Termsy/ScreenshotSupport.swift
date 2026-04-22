import Foundation
import GRDB

struct AppLaunchConfiguration {
	enum ScreenshotScenario: String {
		case savedSessions = "saved-sessions"
		case newSession = "new-session"
		case terminal
		case backgroundReconnect = "background-reconnect"
		case sessionPicker = "session-picker"
		case settings
	}

	let screenshotScenario: ScreenshotScenario?
	let screenshotDatabasePath: String?

	static let current = AppLaunchConfiguration(environment: ProcessInfo.processInfo.environment)

	init(environment: [String: String]) {
		self.screenshotScenario = environment["TERMSY_SCREENSHOT_SCENARIO"].flatMap(ScreenshotScenario.init(rawValue:))
		self.screenshotDatabasePath = environment["TERMSY_SCREENSHOT_DB_PATH"]
	}

	var isScreenshotMode: Bool {
		screenshotScenario != nil
	}

	var databasePath: String {
		screenshotDatabasePath ?? URL.documentsDirectory.appending(path: "termsy.db").path
	}

	func preparePersistentStateIfNeeded(using db: DB) {
		guard isScreenshotMode else { return }
		configureDefaultsForScreenshotMode()
		seedScreenshotSessions(in: db)
	}


	private func configureDefaultsForScreenshotMode() {
		UserDefaults.standard.set(TerminalTheme.mocha.rawValue, forKey: "terminalTheme")
		UserDefaults.standard.set("block", forKey: "cursorStyle")
		UserDefaults.standard.set(false, forKey: "cursorBlink")
		UserDefaults.standard.set("user", forKey: "lastUsername")
		UserDefaults.standard.set("", forKey: TerminalFontSettings.familyKey)
	}

	private func seedScreenshotSessions(in db: DB) {
		do {
			try db.queue.write { database in
				try database.execute(sql: "DELETE FROM session")
				for session in AppStoreScreenshotFixtures.sampleSessions() {
					var session = session
					try session.save(database)
				}
			}
		} catch {
			print("[Screenshots] failed to seed sessions: \(error)")
		}
	}
}

enum AppStoreScreenshotFixtures {
	static let primaryHostname = "my.teletype.computer"

	static func sampleSessions() -> [Session] {
		let baseDate = Date(timeIntervalSince1970: 1_776_000_000)
		return [
			configuredSession(
				username: "user",
				hostname: "my.teletype.computer",
				port: 2222,
				createdAt: baseDate,
				customTitle: "user@my.teletype.computer -p 2222"
			),
			configuredSession(
				username: "luke",
				hostname: "starwarstel.net",
				port: 22,
				createdAt: baseDate.addingTimeInterval(1)
			),
			configuredSession(
				username: "nethack",
				hostname: "alt.org",
				port: 22,
				createdAt: baseDate.addingTimeInterval(2)
			),
			configuredSession(
				username: "root",
				hostname: "pimux",
				port: 22,
				createdAt: baseDate.addingTimeInterval(3)
			),
		]
	}

	static var terminalTranscript: String {
		let esc = "\u{001B}"
		return normalizedTerminalPreviewTranscript("""
		\(esc)[2J\(esc)[H\(esc)[35;1mTeletype demo session\(esc)[0m

		user@teletype:~$ cat ~/servers.txt
		user@my.teletype.computer -p 2222
		luke@starwarstel.net
		nethack@alt.org
		root@pimux

		user@teletype:~$ printf 'ssh -p 2222 user@my.teletype.computer\\n'
		ssh -p 2222 user@my.teletype.computer

		user@teletype:~$ ls --color=always
		\(esc)[34mnotes\(esc)[0m  \(esc)[32mreadme\(esc)[0m  \(esc)[36mscripts\(esc)[0m

		user@teletype:~$ cat readme
		Welcome to Teletype.
		Use the saved sessions on the left, open a new session with ⌘T,
		and keep your favorite hosts one tap away.

		user@teletype:~$ echo $TERM
		xterm-ghostty

		user@teletype:~$ _
		""")
	}

	private static func normalizedTerminalPreviewTranscript(_ transcript: String) -> String {
		// Terminal output needs CRLF for a visual "new line"; a bare LF only moves the
		// cursor down and keeps the current column, which makes the canned preview text
		// stair-step diagonally across the screenshot.
		transcript
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.replacingOccurrences(of: "\n", with: "\r\n")
	}

	private static func configuredSession(
		username: String,
		hostname: String,
		port: Int,
		createdAt: Date,
		customTitle: String? = nil
	) -> Session {
		var session = Session(
			hostname: hostname,
			username: username,
			tmuxSessionName: nil,
			port: port,
			autoconnect: false,
			customTitle: customTitle
		)
		session.createdAt = createdAt
		session.lastConnectedAt = createdAt
		return session
	}
}
