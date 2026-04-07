#if canImport(UIKit)
//
//  TabBarView.swift
//  Termsy
//
//  UIKit-based tab bar with liquid glass pills.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Bridge

struct TabBarRepresentable: UIViewRepresentable {
	@Environment(ViewCoordinator.self) var coordinator
	@Environment(\.appTheme) private var theme

	func makeUIView(context: Context) -> TabBarCollectionView {
		let view = TabBarCollectionView()
		view.onSelectTab = { [coordinator] id in coordinator.selectTab(id) }
		view.onCloseTab = { [coordinator] id in coordinator.closeTab(id) }
		view.onCloseOtherTabs = { [coordinator] id in coordinator.closeOtherTabs(id) }
		view.onReorderTabs = { [coordinator] ids in coordinator.reorderTabs(ids) }
		view.onAddTab = { [coordinator] in coordinator.openNewTabUI() }
		view.onSettings = { [coordinator] in coordinator.openSettings() }
		view.applyTheme(theme)
		view.update(tabs: coordinator.tabs, selectedID: coordinator.selectedTabID)
		return view
	}

	func updateUIView(_ view: TabBarCollectionView, context: Context) {
		view.onSelectTab = { [coordinator] id in coordinator.selectTab(id) }
		view.onCloseTab = { [coordinator] id in coordinator.closeTab(id) }
		view.onCloseOtherTabs = { [coordinator] id in coordinator.closeOtherTabs(id) }
		view.onReorderTabs = { [coordinator] ids in coordinator.reorderTabs(ids) }
		view.onAddTab = { [coordinator] in coordinator.openNewTabUI() }
		view.onSettings = { [coordinator] in coordinator.openSettings() }
		view.applyTheme(theme)
		view.update(tabs: coordinator.tabs, selectedID: coordinator.selectedTabID)
	}
}

// MARK: - Tab Data

nonisolated struct TabBarItem: Hashable, Sendable {
	let id: UUID
	let title: String
	let isConnected: Bool
	let hasError: Bool
}

// MARK: - Collection View

private let tabBarHeight: CGFloat = 44
private let pillInsetV: CGFloat = 5
private let minCellWidth: CGFloat = 120
private let cellSpacing: CGFloat = 6

final class TabBarCollectionView: UIView {
	var onSelectTab: ((UUID) -> Void)?
	var onCloseTab: ((UUID) -> Void)?
	var onCloseOtherTabs: ((UUID) -> Void)?
	var onReorderTabs: (([UUID]) -> Void)?
	var onAddTab: (() -> Void)?
	var onSettings: (() -> Void)?

	private var theme: AppTheme = TerminalTheme.current.appTheme
	private var collectionView: UICollectionView!
	private var dataSource: UICollectionViewDiffableDataSource<Int, TabBarItem>!
	private var items: [TabBarItem] = []
	private var selectedID: UUID?
	private var addButton: UIButton!
	private var settingsButton: UIButton!

	override init(frame: CGRect) {
		super.init(frame: frame)
		setup()
	}

	required init?(coder: NSCoder) { fatalError() }

	private func setup() {
		backgroundColor = theme.backgroundUIColor

		let layout = UICollectionViewFlowLayout()
		layout.scrollDirection = .horizontal
		layout.minimumInteritemSpacing = cellSpacing
		layout.minimumLineSpacing = cellSpacing
		layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)

		collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
		collectionView.translatesAutoresizingMaskIntoConstraints = false
		collectionView.backgroundColor = .clear
		collectionView.showsHorizontalScrollIndicator = false
		collectionView.delegate = self
		collectionView.alwaysBounceHorizontal = false
		collectionView.clipsToBounds = false
		addSubview(collectionView)

		// Enable drag & drop reorder
		collectionView.dragInteractionEnabled = true
		collectionView.dragDelegate = self
		collectionView.dropDelegate = self

		// Settings button
		settingsButton = UIButton(type: .system)
		settingsButton.translatesAutoresizingMaskIntoConstraints = false
		let gearImage = UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
		settingsButton.setImage(gearImage, for: .normal)
		settingsButton.tintColor = theme.secondaryTextUIColor
		settingsButton.addAction(UIAction { [weak self] _ in self?.onSettings?() }, for: .touchUpInside)
		addSubview(settingsButton)

		// + button
		addButton = UIButton(type: .system)
		addButton.translatesAutoresizingMaskIntoConstraints = false
		let plusImage = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
		addButton.setImage(plusImage, for: .normal)
		addButton.tintColor = theme.secondaryTextUIColor
		addButton.addAction(UIAction { [weak self] _ in self?.onAddTab?() }, for: .touchUpInside)
		addSubview(addButton)

		NSLayoutConstraint.activate([
			collectionView.topAnchor.constraint(equalTo: topAnchor),
			collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
			collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
			collectionView.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor),

			settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			settingsButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
			settingsButton.widthAnchor.constraint(equalToConstant: 36),

			addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			addButton.widthAnchor.constraint(equalToConstant: 36),
			addButton.heightAnchor.constraint(equalToConstant: 36),
		])

		let cellRegistration = UICollectionView.CellRegistration<TabBarCell, TabBarItem> { [weak self] cell, _, item in
			guard let self else { return }
			cell.applyTheme(self.theme)
			cell.configure(item: item, isSelected: item.id == self.selectedID)
			cell.onClose = { [weak self] in self?.onCloseTab?(item.id) }
		}

		dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
			collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
		}

		// Enable reordering in data source
		dataSource.reorderingHandlers.canReorderItem = { _ in true }
		dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
			guard let self else { return }
			// Rebuild items from the final snapshot
			let newItems = transaction.finalSnapshot.itemIdentifiers
			self.items = newItems
			self.onReorderTabs?(newItems.map(\.id))
		}
	}

	func applyTheme(_ theme: AppTheme) {
		self.theme = theme
		backgroundColor = theme.backgroundUIColor
		collectionView?.backgroundColor = .clear
		addButton?.tintColor = theme.secondaryTextUIColor
		for cell in collectionView.visibleCells {
			guard let tabCell = cell as? TabBarCell else { continue }
			tabCell.applyTheme(theme)
		}
	}

	@MainActor
	func update(tabs: [TerminalTab], selectedID: UUID?) {
		self.selectedID = selectedID
		backgroundColor = theme.backgroundUIColor

		let newItems = tabs.map { tab in
			TabBarItem(id: tab.id, title: tab.displayTitle, isConnected: tab.isConnected, hasError: tab.connectionError != nil)
		}

		let changed = newItems != items
		items = newItems

		var snapshot = NSDiffableDataSourceSnapshot<Int, TabBarItem>()
		snapshot.appendSections([0])
		snapshot.appendItems(items)

		if changed {
			dataSource.apply(snapshot, animatingDifferences: true)
		} else {
			dataSource.apply(snapshot, animatingDifferences: false)
			for cell in collectionView.visibleCells {
				guard let tabCell = cell as? TabBarCell,
				      let indexPath = collectionView.indexPath(for: cell),
				      indexPath.item < items.count else { continue }
				let item = items[indexPath.item]
				tabCell.configure(item: item, isSelected: item.id == self.selectedID)
			}
		}
	}

	override var intrinsicContentSize: CGSize {
		CGSize(width: UIView.noIntrinsicMetric, height: tabBarHeight)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		collectionView.collectionViewLayout.invalidateLayout()
	}
}

// MARK: - Flow Layout Delegate

extension TabBarCollectionView: UICollectionViewDelegateFlowLayout {
	func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
		let count = max(CGFloat(items.count), 1)
		let insets: CGFloat = 8
		let totalSpacing = cellSpacing * max(count - 1, 0)
		let availableWidth = collectionView.bounds.width - insets - totalSpacing
		let idealWidth = availableWidth / count
		let width = max(idealWidth, minCellWidth)
		return CGSize(width: width, height: tabBarHeight)
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		collectionView.deselectItem(at: indexPath, animated: false)
		guard indexPath.item < items.count else { return }
		onSelectTab?(items[indexPath.item].id)
	}

	func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
		guard let indexPath = indexPaths.first, indexPath.item < items.count else { return nil }
		let item = items[indexPath.item]
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
			let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark")) { _ in
				self?.onCloseTab?(item.id)
			}
			var actions: [UIMenuElement] = [close]
			if (self?.items.count ?? 0) > 1 {
				let closeOthers = UIAction(title: "Close Other Tabs", image: UIImage(systemName: "xmark.circle")) { _ in
					self?.onCloseOtherTabs?(item.id)
				}
				actions.append(closeOthers)
			}
			return UIMenu(children: actions)
		}
	}
}

// MARK: - Drag & Drop

extension TabBarCollectionView: UICollectionViewDragDelegate {
	func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
		let item = UIDragItem(itemProvider: NSItemProvider())
		item.localObject = items[indexPath.item]
		return [item]
	}

	func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
		guard let cell = collectionView.cellForItem(at: indexPath) as? TabBarCell else { return nil }
		let params = UIDragPreviewParameters()
		params.visiblePath = UIBezierPath(roundedRect: cell.glassFrame, cornerRadius: cell.glassFrame.height / 2)
		return params
	}
}

extension TabBarCollectionView: UICollectionViewDropDelegate {
	func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
		if collectionView.hasActiveDrag {
			return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
		}
		return UICollectionViewDropProposal(operation: .forbidden)
	}

	func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
		// Handled by diffable data source reorderingHandlers
	}
}

// MARK: - Cell

private final class TabBarCell: UICollectionViewCell {
	var onClose: (() -> Void)?

	private var theme: AppTheme = TerminalTheme.current.appTheme
	private let pillContainer = UIView()
	private let glassView = UIVisualEffectView(effect: UIGlassEffect())
	private let titleLabel = UILabel()
	private let statusView = UIImageView()
	private let closeButton = UIButton()
	private var isCurrentlySelected = false

	/// Exposed for drag preview clipping.
	var glassFrame: CGRect {
		pillContainer.frame
	}

	override init(frame: CGRect) {
		super.init(frame: frame)

		contentView.clipsToBounds = false
		contentView.backgroundColor = .clear
		backgroundColor = .clear
		var bgConfig = UIBackgroundConfiguration.clear()
		bgConfig.backgroundColor = .clear
		backgroundConfiguration = bgConfig

		// Clipping container for the pill shape
		pillContainer.translatesAutoresizingMaskIntoConstraints = false
		pillContainer.clipsToBounds = true
		pillContainer.layer.cornerCurve = .continuous
		pillContainer.layer.cornerRadius = (tabBarHeight - pillInsetV * 2) / 2
		pillContainer.layer.borderWidth = 0.5
		pillContainer.layer.borderColor = theme.dividerUIColor.cgColor
		contentView.addSubview(pillContainer)

		// Glass effect fills the container
		glassView.translatesAutoresizingMaskIntoConstraints = false
		pillContainer.addSubview(glassView)

		// Status icon
		statusView.contentMode = .scaleAspectFit
		statusView.translatesAutoresizingMaskIntoConstraints = false
		statusView.isHidden = true
		pillContainer.addSubview(statusView)

		// Centered title
		titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
		titleLabel.textColor = theme.secondaryTextUIColor
		titleLabel.textAlignment = .center
		titleLabel.lineBreakMode = .byTruncatingMiddle
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		pillContainer.addSubview(titleLabel)

		// Close button (overlaid trailing)
		var closeConfig = UIButton.Configuration.plain()
		closeConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold))
		closeConfig.baseForegroundColor = theme.tertiaryTextUIColor
		closeConfig.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
		closeButton.configuration = closeConfig
		closeButton.translatesAutoresizingMaskIntoConstraints = false
		closeButton.alpha = 0
		closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
		pillContainer.addSubview(closeButton)

		NSLayoutConstraint.activate([
			pillContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			pillContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			pillContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pillInsetV),
			pillContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -pillInsetV),

			glassView.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor),
			glassView.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor),
			glassView.topAnchor.constraint(equalTo: pillContainer.topAnchor),
			glassView.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor),

			statusView.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 12),
			statusView.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
			statusView.widthAnchor.constraint(equalToConstant: 12),
			statusView.heightAnchor.constraint(equalToConstant: 12),

			titleLabel.centerXAnchor.constraint(equalTo: pillContainer.centerXAnchor),
			titleLabel.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
			titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pillContainer.leadingAnchor, constant: 28),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pillContainer.trailingAnchor, constant: -28),

			closeButton.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -6),
			closeButton.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
		])

		let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
		contentView.addGestureRecognizer(hover)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		if pillContainer.bounds.height > 0 {
			pillContainer.layer.cornerRadius = pillContainer.bounds.height / 2
		}
	}

	func applyTheme(_ theme: AppTheme) {
		self.theme = theme
		backgroundColor = .clear
		titleLabel.textColor = theme.secondaryTextUIColor
		statusView.tintColor = theme.warningUIColor
		pillContainer.layer.borderColor = theme.dividerUIColor.cgColor
		var closeConfig = closeButton.configuration
		closeConfig?.baseForegroundColor = theme.tertiaryTextUIColor
		closeButton.configuration = closeConfig
		if !isCurrentlySelected {
			pillContainer.backgroundColor = theme.cardBackgroundUIColor.withAlphaComponent(0.6)
		}
	}

	func configure(item: TabBarItem, isSelected: Bool) {
		isCurrentlySelected = isSelected

		titleLabel.text = item.title
		titleLabel.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .medium)
		titleLabel.textColor = isSelected ? theme.primaryTextUIColor : theme.secondaryTextUIColor

		if !item.isConnected && !item.hasError {
			statusView.isHidden = true
		} else if item.hasError {
			statusView.image = UIImage(systemName: "exclamationmark.triangle.fill")
			statusView.tintColor = theme.warningUIColor
			statusView.isHidden = false
		} else {
			statusView.isHidden = true
		}

		if isSelected {
			let effect = UIGlassEffect()
			effect.isInteractive = true
			glassView.effect = effect
			glassView.alpha = 1
			pillContainer.backgroundColor = theme.selectedBackgroundUIColor.withAlphaComponent(0.8)
			pillContainer.layer.borderColor = theme.accentUIColor.withAlphaComponent(0.45).cgColor
			closeButton.alpha = 1
		} else {
			glassView.effect = nil
			glassView.alpha = 0
			pillContainer.backgroundColor = theme.cardBackgroundUIColor.withAlphaComponent(0.6)
			pillContainer.layer.borderColor = theme.dividerUIColor.cgColor
			closeButton.alpha = 0
		}
	}

	@objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
		switch recognizer.state {
		case .began, .changed:
			if closeButton.alpha == 0 {
				UIView.animate(withDuration: 0.12) { self.closeButton.alpha = 1 }
			}
		case .ended, .cancelled:
			if !isCurrentlySelected {
				UIView.animate(withDuration: 0.12) { self.closeButton.alpha = 0 }
			}
		default:
			break
		}
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		titleLabel.text = nil
		statusView.image = nil
		statusView.isHidden = true
		closeButton.alpha = 0
		isCurrentlySelected = false
		onClose = nil
	}
}
#endif
