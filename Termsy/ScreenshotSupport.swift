import Foundation
import GRDB

struct AppLaunchConfiguration {
	enum ScreenshotScenario: String {
		case savedSessions = "saved-sessions"
		case newSession = "new-session"
		case terminal
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
		UserDefaults.standard.set("luke", forKey: "lastUsername")
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
	static let primaryHostname = "bandit.labs.overthewire.org"

	static func sampleSessions() -> [Session] {
		let baseDate = Date(timeIntervalSince1970: 1_776_000_000)
		return [
			configuredSession(
				username: "bandi0",
				hostname: "bandit.labs.overthewire.org",
				port: 2220,
				createdAt: baseDate
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

		bandi0@bandit:~$ cat ~/servers.txt
		bandi0@bandit.labs.overthewire.org -p 2220
		luke@starwarstel.net
		nethack@alt.org
		root@pimux

		bandi0@bandit:~$ printf 'ssh -p 2220 bandi0@bandit.labs.overthewire.org\\n'
		ssh -p 2220 bandi0@bandit.labs.overthewire.org

		bandi0@bandit:~$ ls --color=always
		\(esc)[34mnotes\(esc)[0m  \(esc)[32mreadme\(esc)[0m  \(esc)[36mscripts\(esc)[0m

		bandi0@bandit:~$ cat readme
		Welcome to OverTheWire Bandit.
		Use the saved sessions on the left, open a new session with ⌘T,
		and keep your favorite hosts one tap away.

		bandi0@bandit:~$ echo $TERM
		xterm-ghostty

		bandi0@bandit:~$ _
		""")
	}

	private static func normalizedTerminalPreviewTranscript(_ transcript: String) -> String {
		// Terminal output needs CRLF for a visual “new line”; a bare LF only moves the
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
		createdAt: Date
	) -> Session {
		var session = Session(
			hostname: hostname,
			username: username,
			tmuxSessionName: nil,
			port: port,
			autoconnect: false
		)
		session.createdAt = createdAt
		session.lastConnectedAt = createdAt
		return session
	}
}
