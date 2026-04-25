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

	static func localLaunch(shellPath: String, environment: [String: String]) throws -> LocalLaunch? {
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
				let integrationFile = root.appendingPathComponent("termsy-title.zsh")
				try zshEnvScript.write(to: envfile, atomically: true, encoding: .utf8)
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
			throw error
		}
	}

	static func remoteStartupCommand(tmuxSessionName: String?) -> String {
		let script = remoteBootstrapScript(tmuxSessionName: tmuxSessionName)
		return "/bin/sh -lc \(shellQuoted(script))"
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
	  builtin unset TERMSY_TITLE_ORIGINAL_ZDOTDIR
	else
	  builtin unset ZDOTDIR
	fi

	{
	  builtin typeset _termsy_file=${ZDOTDIR-$HOME}/.zshenv
	  [[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"
	} always {
	  if [[ -o interactive ]]; then
	    builtin typeset _termsy_file="${TERMSY_TITLE_ZSH_INTEGRATION_FILE:-${${(%):-%x}:A:h}/termsy-title.zsh}"
	    [[ ! -r "$_termsy_file" ]] || builtin source -- "$_termsy_file"
	  fi
	  builtin unset _termsy_file
	}
	"""#

	private static let zshIntegrationScript = #"""
	if [[ -n "${TERMSY_TITLE_HOOKS_ACTIVE-}" ]]; then
	  return 0 2>/dev/null || exit 0
	fi
	typeset -g TERMSY_TITLE_HOOKS_ACTIVE=1

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
	  add-zsh-hook precmd _termsy_prompt_title
	  add-zsh-hook preexec _termsy_preexec_title
	else
	  typeset -ag precmd_functions preexec_functions
	  precmd_functions+=(_termsy_prompt_title)
	  preexec_functions+=(_termsy_preexec_title)
	fi

	_termsy_prompt_title
	"""#

	private static func remoteBootstrapScript(tmuxSessionName: String?) -> String {
		let termProgramVersionExport = if termProgramVersion.isEmpty {
			""
		} else {
			"export TERM_PROGRAM_VERSION=\(shellQuoted(termProgramVersion))\n"
		}

		let terminfoSetupScript = """
		ready=0
		if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then
		  ready=1
		elif command -v tic >/dev/null 2>&1; then
		  mkdir -p ~/.terminfo 2>/dev/null || true
		  if cat <<'__TERMSY_GHOSTTY_TERMINFO__' | tic -x - >/dev/null 2>&1; then
		\(GhosttyTerminfo.source)
		__TERMSY_GHOSTTY_TERMINFO__
		    ready=1
		  fi
		fi
		if [ "$ready" = 1 ]; then
		  export TERM=xterm-ghostty
		else
		  export TERM=xterm-256color
		fi
		"""

		let tmuxLaunchScript = if let tmuxSessionName, !tmuxSessionName.isEmpty {
			"""
			if command -v tmux >/dev/null 2>&1; then
			  tmux new-session -A -s \(shellQuoted(tmuxSessionName))
			  tmux_status=$?
			  if [ "$tmux_status" -ne 0 ]; then
			    printf 'Termsy: tmux exited with status %s; starting login shell\n' "$tmux_status" >&2
			  fi
			else
			  printf 'Termsy: tmux not found; starting login shell\n' >&2
			fi
			"""
		} else {
			""
		}

		let cacheRootScript = #"""
		shell_path=${SHELL:-}
		if [ -z "$shell_path" ] && [ -n "${USER:-}" ] && [ -r /etc/passwd ]; then
		  shell_path=$(awk -F: -v user="$USER" '$1 == user { print $7; exit }' /etc/passwd 2>/dev/null)
		fi
		[ -n "$shell_path" ] || shell_path=/bin/sh
		shell_name=${shell_path##*/}
		cache_root=${XDG_CACHE_HOME:-}
		if [ -z "$cache_root" ]; then
		  if [ -n "${HOME:-}" ]; then
		    cache_root="$HOME/.cache"
		  else
		    cache_root="${TMPDIR:-/tmp}"
		  fi
		fi
		cache_root="$cache_root/termsy-shell-title"
		export TERM_PROGRAM=ghostty
		export COLORTERM=truecolor
		"""# + termProgramVersionExport

		return """
		\(cacheRootScript)
		\(terminfoSetupScript)
		\(tmuxLaunchScript)
		case "$shell_name" in
		  bash)
		    bash_dir="$cache_root/bash"
		    mkdir -p "$bash_dir"
		    cat >"$bash_dir/termsy-title.bash" <<'__TERMSY_BASH__'
		\(bashScript)
		__TERMSY_BASH__
		    exec "$shell_path" --noprofile --norc --rcfile "$bash_dir/termsy-title.bash" -i
		    ;;
		  fish)
		    fish_dir="$cache_root/fish"
		    mkdir -p "$fish_dir/fish/vendor_conf.d"
		    cat >"$fish_dir/fish/vendor_conf.d/termsy-title.fish" <<'__TERMSY_FISH__'
		\(fishScript)
		__TERMSY_FISH__
		    if [ -n "${XDG_DATA_DIRS:-}" ]; then
		      export XDG_DATA_DIRS="$fish_dir:$XDG_DATA_DIRS"
		    else
		      export XDG_DATA_DIRS="$fish_dir:/usr/local/share:/usr/share"
		    fi
		    exec "$shell_path" -i -l
		    ;;
		  zsh)
		    zsh_dir="$cache_root/zsh"
		    mkdir -p "$zsh_dir"
		    cat >"$zsh_dir/.zshenv" <<'__TERMSY_ZSHENV__'
		\(zshEnvScript)
		__TERMSY_ZSHENV__
		    cat >"$zsh_dir/termsy-title.zsh" <<'__TERMSY_ZSH__'
		\(zshIntegrationScript)
		__TERMSY_ZSH__
		    if [ "${ZDOTDIR+set}" = set ]; then
		      export TERMSY_TITLE_ORIGINAL_ZDOTDIR="$ZDOTDIR"
		    fi
		    export TERMSY_TITLE_ZSH_INTEGRATION_FILE="$zsh_dir/termsy-title.zsh"
		    export ZDOTDIR="$zsh_dir"
		    exec "$shell_path" -i -l
		    ;;
		  *)
		    exec "$shell_path"
		    ;;
		esac
		"""
	}
}

final nonisolated class SSHConnection: @unchecked Sendable {
	enum CloseReason: Sendable {
		case localDisconnect
		case cleanExit
		case error(String)
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
	private var hasReceivedData = false
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
		startupOutputGraceNanoseconds: UInt64 = 500_000_000
	) async throws {
		pendingTerminalSize = size
		log("startShell \(size.columns)x\(size.rows) px=\(size.pixelWidth)x\(size.pixelHeight)")
		guard let channel else { throw SSHConnectionError.notConnected }

		let onData: @Sendable (Data) -> Void = { [weak self] data in
			self?.hasReceivedData = true
			self?.onData(data)
		}
		let onClose = self.onClose

		do {
			// All channel/pipeline operations must run on the NIO event loop.
			let authDelegate = self.authDelegate
			let childChannel: Channel = try await withTimeout(
				channel.eventLoop.flatSubmit {
					self.log("creating session channel...")
					let sshHandler = try! channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
					let promise = channel.eventLoop.makePromise(of: Channel.self)

					// If auth already failed before we got here, fail immediately.
					if authDelegate?.hasFailed == true {
						promise.fail(SSHConnectionError.authenticationFailed)
						return promise.futureResult
					}

					// If auth fails after this point, fail the promise so we don't hang.
					authDelegate?.onExhausted = {
						promise.fail(SSHConnectionError.authenticationFailed)
					}

					sshHandler.createChannel(promise) { childChannel, channelType in
						self.log("child channel init, type=\(channelType)")
						guard channelType == .session else {
							return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
						}
						return childChannel.pipeline.addHandlers([
							SSHChannelDataHandler(onData: onData),
							SSHChannelLifecycleHandler(
								isDisconnecting: { [weak self] in self?.isDisconnecting ?? false },
								onClose: { [weak self] reason in
									self?.sshChildChannel = nil
									self?.channel = nil
									self?.authDelegate = nil
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

			sshChildChannel = childChannel
			log("session channel open")

			// Request PTY
			let ptyReq = SSHChannelRequestEvent.PseudoTerminalRequest(
				wantReply: true,
				term: "xterm-256color",
				terminalCharacterWidth: size.columns,
				terminalRowHeight: size.rows,
				terminalPixelWidth: size.pixelWidth,
				terminalPixelHeight: size.pixelHeight,
				terminalModes: .init([:])
			)
			try await withTimeout(
				childChannel.triggerUserOutboundEvent(ptyReq),
				on: childChannel.eventLoop,
				timeout: Self.channelRequestTimeout,
				error: .timedOut("allocating a remote PTY")
			).get()
			log("PTY allocated")

			if let startupCommand {
				// Try ExecRequest first for shell title integration.
				// Some servers (like sshui-based ones) don't handle exec properly,
				// so we fall back to ShellRequest if no data arrives.
				hasReceivedData = false
				let execReq = SSHChannelRequestEvent.ExecRequest(command: startupCommand, wantReply: true)
				try await withTimeout(
					childChannel.triggerUserOutboundEvent(execReq),
					on: childChannel.eventLoop,
					timeout: Self.channelRequestTimeout,
					error: .timedOut("starting the remote shell")
				).get()
				log("exec request sent, waiting for data...")
				resize(pendingTerminalSize)

				// Wait briefly for the server to respond before falling back to ShellRequest.
				// Direct tmux startup can take longer than a plain shell prompt.
				try await Task.sleep(nanoseconds: startupOutputGraceNanoseconds)

				if hasReceivedData {
					log("exec request worked, data received")
				} else {
					// Server accepted exec but didn't send data - likely doesn't
					// handle exec properly. Try ShellRequest on same channel.
					log("no data after exec, sending ShellRequest on same channel")
					let shellReq = SSHChannelRequestEvent.ShellRequest(wantReply: true)
					try await withTimeout(
						childChannel.triggerUserOutboundEvent(shellReq),
						on: childChannel.eventLoop,
						timeout: Self.channelRequestTimeout,
						error: .timedOut("starting the remote shell")
					).get()
					log("shell started (fallback)")
				}
			} else {
				let shellReq = SSHChannelRequestEvent.ShellRequest(wantReply: true)
				try await withTimeout(
					childChannel.triggerUserOutboundEvent(shellReq),
					on: childChannel.eventLoop,
					timeout: Self.channelRequestTimeout,
					error: .timedOut("starting the remote shell")
				).get()
				log("shell started")
				resize(pendingTerminalSize)
			}
		} catch {
			disconnect()
			throw error
		}
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
		let previousSize = pendingTerminalSize
		pendingTerminalSize = size
		// Re-sending the same character grid can make remote TUIs redraw on tab switches.
		guard size.columns != previousSize.columns || size.rows != previousSize.rows else { return }
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
