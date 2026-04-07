import Darwin
import Foundation

struct LocalShellProfile: Hashable, Sendable {
	var displayName: String
	var shellPath: String
	var workingDirectory: String

	static var defaultShellPath: String {
		if let pw = getpwuid(getuid()),
		   let shell = pw.pointee.pw_shell,
		   shell.pointee != 0 {
			return String(cString: shell)
		}
		return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
	}

	init(
		displayName: String = "Local Shell",
		shellPath: String = LocalShellProfile.defaultShellPath,
		workingDirectory: String = NSHomeDirectory()
	) {
		self.displayName = displayName
		self.shellPath = shellPath
		self.workingDirectory = workingDirectory
	}

	static let `default` = LocalShellProfile()

	var shellName: String {
		URL(fileURLWithPath: shellPath).lastPathComponent
	}

	var detailText: String {
		"\(shellName) • \(workingDirectory)"
	}
}

enum TerminalEndpoint: Hashable, Sendable {
	case remote
	case localShell(LocalShellProfile)
}
