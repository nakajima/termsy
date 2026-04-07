import SwiftUI

extension View {
	@ViewBuilder
	func termsyInlineNavigationTitle() -> some View {
		#if os(iOS)
		self.navigationBarTitleDisplayMode(.inline)
		#else
		self
		#endif
	}

	@ViewBuilder
	func termsyNavigationBarAppearance(_ theme: AppTheme) -> some View {
		#if os(iOS)
		self
			.toolbarBackground(theme.elevatedBackground, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(theme.colorScheme, for: .navigationBar)
		#else
		self
		#endif
	}
}

extension ToolbarItemPlacement {
	static var termsyPrimaryAction: Self {
		#if os(macOS)
		.primaryAction
		#else
		.topBarTrailing
		#endif
	}

	static var termsyCancellationAction: Self {
		#if os(macOS)
		.cancellationAction
		#else
		.topBarLeading
		#endif
	}
}
