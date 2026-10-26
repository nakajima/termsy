import Foundation
@testable import Termsy
import Testing
import UniformTypeIdentifiers

struct TerminalFileDropTests {
	@Test func recognizesFileItemsButNotText() {
		let inPlaceFile = NSItemProvider()
		inPlaceFile.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [.openInPlace], visibility: .all) { completion in
			completion(nil, false, nil)
			return nil
		}
		let copiedFile = NSItemProvider()
		copiedFile.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
			completion(nil, false, nil)
			return nil
		}
		let text = NSItemProvider(object: "not a file" as NSString)
		let fileURL = NSItemProvider(
			item: URL(fileURLWithPath: "/tmp/x").dataRepresentation as NSData,
			typeIdentifier: UTType.fileURL.identifier
		)

		#expect(TerminalFileDropSupport.itemProviderIsFile(inPlaceFile))
		#expect(TerminalFileDropSupport.itemProviderIsFile(fileURL))
		#expect(!TerminalFileDropSupport.itemProviderIsFile(text))
		// Providers without in-place files look like text, so they are still refused.
		#expect(!TerminalFileDropSupport.itemProviderIsFile(copiedFile))
	}

	@Test func stagesDroppedFilesUntilTheBatchIsDone() throws {
		let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("drop-source-\(UUID().uuidString).txt")
		try Data("dropped".utf8).write(to: sourceURL)
		defer { try? FileManager.default.removeItem(at: sourceURL) }

		let stagingDirectory = TerminalFileDropSupport.makeStagingDirectory()
		let stagedURL = try TerminalFileDropSupport.stageDroppedFile(at: sourceURL, preferredName: "notes/report.txt", in: stagingDirectory)

		#expect(stagedURL.lastPathComponent == "notes_report.txt")
		#expect(stagedURL.path.hasPrefix(stagingDirectory.path))
		#expect(FileManager.default.contents(atPath: stagedURL.path) == Data("dropped".utf8))

		TerminalFileDropBatch(urls: [stagedURL], stagingDirectory: stagingDirectory).removeStagedFiles()
		#expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
	}
}
