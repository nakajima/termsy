//
//  ContentView.swift
//  Termsy
//
//  Created by Pat Nakajima on 4/2/26.
//

import GRDB
import GRDBQuery
import SwiftUI

struct ContentView: View {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.databaseContext) private var dbContext
	@State private var didAutoconnect = false

	var body: some View {
		@Bindable var coordinator = coordinator
		Group {
			if coordinator.tabs.isEmpty {
				NavigationStack(path: $coordinator.path) {
					SessionListView()
						.toolbar {
							ToolbarItem(placement: .topBarTrailing) {
								SheetButton(buttonLabel: { Label("Settings", systemImage: "gearshape") }) {
									SettingsView()
										.environment(coordinator)
								}
							}
						}
				}
			} else {
				VStack(spacing: 0) {
					TerminalTabBar()
					TerminalContainer()
				}
			}
		}
		.environment(coordinator)
		.sheet(isPresented: $coordinator.isShowingConnectView) {
			NavigationStack {
				ConnectView { session in
					coordinator.openTab(for: session)
				}
			}
		}
		.task {
			guard !didAutoconnect else { return }
			didAutoconnect = true

			let sessions = try? dbContext.reader.read { db in
				try Session
					.filter(Column("autoconnect") == true)
					.order(Column("lastConnectedAt").descNullsFirst)
					.fetchAll(db)
			}

			for session in sessions ?? [] {
				coordinator.openTab(for: session)
			}
		}
		// Cmd+1–9 keyboard shortcuts
		.background {
			ForEach(Array(coordinator.tabs.enumerated()), id: \.element.id) { index, tab in
				if index < 9 {
					Button("") { coordinator.selectTab(tab.session.id) }
						.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
						.hidden()
				}
			}
		}
	}
}

// MARK: - Tab Bar

private struct TerminalTabBar: View {
	@Environment(ViewCoordinator.self) var coordinator

	/// The session ID currently being dragged, nil if idle.
	@State private var draggedID: Session.ID?
	/// Horizontal offset of the dragged tab from its resting position.
	@State private var dragOffset: CGFloat = 0
	/// Measured widths of each tab, keyed by session ID.
	@State private var tabWidths: [Int64: CGFloat] = [:]

	var body: some View {
		HStack(spacing: 0) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 4) {
					ForEach(coordinator.tabs) { tab in
						let id = tab.session.id ?? 0
						let isDragging = draggedID == tab.session.id

						TabPill(tab: tab, isDragging: isDragging)
							.offset(x: isDragging ? dragOffset : 0)
							.zIndex(isDragging ? 1 : 0)
							.background(GeometryReader { geo in
								Color.clear.preference(key: TabWidthKey.self, value: [id: geo.size.width])
							})
							.gesture(
								DragGesture(minimumDistance: 8)
									.onChanged { value in
										// Only allow horizontal dragging
										if draggedID == nil {
											draggedID = tab.session.id
										}
										dragOffset = value.translation.width
										tryReorder(dragging: tab)
									}
									.onEnded { _ in
										withAnimation(.easeOut(duration: 0.2)) {
											dragOffset = 0
										}
										DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
											draggedID = nil
										}
									}
							)
					}
				}
				.onPreferenceChange(TabWidthKey.self) { tabWidths = $0 }
				.padding(.horizontal, 8)
				.padding(.vertical, 6)
			}

			// Trailing buttons
			HStack(spacing: 2) {
				Button {
					coordinator.isShowingConnectView = true
				} label: {
					Image(systemName: "plus")
						.font(.system(size: 12, weight: .medium))
						.frame(width: 28, height: 28)
						.contentShape(.rect)
				}
				.buttonStyle(.plain)
				.hoverEffect(.highlight)

				Button {
					for tab in coordinator.tabs { tab.sshSession.disconnect() }
					coordinator.tabs.removeAll()
					coordinator.selectedTabID = nil
				} label: {
					Image(systemName: "list.bullet")
						.font(.system(size: 12, weight: .medium))
						.frame(width: 28, height: 28)
						.contentShape(.rect)
				}
				.buttonStyle(.plain)
				.hoverEffect(.highlight)
			}
			.padding(.horizontal, 8)
		}
		.background(.bar)
	}

	private func tryReorder(dragging tab: TerminalTab) {
		guard let fromIndex = coordinator.tabs.firstIndex(where: { $0.session.id == tab.session.id }) else { return }
		let fromID = tab.session.id ?? 0

		// Calculate how far we've dragged in terms of tab positions
		let halfWidth = (tabWidths[fromID] ?? 100) / 2 + 2 // +2 for spacing

		if dragOffset > halfWidth {
			// Moving right
			let nextIndex = fromIndex + 1
			if nextIndex < coordinator.tabs.count {
				withAnimation(.easeInOut(duration: 0.2)) {
					coordinator.tabs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: nextIndex + 1)
				}
				// Adjust offset so the tab stays under the finger
				let neighborID = coordinator.tabs[fromIndex].session.id ?? 0
				let neighborWidth = tabWidths[neighborID] ?? 100
				dragOffset -= neighborWidth + 4
			}
		} else if dragOffset < -halfWidth {
			// Moving left
			let prevIndex = fromIndex - 1
			if prevIndex >= 0 {
				withAnimation(.easeInOut(duration: 0.2)) {
					coordinator.tabs.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: prevIndex)
				}
				let neighborID = coordinator.tabs[fromIndex].session.id ?? 0
				let neighborWidth = tabWidths[neighborID] ?? 100
				dragOffset += neighborWidth + 4
			}
		}
	}
}

private struct TabWidthKey: PreferenceKey {
	static var defaultValue: [Int64: CGFloat] = [:]
	static func reduce(value: inout [Int64: CGFloat], nextValue: () -> [Int64: CGFloat]) {
		value.merge(nextValue(), uniquingKeysWith: { $1 })
	}
}

// MARK: - Tab Pill

private struct TabPill: View {
	@Environment(ViewCoordinator.self) var coordinator
	let tab: TerminalTab
	let isDragging: Bool

	@State private var isHovering = false

	private var isSelected: Bool {
		coordinator.selectedTabID == tab.session.id
	}

	var body: some View {
		Button {
			coordinator.selectTab(tab.session.id)
		} label: {
			HStack(spacing: 6) {
				statusIcon
				Text("\(tab.session.username)@\(tab.session.hostname)")
					.font(.system(size: 12, weight: isSelected ? .medium : .regular))
					.lineLimit(1)
				closeButton
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(pillBackground, in: pillShape)
			.contentShape(pillShape)
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.scaleEffect(isDragging ? 1.03 : 1.0)
		.shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: 8, y: 2)
		.animation(.easeOut(duration: 0.15), value: isDragging)
		.contextMenu {
			Button("Close Tab") {
				coordinator.closeTab(tab.session.id)
			}
			Button("Close Other Tabs") {
				coordinator.closeOtherTabs(tab.session.id)
			}
			.disabled(coordinator.tabs.count <= 1)
		}
	}

	@ViewBuilder
	private var statusIcon: some View {
		if !tab.isConnected && tab.connectionError == nil {
			ProgressView()
				.controlSize(.mini)
		} else if tab.connectionError != nil {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 10))
				.foregroundStyle(.yellow)
		}
	}

	@ViewBuilder
	private var closeButton: some View {
		// Only show close button on hover or when selected
		if isHovering || isSelected {
			Button {
				withAnimation(.easeOut(duration: 0.2)) {
					coordinator.closeTab(tab.session.id)
				}
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(.secondary)
					.frame(width: 16, height: 16)
					.background(.quaternary, in: .circle)
			}
			.buttonStyle(.plain)
			.transition(.opacity.combined(with: .scale(scale: 0.5)))
		}
	}

	private var pillBackground: some ShapeStyle {
		if isSelected {
			AnyShapeStyle(.tint.opacity(0.15))
		} else if isHovering {
			AnyShapeStyle(.quaternary)
		} else {
			AnyShapeStyle(.clear)
		}
	}

	private var pillShape: some InsettableShape {
		Capsule()
	}
}

// MARK: - Terminal Container

private struct TerminalContainer: View {
	@Environment(ViewCoordinator.self) var coordinator

	var body: some View {
		ZStack {
			if let tab = coordinator.selectedTab {
				TerminalHostRepresentable(tab: tab)
					.id(tab.session.id)
					.ignoresSafeArea(.container, edges: .bottom)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task(id: coordinator.selectedTab?.sshSession.isForeground) {
			if let tab = coordinator.selectedTab, tab.sshSession.isForeground {
				await tab.sshSession.replayIfNeeded()
			}
		}
	}
}

#Preview {
	ContentView()
}
