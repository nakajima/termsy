import SwiftUI

struct TerminalFileDropOverlayView: View {
	@Environment(\.appTheme) private var theme
	let state: TerminalFileDropOverlayState
	var onDismissError: () -> Void

	var body: some View {
		if state.isPresented {
			ZStack {
				Color.black.opacity(0.001)
				content
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	@ViewBuilder
	private var content: some View {
		if let errorMessage = state.errorMessage {
			VStack(spacing: 12) {
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.largeTitle)
					.foregroundStyle(theme.error)
				Text("File Upload Failed")
					.font(.headline)
					.foregroundStyle(theme.primaryText)
					.accessibilityIdentifier("fileDrop.error.title")
				Text(errorMessage)
					.font(.callout)
					.multilineTextAlignment(.center)
					.foregroundStyle(theme.secondaryText)
					.accessibilityIdentifier("fileDrop.error.message")
				Button("Dismiss") {
					onDismissError()
				}
				.buttonStyle(.borderedProminent)
				.tint(theme.accent)
				.accessibilityIdentifier("fileDrop.error.dismiss")
			}
			.padding(24)
			.frame(maxWidth: 420)
			.background(theme.cardBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
			.overlay {
				RoundedRectangle(cornerRadius: 16)
					.stroke(theme.divider, lineWidth: 1)
			}
		} else if state.isUploading {
			VStack(spacing: 10) {
				ProgressView(value: state.progressFraction)
					.tint(theme.accent)
					.accessibilityIdentifier("fileDrop.upload.progress")
				Text(uploadTitle)
					.font(.headline)
					.foregroundStyle(theme.primaryText)
					.accessibilityIdentifier("fileDrop.upload.title")
				Text(uploadDetail)
					.font(.caption)
					.foregroundStyle(theme.secondaryText)
					.lineLimit(2)
					.multilineTextAlignment(.center)
					.accessibilityIdentifier("fileDrop.upload.detail")
			}
			.padding(18)
			.frame(maxWidth: 360)
			.background(theme.cardBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
			.overlay {
				RoundedRectangle(cornerRadius: 14)
					.stroke(theme.divider, lineWidth: 1)
			}
		}
	}

	private var uploadTitle: String {
		let fileWord = state.activeFileCount == 1 ? "file" : "files"
		return "Uploading \(state.activeFileCount) \(fileWord)..."
	}

	private var uploadDetail: String {
		var parts: [String] = []
		if let fraction = state.progressFraction {
			parts.append("\(Int((fraction * 100).rounded()))%")
		}
		if let currentFileName = state.currentFileName, !currentFileName.isEmpty {
			parts.append(currentFileName)
		}
		if state.queuedBatchCount > 0 {
			let queuedWord = state.queuedBatchCount == 1 ? "batch" : "batches"
			parts.append("\(state.queuedBatchCount) queued \(queuedWord)")
		}
		return parts.isEmpty ? "Preparing upload" : parts.joined(separator: " - ")
	}
}

#Preview("File Upload Progress") {
	TerminalFileDropOverlayView(
		state: .uploading(
			activeFileCount: 2,
			queuedBatchCount: 1,
			completedBytes: 43,
			totalBytes: 100,
			currentFileName: "report.pdf"
		),
		onDismissError: {}
	)
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}

#Preview("File Upload Error") {
	TerminalFileDropOverlayView(
		state: .error("SSH session is not connected."),
		onDismissError: {}
	)
	.background(TerminalTheme.mocha.appTheme.background)
	.environment(\.appTheme, TerminalTheme.mocha.appTheme)
}
