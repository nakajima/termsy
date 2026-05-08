//
//  SSHConnection.swift
//  Termsy
//

import Foundation
import NIOCore
import NIOFoundationCompat
@preconcurrency import NIOSSH
import NIOTransportServices
import TermsyGhosttyCore

struct TerminalWindowSize: Sendable, Equatable {
	var columns: Int
	var rows: Int
	var pixelWidth: Int
	var pixelHeight: Int
}

struct SSHCommandResult: Sendable {
	let output: String
	let exitStatus: Int?
	let exitSignal: String?
}

enum RemoteTmuxSessionDiscovery {
	static func fetchSessionNames(host: String, port: Int, username: String, password: String?) async throws -> [String] {
		let connection = SSHConnection(
			onData: { _ in },
			onClose: { _ in },
			onEvent: { _ in }
		)
		defer { connection.disconnect() }

		try await connection.connect(host: host, port: port, username: username, password: password)
		let result = try await connection.runDetachedCommand(listSessionsCommand)
		return parseListSessionsOutput(result.output)
	}

	static func parseListSessionsOutput(_ output: String) -> [String] {
		var seenNames = Set<String>()
		var names: [String] = []

		for line in output.components(separatedBy: .newlines) {
			let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard trimmedLine.hasPrefix(outputPrefix) else { continue }
			let name = String(trimmedLine.dropFirst(outputPrefix.count))
				.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !name.isEmpty, seenNames.insert(name).inserted else { continue }
			names.append(name)
		}

		return names
	}

	private static let outputPrefix = "__TERMSY_TMUX_SESSION__="

	private static let listSessionsCommand: String = {
		let script = #"""
		PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin"
		export PATH
		if command -v tmux >/dev/null 2>&1; then
		  tmux list-sessions -F '__TERMSY_TMUX_SESSION__=#{session_name}' 2>/dev/null || true
		fi
		"""#
		return "/bin/sh -c \(shellQuoted(script))"
	}()

	private static func shellQuoted(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}
}

enum SSHConnectionError: Error, LocalizedError, CustomStringConvertible {
	case notConnected
	case invalidChannelType
	case authenticationFailed
	case timedOut(String)

	var errorDescription: String? {
		switch self {
		case .notConnected: "Not connected"
		case .invalidChannelType: "Invalid SSH channel type"
		case .authenticationFailed: "Authentication failed"
		case let .timedOut(stage): "Timed out while \(stage)"
		}
	}

	var description: String {
		errorDescription ?? "SSH connection error"
	}
}

enum ShellTitleIntegration {
	enum Shell: String {
		case bash
		case fish
		case zsh

		init?(shellPath: String) {
			switch URL(fileURLWithPath: shellPath).lastPathComponent.lowercased() {
			case "bash": self = .bash
			case "fish": self = .fish
			case "zsh": self = .zsh
			default: return nil
			}
		}
	}

	struct LocalLaunch {
		let arguments: [String]
		let environment: [String: String]
		let cleanupDirectory: URL?
	}

	static let termProgram = "ghostty"

	static let termProgramVersion: String = {
		let info = ghostty_info()
		guard let version = info.version else { return "" }
		return String(cString: version)
	}()

	static func localLaunch(shellPath: String, environment: [String: String]) -> LocalLaunch? {
		guard let shell = Shell(shellPath: shellPath) else { return nil }

		let fileManager = FileManager.default
		let root = fileManager.temporaryDirectory.appendingPathComponent(
			"termsy-shell-title-\(UUID().uuidString)",
			isDirectory: true
		)

		do {
			try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
			var launchEnvironment = [String: String]()
			let shellName = URL(fileURLWithPath: shellPath).lastPathComponent

			switch shell {
			case .bash:
				let rcfile = root.appendingPathComponent("termsy-title.bash")
				try bashScript.write(to: rcfile, atomically: true, encoding: .utf8)
				return LocalLaunch(
					arguments: [shellName, "--noprofile", "--norc", "--rcfile", rcfile.path, "-i"],
					environment: launchEnvironment,
					cleanupDirectory: root
				)

			case .fish:
				let dataDir = root.appendingPathComponent("share", isDirectory: true)
				let vendorDirectory = dataDir.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)
				try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
				let scriptURL = vendorDirectory.appendingPathComponent("termsy-title.fish")
				try fishScript.write(to: scriptURL, atomically: true, encoding: .utf8)
				launchEnvironment["XDG_DATA_DIRS"] = prependDataDirectory(
					dataDir.path,
					to: environment["XDG_DATA_DIRS"]
				)
				return LocalLaunch(
					arguments: [shellName, "-i", "-l"],
					environment: launchEnvironment,
					cleanupDirectory: root
				)

			case .zsh:
				let envfile = root.appendingPathComponent(".zshenv")
				let profileFile = root.appendingPathComponent(".zprofile")
				let rcFile = root.appendingPathComponent(".zshrc")
				let loginFile = root.appendingPathComponent(".zlogin")
				let integrationFile = root.appendingPathComponent("termsy-title.zsh")
				try zshEnvScript.write(to: envfile, atomically: true, encoding: .utf8)
				try zshProfileScript.write(to: profileFile, atomically: true, encoding: .utf8)
				try zshRcScript.write(to: rcFile, atomically: true, encoding: .utf8)
				try zshLoginScript.write(to: loginFile, atomically: true, encoding: .utf8)
				try zshIntegrationScript.write(to: integrationFile, atomically: true, encoding: .utf8)
				launchEnvironment["ZDOTDIR"] = root.path
				launchEnvironment["TERMSY_TITLE_ZSH_INTEGRATION_FILE"] = integrationFile.path
				if let originalZdotdir = environment["ZDOTDIR"] {
					launchEnvironment["TERMSY_TITLE_ORIGINAL_ZDOTDIR"] = originalZdotdir
				}
				return LocalLaunch(
					arguments: [shellName, "-i", "-l"],
					environment: launchEnvironment,
					cleanupDirectory: root
				)
			}
		} catch {
			try? fileManager.removeItem(at: root)
			return nil
		}
	}

	static func remoteStartupCommand(tmuxSessionName: String?, initialWorkingDirectory: String?) -> String {
		let script = remoteBootstrapScript(
			tmuxSessionName: tmuxSessionName,
			initialWorkingDirectory: initialWorkingDirectory
		)
		// Keep the bootstrap shell non-login. The real shell below loads profiles;
		// a login /bin/sh can source bash-oriented profile.d scripts under dash.
		return "/bin/sh -c \(shellQuoted(script))"
	}

	private static func prependDataDirectory(_ path: String, to existingValue: String?) -> String {
		let existing = (existingValue?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
			$0.isEmpty ? nil : $0
		}
		return existing.map { "\(path):\($0)" } ?? "\(path):/usr/local/share:/usr/share"
	}

	private static func shellQuoted(_ value: String) -> String {
		"'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	private static let bashScript = #"""
	if [[ "$-" != *i* ]]; then
	  return 0 2>/dev/null || exit 0
	fi

	[ -r /etc/profile ] && builtin source /etc/profile
	for _termsy_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
	  if [ -r "$_termsy_rcfile" ]; then
	    builtin source "$_termsy_rcfile"
	    break
	  fi
	done
	builtin unset _termsy_rcfile

	__termsy_tmux_attach_or_create() {
	  local session=$1
	  local start_directory=${2-}
	  local -a shell_command=(env "SHELL=$SHELL")
	  if [[ -n "${ZDOTDIR+X}" ]]; then
	    shell_command+=("ZDOTDIR=$ZDOTDIR")
	  fi
	  shell_command+=("$SHELL" -l -i)

	  if ! tmux has-session -t "$session" 2>/dev/null; then
	    if [[ -n "$start_directory" ]]; then
	      tmux new-session -d -s "$session" -c "$start_directory" "${shell_command[@]}" 2>/dev/null || true
	    else
	      tmux new-session -d -s "$session" "${shell_command[@]}" 2>/dev/null || true
	    fi
	  fi
	  tmux set-option -q -t "$session" default-shell "$SHELL" 2>/dev/null || true
	  tmux set-environment -t "$session" SHELL "$SHELL" 2>/dev/null || true
	  if [[ -n "${ZDOTDIR+X}" ]]; then
	    tmux set-environment -t "$session" ZDOTDIR "$ZDOTDIR" 2>/dev/null || true
	  else
	    tmux set-environment -rt "$session" ZDOTDIR 2>/dev/null || true
	  fi
	  tmux set-environment -rt "$session" TERMSY_STARTUP_TMUX_SESSION 2>/dev/null || true
	  tmux set-environment -rt "$session" TERMSY_TMUX_START_DIRECTORY 2>/dev/null || true
	  exec tmux attach-session -t "$session"
	}

	if [[ -n "${TERMSY_STARTUP_TMUX_SESSION-}" ]]; then
	  __termsy_tmux_session=$TERMSY_STARTUP_TMUX_SESSION
	  __termsy_tmux_start_directory=${TERMSY_TMUX_START_DIRECTORY-}
	  builtin unset TERMSY_STARTUP_TMUX_SESSION TERMSY_TMUX_START_DIRECTORY
	  if command -v tmux >/dev/null 2>&1; then
	    __termsy_tmux_attach_or_create "$__termsy_tmux_session" "$__termsy_tmux_start_directory"
	  else
	    printf 'Termsy: tmux not found after bash startup; continuing with login shell\n' >&2
	  fi
	  builtin unset __termsy_tmux_session __termsy_tmux_start_directory
	fi

	if [[ -n "${TERMSY_TITLE_HOOKS_ACTIVE-}" ]]; then
	  return 0 2>/dev/null || exit 0
	fi
	TERMSY_TITLE_HOOKS_ACTIVE=1

	__termsy_sanitize_title() {
	  local title=$1
	  title=${title//$'\e'/}
	  title=${title//$'\a'/}
	  title=${title//$'\r'/ }
	  title=${title//$'\n'/ }
	  printf '%s' "$title"
	}

	__termsy_set_title() {
	  local title
	  title="$(__termsy_sanitize_title "$1")"
	  printf '\e]2;%s\a' "$title"
	}

	__termsy_normalize_command_title() {
	  local title=$1
	  case "$title" in
	    "env TERM=xterm-ghostty "*)
	      title=${title#env TERM=xterm-ghostty }
	      ;;
	    "TERM=xterm-ghostty "*)
	      title=${title#TERM=xterm-ghostty }
	      ;;
	  esac
	  printf '%s' "$title"
	}

	__termsy_prompt_title() {
	  __termsy_in_prompt_command=1
	  __termsy_preexec_seen=0
	  local path="${PWD/#$HOME/~}"
	  __termsy_set_title "$path"
	  __termsy_in_prompt_command=0
	}

	__termsy_preexec() {
	  [[ "${__termsy_in_prompt_command-0}" == 1 ]] && return
	  [[ "${__termsy_preexec_seen-0}" == 1 ]] && return
	  __termsy_preexec_seen=1
	  __termsy_set_title "$(__termsy_normalize_command_title "$1")"
	}

	if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
	  PROMPT_COMMAND=(__termsy_prompt_title "${PROMPT_COMMAND[@]}")
	elif [[ -n "${PROMPT_COMMAND-}" ]]; then
	  PROMPT_COMMAND="__termsy_prompt_title; ${PROMPT_COMMAND}"
	else
	  PROMPT_COMMAND="__termsy_prompt_title"
	fi

	if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
	  PS0='${ __termsy_preexec "$BASH_COMMAND"; }'"${PS0-}"
	else
	  trap '__termsy_preexec "$BASH_COMMAND"' DEBUG
	fi

	__termsy_prompt_title
	"""#

	private static let fishScript = #"""
	function __termsy_set_title -a title
	    set -l sanitized (string replace -ar '[\x00-\x1f\x7f]' ' ' -- "$title")
	    printf '\e]2;%s\a' "$sanitized"
	end

	function __termsy_normalize_command_title -a title
	    if string match -q 'env TERM=xterm-ghostty *' -- "$title"
	        string replace -r '^env TERM=xterm-ghostty ' '' -- "$title"
	    else if string match -q 'TERM=xterm-ghostty *' -- "$title"
	        string replace -r '^TERM=xterm-ghostty ' '' -- "$title"
	    else
	        printf '%s' "$title"
	    end
	end

	function __termsy_tmux_attach_or_create -a session start_directory
	    set -l shell_command env "SHELL=$SHELL"
	    if set -q ZDOTDIR
	        set shell_command $shell_command "ZDOTDIR=$ZDOTDIR"
	    end
	    set shell_command $shell_command "$SHELL" -i -l

	    if not tmux has-session -t "$session" 2>/dev/null
	        if test -n "$start_directory"
	            tmux new-session -d -s "$session" -c "$start_directory" $shell_command 2>/dev/null; or true
	        else
	            tmux new-session -d -s "$session" $shell_command 2>/dev/null; or true
	        end
	    end
	    tmux set-option -q -t "$session" default-shell "$SHELL" 2>/dev/null; or true
	    tmux set-environment -t "$session" SHELL "$SHELL" 2>/dev/null; or true
	    if set -q ZDOTDIR
	        tmux set-environment -t "$session" ZDOTDIR "$ZDOTDIR" 2>/dev/null; or true
	    else
	        tmux set-environment -rt "$session" ZDOTDIR 2>/dev/null; or true
	    end
	    tmux set-environment -rt "$session" TERMSY_STARTUP_TMUX_SESSION 2>/dev/null; or true
	    tmux set-environment -rt "$session" TERMSY_TMUX_START_DIRECTORY 2>/dev/null; or true
	    exec tmux attach-session -t "$session"
	end

	function __termsy_maybe_start_tmux --on-event fish_prompt
	    if set -q TERMSY_STARTUP_TMUX_SESSION
	        set -l session "$TERMSY_STARTUP_TMUX_SESSION"
	        set -l start_directory
	        if set -q TERMSY_TMUX_START_DIRECTORY
	            set start_directory "$TERMSY_TMUX_START_DIRECTORY"
	        end
	        set -e TERMSY_STARTUP_TMUX_SESSION TERMSY_TMUX_START_DIRECTORY
	        functions -e __termsy_maybe_start_tmux
	        if command -sq tmux
	            __termsy_tmux_attach_or_create "$session" "$start_directory"
	        else
	            printf 'Termsy: tmux not found after fish startup; continuing with login shell\n' >&2
	        end
	    end
	end

	function __termsy_prompt_title --on-event fish_prompt
	    __termsy_set_title (prompt_pwd)
	end

	function __termsy_command_title --on-event fish_preexec -a commandline
	    if test -n "$commandline"
	        __termsy_set_title (__termsy_normalize_command_title "$commandline")
	    end
	end

	__termsy_prompt_title
	"""#

	private static let zshEnvScript = #"""
	if [[ -n "${TERMSY_TITLE_ORIGINAL_ZDOTDIR+X}" ]]; then
	  builtin export ZDOTDIR="$TERMSY_TITLE_ORIGINAL_ZDOTDIR"
	else
	  builtin unset ZDOTDIR
	fi

	builtin typeset _termsy_wrapper_zdotdir="${${(%):-%x}:A:h}"
	builtin typeset _termsy_user_zdotdir="${ZDOTDIR:-$HOME}"
	builtin typeset _termsy_file="$_termsy_user_zdotdir/.zshenv"
	[[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"

	if [[ -n "${ZDOTDIR+X}" ]]; then
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$ZDOTDIR"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=1
	else
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$HOME"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=0
	fi
	builtin export TERMSY_TITLE_WRAPPER_ZDOTDIR="$_termsy_wrapper_zdotdir"
	builtin export ZDOTDIR="$_termsy_wrapper_zdotdir"
	builtin unset _termsy_file _termsy_user_zdotdir _termsy_wrapper_zdotdir
	"""#

	private static let zshProfileScript = #"""
	builtin typeset _termsy_wrapper_zdotdir="${TERMSY_TITLE_WRAPPER_ZDOTDIR:-${${(%):-%x}:A:h}}"
	builtin typeset _termsy_user_zdotdir="${TERMSY_TITLE_USER_ZDOTDIR:-$HOME}"
	if [[ "${TERMSY_TITLE_USER_ZDOTDIR_SET:-0}" == 1 ]]; then
	  builtin export ZDOTDIR="$_termsy_user_zdotdir"
	else
	  builtin unset ZDOTDIR
	fi

	builtin typeset _termsy_file="$_termsy_user_zdotdir/.zprofile"
	[[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"

	if [[ -n "${ZDOTDIR+X}" ]]; then
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$ZDOTDIR"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=1
	else
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$HOME"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=0
	fi
	builtin export ZDOTDIR="$_termsy_wrapper_zdotdir"
	builtin unset _termsy_file _termsy_user_zdotdir _termsy_wrapper_zdotdir
	"""#

	private static let zshRcScript = #"""
	builtin typeset _termsy_wrapper_zdotdir="${TERMSY_TITLE_WRAPPER_ZDOTDIR:-${${(%):-%x}:A:h}}"
	builtin typeset _termsy_user_zdotdir="${TERMSY_TITLE_USER_ZDOTDIR:-$HOME}"
	if [[ "${TERMSY_TITLE_USER_ZDOTDIR_SET:-0}" == 1 ]]; then
	  builtin export ZDOTDIR="$_termsy_user_zdotdir"
	else
	  builtin unset ZDOTDIR
	fi

	builtin typeset _termsy_file="$_termsy_user_zdotdir/.zshrc"
	[[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"

	if [[ -n "${ZDOTDIR+X}" ]]; then
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$ZDOTDIR"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=1
	else
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$HOME"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=0
	fi

	if [[ -o login ]]; then
	  builtin export ZDOTDIR="$_termsy_wrapper_zdotdir"
	else
	  _termsy_file="${TERMSY_TITLE_ZSH_INTEGRATION_FILE:-$_termsy_wrapper_zdotdir/termsy-title.zsh}"
	  [[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"
	  if [[ "${TERMSY_TITLE_USER_ZDOTDIR_SET:-0}" == 1 ]]; then
	    builtin export ZDOTDIR="$TERMSY_TITLE_USER_ZDOTDIR"
	  else
	    builtin unset ZDOTDIR
	  fi
	  builtin unset TERMSY_TITLE_ORIGINAL_ZDOTDIR TERMSY_TITLE_USER_ZDOTDIR TERMSY_TITLE_USER_ZDOTDIR_SET TERMSY_TITLE_WRAPPER_ZDOTDIR TERMSY_TITLE_ZSH_INTEGRATION_FILE
	fi
	builtin unset _termsy_file _termsy_user_zdotdir _termsy_wrapper_zdotdir
	"""#

	private static let zshLoginScript = #"""
	builtin typeset _termsy_wrapper_zdotdir="${TERMSY_TITLE_WRAPPER_ZDOTDIR:-${${(%):-%x}:A:h}}"
	builtin typeset _termsy_user_zdotdir="${TERMSY_TITLE_USER_ZDOTDIR:-$HOME}"
	if [[ "${TERMSY_TITLE_USER_ZDOTDIR_SET:-0}" == 1 ]]; then
	  builtin export ZDOTDIR="$_termsy_user_zdotdir"
	else
	  builtin unset ZDOTDIR
	fi

	builtin typeset _termsy_file="$_termsy_user_zdotdir/.zlogin"
	[[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"

	if [[ -n "${ZDOTDIR+X}" ]]; then
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$ZDOTDIR"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=1
	else
	  builtin export TERMSY_TITLE_USER_ZDOTDIR="$HOME"
	  builtin export TERMSY_TITLE_USER_ZDOTDIR_SET=0
	fi
	_termsy_file="${TERMSY_TITLE_ZSH_INTEGRATION_FILE:-$_termsy_wrapper_zdotdir/termsy-title.zsh}"
	[[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"

	if [[ "${TERMSY_TITLE_USER_ZDOTDIR_SET:-0}" == 1 ]]; then
	  builtin export ZDOTDIR="$TERMSY_TITLE_USER_ZDOTDIR"
	else
	  builtin unset ZDOTDIR
	fi
	builtin unset TERMSY_TITLE_ORIGINAL_ZDOTDIR TERMSY_TITLE_USER_ZDOTDIR TERMSY_TITLE_USER_ZDOTDIR_SET TERMSY_TITLE_WRAPPER_ZDOTDIR TERMSY_TITLE_ZSH_INTEGRATION_FILE
	builtin unset _termsy_file _termsy_user_zdotdir _termsy_wrapper_zdotdir
	"""#

	private static let zshIntegrationScript = #"""
	if [[ -n "${TERMSY_TITLE_HOOKS_ACTIVE-}" ]]; then
	  return 0 2>/dev/null || exit 0
	fi
	typeset -g TERMSY_TITLE_HOOKS_ACTIVE=1

	_termsy_tmux_attach_or_create() {
	  emulate -L zsh
	  local session=$1
	  local start_directory=${2-}
	  local -a shell_command=(env "SHELL=$SHELL")
	  if [[ -n "${ZDOTDIR+X}" ]]; then
	    shell_command+=("ZDOTDIR=$ZDOTDIR")
	  fi
	  shell_command+=("$SHELL" -i -l)

	  if ! tmux has-session -t "$session" 2>/dev/null; then
	    if [[ -n "$start_directory" ]]; then
	      tmux new-session -d -s "$session" -c "$start_directory" "${shell_command[@]}" 2>/dev/null || true
	    else
	      tmux new-session -d -s "$session" "${shell_command[@]}" 2>/dev/null || true
	    fi
	  fi
	  tmux set-option -q -t "$session" default-shell "$SHELL" 2>/dev/null || true
	  tmux set-environment -t "$session" SHELL "$SHELL" 2>/dev/null || true
	  if [[ -n "${ZDOTDIR+X}" ]]; then
	    tmux set-environment -t "$session" ZDOTDIR "$ZDOTDIR" 2>/dev/null || true
	  else
	    tmux set-environment -rt "$session" ZDOTDIR 2>/dev/null || true
	  fi
	  tmux set-environment -rt "$session" TERMSY_STARTUP_TMUX_SESSION 2>/dev/null || true
	  tmux set-environment -rt "$session" TERMSY_TMUX_START_DIRECTORY 2>/dev/null || true
	  exec tmux attach-session -t "$session"
	}

	_termsy_maybe_start_tmux() {
	  emulate -L zsh
	  [[ -n "${TERMSY_STARTUP_TMUX_SESSION-}" ]] || return 0
	  local session=$TERMSY_STARTUP_TMUX_SESSION
	  local start_directory=${TERMSY_TMUX_START_DIRECTORY-}
	  unset TERMSY_STARTUP_TMUX_SESSION TERMSY_TMUX_START_DIRECTORY
	  if (( $+functions[add-zsh-hook] )); then
	    add-zsh-hook -d precmd _termsy_maybe_start_tmux 2>/dev/null
	  else
	    precmd_functions=(${precmd_functions:#_termsy_maybe_start_tmux})
	  fi
	  if (( $+commands[tmux] )); then
	    _termsy_tmux_attach_or_create "$session" "$start_directory"
	  else
	    print -ru2 -- 'Termsy: tmux not found after zsh startup; continuing with login shell'
	  fi
	}

	_termsy_sanitize_title() {
	  emulate -L zsh
	  local title=$1
	  title=${title//$'\e'/}
	  title=${title//$'\a'/}
	  title=${title//$'\r'/ }
	  title=${title//$'\n'/ }
	  print -rn -- "$title"
	}

	_termsy_set_title() {
	  emulate -L zsh
	  local title
	  title=$(_termsy_sanitize_title "$1")
	  print -rn -- $'\e]2;'${title}$'\a'
	}

	_termsy_normalize_command_title() {
	  emulate -L zsh
	  local title=$1
	  case "$title" in
	    ("env TERM=xterm-ghostty "*)
	      title=${title#env TERM=xterm-ghostty }
	      ;;
	    ("TERM=xterm-ghostty "*)
	      title=${title#TERM=xterm-ghostty }
	      ;;
	  esac
	  print -rn -- "$title"
	}

	_termsy_prompt_title() {
	  emulate -L zsh
	  local path="${PWD/#$HOME/~}"
	  _termsy_set_title "$path"
	}

	_termsy_preexec_title() {
	  emulate -L zsh
	  _termsy_set_title "$(_termsy_normalize_command_title "$1")"
	}

	autoload -Uz add-zsh-hook 2>/dev/null
	if (( $+functions[add-zsh-hook] )); then
	  add-zsh-hook precmd _termsy_maybe_start_tmux
	  add-zsh-hook precmd _termsy_prompt_title
	  add-zsh-hook preexec _termsy_preexec_title
	else
	  typeset -ag precmd_functions preexec_functions
	  precmd_functions+=(_termsy_maybe_start_tmux _termsy_prompt_title)
	  preexec_functions+=(_termsy_preexec_title)
	fi

	_termsy_prompt_title
	"""#

	private static func remoteBootstrapScript(tmuxSessionName: String?, initialWorkingDirectory: String?) -> String {
		let termProgramVersionExport = if termProgramVersion.isEmpty {
			""
		} else {
			"export TERM_PROGRAM_VERSION=\(shellQuoted(termProgramVersion))\n"
		}

		let tmuxStartupExport = if let tmuxSessionName, !tmuxSessionName.isEmpty {
			"export TERMSY_STARTUP_TMUX_SESSION=\(shellQuoted(tmuxSessionName))\n"
		} else {
			""
		}

		let initialWorkingDirectoryExport = if let initialWorkingDirectory = initialWorkingDirectory?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!initialWorkingDirectory.isEmpty
		{
			"export TERMSY_INITIAL_WORKING_DIRECTORY=\(shellQuoted(initialWorkingDirectory))\n"
		} else {
			""
		}

		let bootstrapEnvironment = """
		export TERM_PROGRAM=ghostty
		export COLORTERM=truecolor
		\(termProgramVersionExport)\(tmuxStartupExport)\(initialWorkingDirectoryExport)
		"""

		return #"""
		termsy_log() {
		  printf 'Termsy: %s\n' "$*" >&2
		}

		termsy_passwd_shell() {
		  [ -n "${USER:-}" ] || return 1
		  [ -r /etc/passwd ] || return 1
		  awk -F: -v user="$USER" '$1 == user { print $7; exit }' /etc/passwd 2>/dev/null
		}

		shell_path=${SHELL:-}
		passwd_shell=$(termsy_passwd_shell || true)
		if [ -z "$shell_path" ] || [ ! -x "$shell_path" ]; then
		  shell_path=$passwd_shell
		fi
		if [ -z "$shell_path" ] || [ ! -x "$shell_path" ]; then
		  shell_path=/bin/sh
		fi
		shell_name=${shell_path##*/}
		export SHELL="$shell_path"

		termsy_exec_user_shell() {
		  case "$shell_name" in
		    bash)
		      exec "$shell_path" -l -i
		      ;;
		    fish|zsh)
		      exec "$shell_path" -i -l
		      ;;
		    *)
		      exec "$shell_path"
		      ;;
		  esac
		  exec /bin/sh
		}

		cache_root=${XDG_CACHE_HOME:-}
		if [ -z "$cache_root" ]; then
		  if [ -n "${HOME:-}" ]; then
		    cache_root="$HOME/.cache"
		  else
		    cache_root="${TMPDIR:-/tmp}"
		  fi
		fi
		cache_root="$cache_root/termsy-shell-title"

		__TERMSY_BOOTSTRAP_ENVIRONMENT__
		unset TERMSY_TMUX_START_DIRECTORY

		if [ -n "${TERMSY_INITIAL_WORKING_DIRECTORY:-}" ]; then
		  termsy_initial_working_directory=$TERMSY_INITIAL_WORKING_DIRECTORY
		  unset TERMSY_INITIAL_WORKING_DIRECTORY
		  case "$termsy_initial_working_directory" in
		    "~")
		      [ -z "${HOME:-}" ] || termsy_initial_working_directory=$HOME
		      ;;
		    "~/"*)
		      [ -z "${HOME:-}" ] || termsy_initial_working_directory="$HOME/${termsy_initial_working_directory#~/}"
		      ;;
		  esac
		  if cd "$termsy_initial_working_directory" 2>/dev/null; then
		    if [ -n "${TERMSY_STARTUP_TMUX_SESSION:-}" ]; then
		      export TERMSY_TMUX_START_DIRECTORY="$PWD"
		    fi
		  fi
		  unset termsy_initial_working_directory
		fi

		ready=0
		if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then
		  ready=1
		elif [ -n "${HOME:-}" ] && command -v tic >/dev/null 2>&1; then
		  mkdir -p "$HOME/.terminfo" 2>/dev/null || true
		  if cat <<'__TERMSY_GHOSTTY_TERMINFO__' | tic -x - >/dev/null 2>&1; then
		__TERMSY_GHOSTTY_TERMINFO_SOURCE__
		__TERMSY_GHOSTTY_TERMINFO__
		    ready=1
		  fi
		fi
		if [ "$ready" = 1 ]; then
		  export TERM=xterm-ghostty
		else
		  export TERM=xterm-256color
		fi

		case "$shell_name" in
		  bash)
		    bash_dir="$cache_root/bash"
		    if (
		      set -e
		      mkdir -p "$bash_dir"
		      cat >"$bash_dir/termsy-title.bash" <<'__TERMSY_BASH__'
		__TERMSY_BASH_SCRIPT__
		__TERMSY_BASH__
		    ); then
		      exec "$shell_path" --noprofile --norc --rcfile "$bash_dir/termsy-title.bash" -i
		    fi
		    termsy_log 'failed to prepare bash integration; starting normal shell'
		    termsy_exec_user_shell
		    ;;
		  fish)
		    fish_dir="$cache_root/fish"
		    if (
		      set -e
		      mkdir -p "$fish_dir/fish/vendor_conf.d"
		      cat >"$fish_dir/fish/vendor_conf.d/termsy-title.fish" <<'__TERMSY_FISH__'
		__TERMSY_FISH_SCRIPT__
		__TERMSY_FISH__
		    ); then
		      if [ -n "${XDG_DATA_DIRS:-}" ]; then
		        export XDG_DATA_DIRS="$fish_dir:$XDG_DATA_DIRS"
		      else
		        export XDG_DATA_DIRS="$fish_dir:/usr/local/share:/usr/share"
		      fi
		      exec "$shell_path" -i -l
		    fi
		    termsy_log 'failed to prepare fish integration; starting normal shell'
		    termsy_exec_user_shell
		    ;;
		  zsh)
		    zsh_dir="$cache_root/zsh"
		    if (
		      set -e
		      mkdir -p "$zsh_dir"
		      cat >"$zsh_dir/.zshenv" <<'__TERMSY_ZSHENV__'
		__TERMSY_ZSH_ENV_SCRIPT__
		__TERMSY_ZSHENV__
		      cat >"$zsh_dir/.zprofile" <<'__TERMSY_ZPROFILE__'
		__TERMSY_ZSH_PROFILE_SCRIPT__
		__TERMSY_ZPROFILE__
		      cat >"$zsh_dir/.zshrc" <<'__TERMSY_ZSHRC__'
		__TERMSY_ZSH_RC_SCRIPT__
		__TERMSY_ZSHRC__
		      cat >"$zsh_dir/.zlogin" <<'__TERMSY_ZLOGIN__'
		__TERMSY_ZSH_LOGIN_SCRIPT__
		__TERMSY_ZLOGIN__
		      cat >"$zsh_dir/termsy-title.zsh" <<'__TERMSY_ZSH__'
		__TERMSY_ZSH_INTEGRATION_SCRIPT__
		__TERMSY_ZSH__
		    ); then
		      if [ "${ZDOTDIR+set}" = set ]; then
		        export TERMSY_TITLE_ORIGINAL_ZDOTDIR="$ZDOTDIR"
		      else
		        unset TERMSY_TITLE_ORIGINAL_ZDOTDIR
		      fi
		      export TERMSY_TITLE_ZSH_INTEGRATION_FILE="$zsh_dir/termsy-title.zsh"
		      export ZDOTDIR="$zsh_dir"
		      exec "$shell_path" -i -l
		    fi
		    termsy_log 'failed to prepare zsh integration; starting normal shell'
		    termsy_exec_user_shell
		    ;;
		  *)
		    termsy_exec_user_shell
		    ;;
		esac
		"""#
		.replacingOccurrences(of: "__TERMSY_BOOTSTRAP_ENVIRONMENT__", with: bootstrapEnvironment)
		.replacingOccurrences(of: "__TERMSY_GHOSTTY_TERMINFO_SOURCE__", with: GhosttyTerminfo.source)
		.replacingOccurrences(of: "__TERMSY_BASH_SCRIPT__", with: bashScript)
		.replacingOccurrences(of: "__TERMSY_FISH_SCRIPT__", with: fishScript)
		.replacingOccurrences(of: "__TERMSY_ZSH_ENV_SCRIPT__", with: zshEnvScript)
		.replacingOccurrences(of: "__TERMSY_ZSH_PROFILE_SCRIPT__", with: zshProfileScript)
		.replacingOccurrences(of: "__TERMSY_ZSH_RC_SCRIPT__", with: zshRcScript)
		.replacingOccurrences(of: "__TERMSY_ZSH_LOGIN_SCRIPT__", with: zshLoginScript)
		.replacingOccurrences(of: "__TERMSY_ZSH_INTEGRATION_SCRIPT__", with: zshIntegrationScript)
	}
}

final nonisolated class SSHConnection: @unchecked Sendable {
	enum CloseReason: Sendable {
		case localDisconnect
		case cleanExit
		case error(String)
	}

	enum StartupCommandFallbackPolicy: Sendable, Equatable {
		case plainShellOnBootstrapFailure
		case requireStartupCommand
	}

	private static let sessionStartupTimeout: TimeAmount = .seconds(10)
	private static let channelRequestTimeout: TimeAmount = .seconds(10)

	private let group = NIOTSEventLoopGroup()
	private var channel: Channel?
	private var sshChildChannel: Channel?
	private var authDelegate: PasswordOrNoneAuthDelegate?
	private var isDisconnecting = false
	private var pendingTerminalSize = TerminalWindowSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)

	private let onData: @Sendable (Data) -> Void
	private let onClose: @Sendable (CloseReason) -> Void
	private let onEvent: @Sendable (String) -> Void

	var isActive: Bool {
		channel?.isActive ?? false
	}

	init(
		onData: @escaping @Sendable (Data) -> Void,
		onClose: @escaping @Sendable (CloseReason) -> Void,
		onEvent: @escaping @Sendable (String) -> Void = { _ in }
	) {
		self.onData = onData
		self.onClose = onClose
		self.onEvent = onEvent
	}

	func connect(host: String, port: Int, username: String, password: String?) async throws {
		disconnect()
		log("connecting to \(host):\(port) as \(username)")
		channel = nil
		sshChildChannel = nil
		authDelegate = nil
		isDisconnecting = false

		let authDelegate = PasswordOrNoneAuthDelegate(
			username: username,
			password: password ?? "",
			logger: { [weak self] message in self?.log(message) }
		)
		self.authDelegate = authDelegate
		let hostKeyDelegate = AcceptAllHostKeysDelegate(
			logger: { [weak self] message in self?.log(message) }
		)

		let bootstrap = NIOTSConnectionBootstrap(group: group)
			.connectTimeout(.seconds(10))
			.channelInitializer { channel in
				self.log("TCP connected, adding SSH handler")
				return channel.pipeline.addHandler(
					NIOSSHHandler(
						role: .client(.init(
							userAuthDelegate: authDelegate,
							serverAuthDelegate: hostKeyDelegate
						)),
						allocator: channel.allocator,
						inboundChildChannelInitializer: nil
					)
				)
			}

		log("bootstrap.connect...")
		channel = try await bootstrap.connect(host: host, port: port).get()
		log("connected")
	}

	func startShell(
		size: TerminalWindowSize,
		startupCommand: String? = nil,
		startupFallbackPolicy: StartupCommandFallbackPolicy = .plainShellOnBootstrapFailure
	) async throws {
		pendingTerminalSize = size
		log("startShell \(size.columns)x\(size.rows) px=\(size.pixelWidth)x\(size.pixelHeight)")
		guard let channel else { throw SSHConnectionError.notConnected }

		do {
			if let startupCommand {
				do {
					let childChannel = try await openPreparedSessionChannel(on: channel)
					sshChildChannel = childChannel
					try await requestExec(startupCommand, on: childChannel)
					log("remote shell bootstrap started")
					sendWindowChange(pendingTerminalSize, force: true)
				} catch {
					closeActiveStartupChannelIfNeeded()
					switch startupFallbackPolicy {
					case .plainShellOnBootstrapFailure:
						log("remote shell bootstrap failed, opening fresh plain shell channel: \(error)")
						try await startPlainShell(on: channel, fallback: true)
					case .requireStartupCommand:
						log("remote shell bootstrap failed and plain shell fallback is disabled: \(error)")
						throw error
					}
				}
			} else {
				try await startPlainShell(on: channel, fallback: false)
			}
		} catch {
			disconnect()
			throw error
		}
	}

	private func startPlainShell(on channel: Channel, fallback: Bool) async throws {
		let childChannel = try await openPreparedSessionChannel(on: channel)
		sshChildChannel = childChannel
		try await requestShell(on: childChannel)
		log(fallback ? "shell started (fresh fallback channel)" : "shell started")
		sendWindowChange(pendingTerminalSize, force: true)
	}

	private func openPreparedSessionChannel(on channel: Channel) async throws -> Channel {
		let childChannel = try await openSessionChannel(on: channel)
		do {
			try await requestPTY(on: childChannel, size: pendingTerminalSize)
			log("PTY allocated")
			return childChannel
		} catch {
			childChannel.close(mode: .all, promise: nil)
			throw error
		}
	}

	private func openSessionChannel(on channel: Channel) async throws -> Channel {
		let authDelegate = self.authDelegate
		let onData = self.onData
		let onClose = self.onClose
		return try await withTimeout(
			channel.eventLoop.flatSubmit {
				self.log("creating session channel...")
				let sshHandler = try! channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
				let promise = channel.eventLoop.makePromise(of: Channel.self)

				if authDelegate?.hasFailed == true {
					promise.fail(SSHConnectionError.authenticationFailed)
					return promise.futureResult
				}

				authDelegate?.onExhausted = {
					promise.fail(SSHConnectionError.authenticationFailed)
				}

				sshHandler.createChannel(promise) { childChannel, channelType in
					self.log("child channel init, type=\(channelType)")
					guard channelType == .session else {
						return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
					}

					let childID = ObjectIdentifier(childChannel)
					return childChannel.pipeline.addHandlers([
						SSHChannelDataHandler(onData: onData),
						SSHChannelLifecycleHandler(
							isDisconnecting: { [weak self] in self?.isDisconnecting ?? false },
							onClose: { [weak self] reason in
								guard let self,
								      let activeChannel = self.sshChildChannel,
								      ObjectIdentifier(activeChannel) == childID
								else { return }
								self.sshChildChannel = nil
								self.channel = nil
								self.authDelegate = nil
								onClose(reason)
							}
						),
					])
				}
				return promise.futureResult
			},
			on: channel.eventLoop,
			timeout: Self.sessionStartupTimeout,
			error: .timedOut("establishing the SSH session")
		).get()
	}

	private func requestPTY(on childChannel: Channel, size: TerminalWindowSize) async throws {
		let request = SSHChannelRequestEvent.PseudoTerminalRequest(
			wantReply: true,
			term: "xterm-256color",
			terminalCharacterWidth: size.columns,
			terminalRowHeight: size.rows,
			terminalPixelWidth: size.pixelWidth,
			terminalPixelHeight: size.pixelHeight,
			terminalModes: .init([:])
		)
		try await withTimeout(
			childChannel.triggerUserOutboundEvent(request),
			on: childChannel.eventLoop,
			timeout: Self.channelRequestTimeout,
			error: .timedOut("allocating a remote PTY")
		).get()
	}

	private func requestExec(_ command: String, on childChannel: Channel) async throws {
		let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
		try await withTimeout(
			childChannel.triggerUserOutboundEvent(request),
			on: childChannel.eventLoop,
			timeout: Self.channelRequestTimeout,
			error: .timedOut("starting the remote shell")
		).get()
	}

	private func requestShell(on childChannel: Channel) async throws {
		let request = SSHChannelRequestEvent.ShellRequest(wantReply: true)
		try await withTimeout(
			childChannel.triggerUserOutboundEvent(request),
			on: childChannel.eventLoop,
			timeout: Self.channelRequestTimeout,
			error: .timedOut("starting the remote shell")
		).get()
	}

	private func closeActiveStartupChannelIfNeeded() {
		guard let childChannel = sshChildChannel else { return }
		sshChildChannel = nil
		childChannel.close(mode: .all, promise: nil)
	}

	func send(_ data: Data) {
		guard let sshChildChannel, sshChildChannel.isActive else { return }
		sshChildChannel.eventLoop.execute {
			guard sshChildChannel.isActive else { return }
			var buffer = sshChildChannel.allocator.buffer(capacity: data.count)
			buffer.writeBytes(data)
			let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
			sshChildChannel.writeAndFlush(channelData, promise: nil)
		}
	}

	func resize(_ size: TerminalWindowSize) {
		sendWindowChange(size, force: false)
	}

	private func sendWindowChange(_ size: TerminalWindowSize, force: Bool) {
		let previousSize = pendingTerminalSize
		pendingTerminalSize = size
		// Re-sending the same character grid can make remote TUIs redraw on tab switches.
		guard force || size.columns != previousSize.columns || size.rows != previousSize.rows else { return }
		guard let sshChildChannel, sshChildChannel.isActive else { return }
		sshChildChannel.eventLoop.execute {
			guard sshChildChannel.isActive else { return }
			let req = SSHChannelRequestEvent.WindowChangeRequest(
				terminalCharacterWidth: size.columns,
				terminalRowHeight: size.rows,
				terminalPixelWidth: size.pixelWidth,
				terminalPixelHeight: size.pixelHeight
			)
			sshChildChannel.triggerUserOutboundEvent(req, promise: nil)
		}
	}

	func runDetachedCommand(_ command: String) async throws -> SSHCommandResult {
		guard let channel else { throw SSHConnectionError.notConnected }
		log("running detached command")
		return try await withTimeout(
			channel.eventLoop.flatSubmit {
				self.log("creating detached session channel...")
				let sshHandler = try! channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
				let childChannelPromise = channel.eventLoop.makePromise(of: Channel.self)
				let resultPromise = channel.eventLoop.makePromise(of: SSHCommandResult.self)
				let resultHandler = SSHDetachedCommandHandler(resultPromise: resultPromise)

				sshHandler.createChannel(childChannelPromise) { childChannel, channelType in
					self.log("detached child channel init, type=\(channelType)")
					guard channelType == .session else {
						return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
					}
					return childChannel.pipeline.addHandler(resultHandler)
				}

				return childChannelPromise.futureResult.flatMap { childChannel in
					self.log("detached exec request started")
					let execReq = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
					return childChannel.triggerUserOutboundEvent(execReq).flatMap {
						resultPromise.futureResult
					}
				}
			},
			on: channel.eventLoop,
			timeout: Self.sessionStartupTimeout,
			error: .timedOut("running a remote setup command")
		).get()
	}

	private func withTimeout<T>(
		_ future: EventLoopFuture<T>,
		on eventLoop: EventLoop,
		timeout: TimeAmount,
		error: SSHConnectionError
	) -> EventLoopFuture<T> {
		let promise = eventLoop.makePromise(of: T.self)
		var isComplete = false
		let timeoutTask = eventLoop.scheduleTask(in: timeout) {
			guard !isComplete else { return }
			isComplete = true
			promise.fail(error)
		}

		future.whenComplete { result in
			guard !isComplete else { return }
			isComplete = true
			timeoutTask.cancel()
			switch result {
			case let .success(value):
				promise.succeed(value)
			case let .failure(error):
				promise.fail(error)
			}
		}

		return promise.futureResult
	}

	private func log(_ message: String) {
		print("[SSH] \(message)")
		onEvent(message)
	}

	func disconnect() {
		isDisconnecting = true
		let childChannel = sshChildChannel
		let parentChannel = channel
		sshChildChannel = nil
		channel = nil
		authDelegate = nil
		childChannel?.close(mode: .all, promise: nil)
		parentChannel?.close(mode: .all, promise: nil)
	}

	deinit {
		disconnect()
		group.shutdownGracefully(queue: .global(qos: .utility)) { [onEvent] error in
			if let error {
				print("[SSH] failed to shut down event loop group: \(error)")
				onEvent("failed to shut down event loop group: \(error)")
			}
		}
	}
}

// MARK: - Auth Delegates

private final nonisolated class PasswordOrNoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
	private let username: String
	private let password: String
	private let logger: @Sendable (String) -> Void
	private var attemptedNone = false
	private var attemptedPassword = false
	var hasFailed = false
	var onExhausted: (() -> Void)?

	init(username: String, password: String, logger: @escaping @Sendable (String) -> Void) {
		self.username = username
		self.password = password
		self.logger = logger
	}

	func nextAuthenticationType(
		availableMethods: NIOSSHAvailableUserAuthenticationMethods,
		nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
	) {
		logger("auth callback: available=\(availableMethods) attemptedNone=\(attemptedNone) attemptedPassword=\(attemptedPassword)")

		// Always try "none" first — Tailscale SSH accepts this
		// when the client is an authorized tailnet node.
		if !attemptedNone {
			attemptedNone = true
			logger("trying none auth")
			nextChallengePromise.succeed(.init(
				username: username,
				serviceName: "",
				offer: .none
			))
			return
		}

		// Fall back to password if available
		if !attemptedPassword, !password.isEmpty, availableMethods.contains(.password) {
			attemptedPassword = true
			logger("trying password auth")
			nextChallengePromise.succeed(.init(
				username: username,
				serviceName: "",
				offer: .password(.init(password: password))
			))
			return
		}

		// No more methods
		logger("no more auth methods, failing")
		hasFailed = true
		onExhausted?()
		onExhausted = nil
		nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
	}
}

private final nonisolated class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
	private let logger: @Sendable (String) -> Void

	init(logger: @escaping @Sendable (String) -> Void) {
		self.logger = logger
	}

	func validateHostKey(
		hostKey: NIOSSHPublicKey,
		validationCompletePromise: EventLoopPromise<Void>
	) {
		logger("accepting host key: \(hostKey)")
		validationCompletePromise.succeed(())
	}
}

// MARK: - Channel Handlers

private final nonisolated class SSHChannelDataHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	let onData: @Sendable (Data) -> Void

	init(onData: @escaping @Sendable (Data) -> Void) {
		self.onData = onData
	}

	func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
		let channelData = unwrapInboundIn(data)
		guard case var .byteBuffer(buffer) = channelData.data,
		      let bytes = buffer.readData(length: buffer.readableBytes)
		else {
			return
		}
		onData(bytes)
	}
}

private final nonisolated class SSHDetachedCommandHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	private let resultPromise: EventLoopPromise<SSHCommandResult>
	private var output = Data()
	private var exitStatus: Int?
	private var exitSignal: SSHChannelRequestEvent.ExitSignal?
	private var caughtError: Error?
	private var isResolved = false

	init(resultPromise: EventLoopPromise<SSHCommandResult>) {
		self.resultPromise = resultPromise
	}

	func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
		let channelData = unwrapInboundIn(data)
		guard case var .byteBuffer(buffer) = channelData.data,
		      let bytes = buffer.readData(length: buffer.readableBytes)
		else {
			return
		}
		output.append(bytes)
	}

	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		switch event {
		case let event as SSHChannelRequestEvent.ExitStatus:
			exitStatus = event.exitStatus
		case let event as SSHChannelRequestEvent.ExitSignal:
			exitSignal = event
		default:
			break
		}
		context.fireUserInboundEventTriggered(event)
	}

	func errorCaught(context: ChannelHandlerContext, error: any Error) {
		caughtError = error
		context.close(mode: .all, promise: nil)
	}

	func channelInactive(context: ChannelHandlerContext) {
		guard !isResolved else {
			context.fireChannelInactive()
			return
		}
		isResolved = true
		if let caughtError {
			resultPromise.fail(caughtError)
		} else {
			let signalDescription = exitSignal.map { signal in
				signal.errorMessage.isEmpty ? signal.signalName : "\(signal.signalName): \(signal.errorMessage)"
			}
			let outputText = String(decoding: output, as: UTF8.self)
			resultPromise.succeed(
				SSHCommandResult(output: outputText, exitStatus: exitStatus, exitSignal: signalDescription)
			)
		}
		context.fireChannelInactive()
	}
}

private final nonisolated class SSHChannelLifecycleHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	let isDisconnecting: @Sendable () -> Bool
	let onClose: @Sendable (SSHConnection.CloseReason) -> Void

	private var exitStatus: Int?
	private var exitSignal: SSHChannelRequestEvent.ExitSignal?
	private var caughtError: Error?

	init(
		isDisconnecting: @escaping @Sendable () -> Bool,
		onClose: @escaping @Sendable (SSHConnection.CloseReason) -> Void
	) {
		self.isDisconnecting = isDisconnecting
		self.onClose = onClose
	}

	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		switch event {
		case let event as SSHChannelRequestEvent.ExitStatus:
			exitStatus = event.exitStatus
		case let event as SSHChannelRequestEvent.ExitSignal:
			exitSignal = event
		default:
			break
		}
		context.fireUserInboundEventTriggered(event)
	}

	func errorCaught(context: ChannelHandlerContext, error: any Error) {
		caughtError = error
		context.fireErrorCaught(error)
	}

	func channelInactive(context: ChannelHandlerContext) {
		let reason: SSHConnection.CloseReason
		if isDisconnecting() {
			reason = .localDisconnect
		} else if let exitSignal {
			let message = exitSignal.errorMessage.isEmpty
				? "Shell terminated by signal \(exitSignal.signalName)"
				: "Shell terminated by signal \(exitSignal.signalName): \(exitSignal.errorMessage)"
			reason = .error(message)
		} else if let exitStatus {
			reason = exitStatus == 0 ? .cleanExit : .error("Shell exited with status \(exitStatus)")
		} else if let caughtError {
			reason = .error(String(describing: caughtError))
		} else {
			reason = .error("Connection closed unexpectedly")
		}

		onClose(reason)
		context.fireChannelInactive()
	}
}
