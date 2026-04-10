// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "TermsyGhostty",
	platforms: [
		.iOS(.v16),
		.macOS(.v13),
	],
	products: [
		.library(name: "TermsyGhosttyKit", targets: ["TermsyGhosttyKit"]),
		.library(name: "TermsyGhosttyCore", targets: ["TermsyGhosttyCore"]),
	],
	targets: [
		.binaryTarget(
			name: "TermsyLibghostty",
			path: "BinaryTarget/libghostty.xcframework"
		),
		.target(
			name: "TermsyGhosttyKit",
			dependencies: ["TermsyLibghostty"],
			path: "Sources/TermsyGhosttyKit",
			linkerSettings: [
				.linkedLibrary("c++"),
				.linkedFramework("Carbon", .when(platforms: [.macOS])),
			]
		),
		.target(
			name: "TermsyGhosttyCore",
			dependencies: ["TermsyGhosttyKit"],
			path: "Sources/TermsyGhosttyCore"
		),
	]
)
