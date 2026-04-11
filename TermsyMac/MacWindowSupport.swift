#if os(macOS)
	import AppKit
	import SwiftUI

	enum MacDebugLogging {
		static let rawKeysEnvironmentKey = "TERMSY_LOG_RAW_KEYS"
		static let rawKeysDefaultsKey = "logRawMacKeyEvents"
		static let terminalIOEnvironmentKey = "TERMSY_LOG_TERMINAL_IO"
		static let terminalIODefaultsKey = "logMacTerminalIO"

		static func isEnabled(environmentKey: String, defaultsKey: String) -> Bool {
			let environmentValue = ProcessInfo.processInfo.environment[environmentKey]?
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.lowercased()
			if let environmentValue, ["1", "true", "yes", "on"].contains(environmentValue) {
				return true
			}
			return UserDefaults.standard.bool(forKey: defaultsKey)
		}

		static func describe(_ data: Data, limit: Int = 48) -> String {
			let preview = data.prefix(limit)
			let text = String(decoding: preview, as: UTF8.self)
			let hex = preview.map { String(format: "%02X", $0) }.joined(separator: " ")
			let suffix = data.count > limit ? "..." : ""
			return "bytes=\(data.count) utf8=\(String(reflecting: escaped(text, limit: limit) + suffix)) hex=\(hex)\(suffix)"
		}

		private static func escaped(_ string: String, limit: Int) -> String {
			var result = ""
			var emitted = 0
			for scalar in string.unicodeScalars {
				guard emitted < limit else {
					result.append("...")
					break
				}

				switch scalar.value {
				case 0x09:
					result.append("\\t")
				case 0x0A:
					result.append("\\n")
				case 0x0D:
					result.append("\\r")
				case 0x1B:
					result.append("\\e")
				case 0x20 ..< 0x7F:
					result.append(Character(scalar))
				default:
					if scalar.value < 0x20 || scalar.value == 0x7F {
						result.append(String(format: "\\u{%02X}", Int(scalar.value)))
					} else {
						result.append(Character(scalar))
					}
				}

				emitted += 1
			}
			return result
		}
	}

	final class TermsyTerminalWindow: NSWindow {
		private static var tabContextMenuObserver: NSObjectProtocol?
		private static let renameTabAction = #selector(TermsyTerminalWindow.renameTabFromSystemMenu(_:))

		private let rawKeyEventLogger = MacRawKeyEventLogger()
		var onRenameTabRequest: (() -> Void)?

		override init(
			contentRect: NSRect,
			styleMask style: NSWindow.StyleMask,
			backing bufferingType: NSWindow.BackingStoreType,
			defer flag: Bool
		) {
			super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
			Self.installTabContextMenuObserverIfNeeded()
		}

		@available(*, unavailable)
		required init?(coder _: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		override func sendEvent(_ event: NSEvent) {
			rawKeyEventLogger.handle(event, in: self)
			super.sendEvent(event)
		}

		@objc private func renameTabFromSystemMenu(_: Any?) {
			onRenameTabRequest?()
		}

		private static func installTabContextMenuObserverIfNeeded() {
			guard tabContextMenuObserver == nil else { return }
			tabContextMenuObserver = NotificationCenter.default.addObserver(
				forName: NSMenu.didBeginTrackingNotification,
				object: nil,
				queue: .main
			) { notification in
				guard let menu = notification.object as? NSMenu else { return }
				guard isAutomaticWindowTabContextMenu(menu) else { return }

				menu.items.removeAll { $0.action == renameTabAction }

				guard let referenceItem = menu.items.first,
				      let target = referenceItem.target
				else { return }

				let renameItem = NSMenuItem(title: "Rename Tab", action: renameTabAction, keyEquivalent: "")
				renameItem.target = target
				menu.insertItem(renameItem, at: 0)
			}
		}

		private static func isAutomaticWindowTabContextMenu(_ menu: NSMenu) -> Bool {
			let titles = Set(menu.items.map(\.title))
			return titles.contains("Close Tab")
				&& titles.contains("Move Tab to New Window")
				&& titles.contains("Show All Tabs")
		}
	}

	@MainActor
	final class MacRawKeyEventLogger {
		private static var didLogActivation = false

		private static var isEnabled: Bool {
			MacDebugLogging.isEnabled(
				environmentKey: MacDebugLogging.rawKeysEnvironmentKey,
				defaultsKey: MacDebugLogging.rawKeysDefaultsKey
			)
		}

		func handle(_ event: NSEvent, in window: NSWindow) {
			guard Self.isEnabled else { return }
			guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return }

			if !Self.didLogActivation {
				Self.didLogActivation = true
				print(
					"[KeyDebug] raw macOS key logging enabled (env: \(MacDebugLogging.rawKeysEnvironmentKey)=1, defaults: \(MacDebugLogging.rawKeysDefaultsKey)=true)"
				)
			}

			let firstResponderDescription = Self.describe(responder: window.firstResponder)
			let keyWindowMarker = window.isKeyWindow ? "key" : "not-key"
			let mainWindowMarker = window.isMainWindow ? "main" : "not-main"
			let charsDescription: String
			let charsIgnoringModifiersDescription: String
			let repeatDescription: String
			var extraFields: [String] = []

			switch event.type {
			case .keyDown, .keyUp:
				charsDescription = Self.reflect(event.characters)
				charsIgnoringModifiersDescription = Self.reflect(event.charactersIgnoringModifiers)
				repeatDescription = "\(event.isARepeat)"
			case .flagsChanged:
				charsDescription = "n/a"
				charsIgnoringModifiersDescription = "n/a"
				repeatDescription = "n/a"
				extraFields.append("modifierKey=\(Self.describeModifierKey(keyCode: event.keyCode))")
				extraFields.append("pressed=\(Self.isModifierPressed(for: event))")
			default:
				charsDescription = "n/a"
				charsIgnoringModifiersDescription = "n/a"
				repeatDescription = "n/a"
			}

			var fields = [
				"[KeyDebug]",
				"type=\(Self.describe(event.type))",
				"keyCode=\(event.keyCode)",
				"mods=\(Self.describe(modifierFlags: event.modifierFlags))",
				String(format: "modsRaw=0x%llx", UInt64(event.modifierFlags.rawValue)),
				"chars=\(charsDescription)",
				"charsIgnoringMods=\(charsIgnoringModifiersDescription)",
				"repeat=\(repeatDescription)",
				"window=\(keyWindowMarker)/\(mainWindowMarker)",
				"firstResponder=\(firstResponderDescription)",
			]
			fields.append(contentsOf: extraFields)
			print(fields.joined(separator: " "))
		}

		private static func describe(_ eventType: NSEvent.EventType) -> String {
			switch eventType {
			case .keyDown:
				return "keyDown"
			case .keyUp:
				return "keyUp"
			case .flagsChanged:
				return "flagsChanged"
			default:
				return String(describing: eventType)
			}
		}

		private static func describe(modifierFlags: NSEvent.ModifierFlags) -> String {
			let deviceIndependentFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
			var names: [String] = []
			if deviceIndependentFlags.contains(.capsLock) { names.append("caps") }
			if deviceIndependentFlags.contains(.shift) { names.append("shift") }
			if deviceIndependentFlags.contains(.control) { names.append("control") }
			if deviceIndependentFlags.contains(.option) { names.append("option") }
			if deviceIndependentFlags.contains(.command) { names.append("command") }
			if deviceIndependentFlags.contains(.numericPad) { names.append("numericPad") }
			if deviceIndependentFlags.contains(.help) { names.append("help") }
			if deviceIndependentFlags.contains(.function) { names.append("function") }
			return names.isEmpty ? "[]" : "[\(names.joined(separator: ","))]"
		}

		private static func describe(responder: NSResponder?) -> String {
			guard let responder else { return "nil" }
			if let view = responder as? NSView {
				return "\(String(describing: type(of: view))) frame=\(NSStringFromRect(view.frame))"
			}
			return String(describing: type(of: responder))
		}

		private static func describeModifierKey(keyCode: UInt16) -> String {
			switch keyCode {
			case 54:
				return "rightCommand"
			case 55:
				return "leftCommand"
			case 56:
				return "leftShift"
			case 57:
				return "capsLock"
			case 58:
				return "leftOption"
			case 59:
				return "leftControl"
			case 60:
				return "rightShift"
			case 61:
				return "rightOption"
			case 62:
				return "rightControl"
			case 63:
				return "function"
			default:
				return "unknown(\(keyCode))"
			}
		}

		private static func isModifierPressed(for event: NSEvent) -> Bool {
			let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			switch event.keyCode {
			case 54, 55:
				return flags.contains(.command)
			case 56, 60:
				return flags.contains(.shift)
			case 57:
				return flags.contains(.capsLock)
			case 58, 61:
				return flags.contains(.option)
			case 59, 62:
				return flags.contains(.control)
			case 63:
				return flags.contains(.function)
			default:
				return false
			}
		}

		private static func reflect(_ string: String?) -> String {
			guard let string else { return "nil" }
			return String(reflecting: string)
		}
	}

	extension Notification.Name {
		static let termsyPresentSSHSessionSheet = Notification.Name("TermsyPresentSSHSessionSheet")
	}

	struct MacWindowAccessor: NSViewRepresentable {
		@Binding var window: NSWindow?

		func makeNSView(context _: Context) -> NSView {
			let view = NSView()
			DispatchQueue.main.async {
				window = view.window
			}
			return view
		}

		func updateNSView(_ nsView: NSView, context _: Context) {
			DispatchQueue.main.async {
				window = nsView.window
			}
		}
	}
#endif
