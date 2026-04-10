#if canImport(AppKit) && !canImport(UIKit)
	import AppKit
	import GRDB
	import GRDBQuery
	import SwiftUI

	struct TabBarRepresentable: View {
		@Environment(ViewCoordinator.self) private var coordinator
		@Environment(\.databaseContext) private var dbContext
		@Environment(\.appTheme) private var theme

		var body: some View {
			HStack(spacing: 8) {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(coordinator.tabs) { tab in
							HStack(spacing: 8) {
								Button {
									coordinator.selectTab(tab.id)
								} label: {
									HStack(spacing: 8) {
										if tab.connectionError != nil {
											Image(systemName: "exclamationmark.triangle.fill")
												.foregroundStyle(theme.warning)
										}
										Text(tab.displayTitle)
											.lineLimit(1)
											.foregroundStyle(tab.id == coordinator.selectedTabID ? theme.primaryText : theme.secondaryText)
									}
								}
								.buttonStyle(.plain)

								Button {
									coordinator.closeTab(tab.id)
								} label: {
									Image(systemName: "xmark")
										.font(.system(size: 10, weight: .bold))
								}
								.buttonStyle(.plain)
								.foregroundStyle(theme.tertiaryText)
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 7)
							.background(
								Capsule()
									.fill(tab.id == coordinator.selectedTabID ? theme.selectedBackground : theme.cardBackground)
							)
							.overlay(
								Capsule()
									.stroke(tab.id == coordinator.selectedTabID ? theme.accent.opacity(0.35) : theme.divider, lineWidth: 1)
							)
							.contextMenu {
								Button("Rename Tab") {
									presentRenameAlert(for: tab)
								}

								Button("Close Tab") {
									coordinator.closeTab(tab.id)
								}

								if coordinator.tabs.count > 1 {
									Button("Close Other Tabs") {
										coordinator.closeOtherTabs(tab.id)
									}
								}
							}
						}
					}
				}

				Spacer(minLength: 0)

				Button {
					coordinator.openSettings()
				} label: {
					Image(systemName: "gearshape")
				}
				.buttonStyle(.plain)
				.foregroundStyle(theme.secondaryText)

				Button {
					coordinator.openNewTabUI()
				} label: {
					Image(systemName: "plus")
				}
				.buttonStyle(.plain)
				.foregroundStyle(theme.secondaryText)
			}
			.padding(.horizontal, 10)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(theme.background)
		}

		private func presentRenameAlert(for tab: TerminalTab) {
			let alert = NSAlert()
			alert.messageText = "Rename Tab"
			alert.informativeText = "Leave blank to use the automatic title."

			let textField = NSTextField(string: tab.customTitle ?? "")
			textField.placeholderString = tab.automaticTitle
			textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
			alert.accessoryView = textField

			alert.addButton(withTitle: "Save")
			alert.addButton(withTitle: "Use Automatic Title")
			alert.addButton(withTitle: "Cancel")

			let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
				switch response {
				case .alertFirstButtonReturn:
					persistRename(for: tab, title: textField.stringValue)
				case .alertSecondButtonReturn:
					persistRename(for: tab, title: nil)
				default:
					break
				}
			}

			if let window = NSApp.keyWindow ?? NSApp.mainWindow {
				alert.beginSheetModal(for: window) { response in
					handleResponse(response)
				}
				DispatchQueue.main.async {
					window.makeFirstResponder(textField)
					textField.selectText(nil)
				}
			} else {
				handleResponse(alert.runModal())
			}
		}

		private func persistRename(for tab: TerminalTab, title: String?) {
			coordinator.renameTab(tab.id, to: title)

			guard var session = tab.session else { return }
			do {
				try dbContext.writer.write { db in
					if session.id == nil {
						try session.save(db)
					} else {
						try session.update(db)
					}
				}
				tab.session = session
			} catch {
				print("[DB] failed to persist customTitle for session \(session.id.map(String.init) ?? "new"): \(error)")
			}
		}
	}
#endif
