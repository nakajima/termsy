#!/usr/bin/env swift

import AppKit
import CoreGraphics
import ImageIO
import Foundation

struct Configuration {
	let sourcePNG: URL
	let outputRoot: URL
	let legacyInsetScale: CGFloat
}

enum ScriptError: LocalizedError {
	case usage(String)
	case invalidSource(String)
	case missingSource(String)
	case invalidInset(String)
	case imageReadFailed(String)
	case invalidDimensions(width: Int, height: Int)
	case contextCreationFailed(size: Int)

	var errorDescription: String? {
		switch self {
		case let .usage(message),
			 let .invalidSource(message),
			 let .missingSource(message),
			 let .invalidInset(message),
			 let .imageReadFailed(message):
			return message
		case let .invalidDimensions(width, height):
			return "Source image must be exactly 1024x1024 pixels. Got \(width)x\(height)."
		case let .contextCreationFailed(size):
			return "Failed to create bitmap context for legacy icon size \(size)."
		}
	}
}

private let defaultLegacyInsetScale: CGFloat = 0.90
private let iconComposerImageName = "termsyicon.png"

private let iconComposerJSONTemplate = #"""
{
  "fill" : {
    "automatic-gradient" : "display-p3:0.00000,0.00000,0.00000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "blend-mode" : "normal",
          "fill" : "none",
          "glass" : false,
          "hidden" : false,
          "image-name" : "termsyicon.png",
          "name" : "termsyicon"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}
"""#

private let appIconContentsJSONTemplate = #"""
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""#

private let legacyVariants: [(filename: String, size: Int)] = [
	("icon_16x16.png", 16),
	("icon_16x16@2x.png", 32),
	("icon_32x32.png", 32),
	("icon_32x32@2x.png", 64),
	("icon_128x128.png", 128),
	("icon_128x128@2x.png", 256),
	("icon_256x256.png", 256),
	("icon_256x256@2x.png", 512),
	("icon_512x512.png", 512),
	("icon_512x512@2x.png", 1024),
]

struct UpdateMacOSAppIconScript {
	static func parseArguments(_ arguments: [String]) throws -> Configuration {
		let usage = """
		Usage:
		  ./scripts/update_macos_app_icon.swift <source-1024.png> [--legacy-inset 0.90] [--output-root /path/to/repo]

		Notes:
		  - The source image must be exactly 1024x1024 pixels.
		  - The script updates both:
		      * TermsyMac/AppIcon.icon/Assets/termsyicon.png
		      * TermsyMac/Assets.xcassets/AppIcon.appiconset/icon_*.png
		  - The current Icon Composer template is preserved if icon.json already exists.
		    If it does not exist, the script recreates it with the checked-in single-layer template.
		"""

		guard arguments.count >= 2 else {
			throw ScriptError.usage(usage)
		}

		var sourcePath: String?
		var outputRoot: URL?
		var legacyInsetScale = defaultLegacyInsetScale

		var index = 1
		while index < arguments.count {
			let argument = arguments[index]
			switch argument {
			case "-h", "--help":
				throw ScriptError.usage(usage)
			case "--output-root":
				guard index + 1 < arguments.count else {
					throw ScriptError.usage(usage)
				}
				outputRoot = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
				index += 2
			case "--legacy-inset":
				guard index + 1 < arguments.count else {
					throw ScriptError.usage(usage)
				}
				guard let value = Double(arguments[index + 1]), value > 0, value <= 1 else {
					throw ScriptError.invalidInset("--legacy-inset must be a number between 0 and 1.")
				}
				legacyInsetScale = CGFloat(value)
				index += 2
			default:
				if argument.hasPrefix("--") {
					throw ScriptError.usage(usage)
				}
				guard sourcePath == nil else {
					throw ScriptError.usage(usage)
				}
				sourcePath = argument
				index += 1
			}
		}

		guard let sourcePath else {
			throw ScriptError.usage(usage)
		}

		let sourcePNG = URL(fileURLWithPath: sourcePath)
		guard FileManager.default.fileExists(atPath: sourcePNG.path) else {
			throw ScriptError.missingSource("Source PNG not found: \(sourcePNG.path)")
		}
		guard sourcePNG.pathExtension.lowercased() == "png" else {
			throw ScriptError.invalidSource("Source file must be a PNG: \(sourcePNG.path)")
		}

		let resolvedOutputRoot = outputRoot ?? URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent() // scripts
			.deletingLastPathComponent() // repo root

		return Configuration(
			sourcePNG: sourcePNG,
			outputRoot: resolvedOutputRoot,
			legacyInsetScale: legacyInsetScale
		)
	}

	static func run(_ configuration: Configuration) throws {
		let fileManager = FileManager.default
		let iconComposerDirectory = configuration.outputRoot
			.appendingPathComponent("TermsyMac/AppIcon.icon", isDirectory: true)
		let iconComposerAssetsDirectory = iconComposerDirectory
			.appendingPathComponent("Assets", isDirectory: true)
		let iconComposerSourcePNG = iconComposerAssetsDirectory
			.appendingPathComponent(iconComposerImageName)
		let iconComposerJSON = iconComposerDirectory
			.appendingPathComponent("icon.json")

		let appIconSetDirectory = configuration.outputRoot
			.appendingPathComponent("TermsyMac/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
		let appIconSetContentsJSON = appIconSetDirectory
			.appendingPathComponent("Contents.json")

		guard let imageSource = CGImageSourceCreateWithURL(configuration.sourcePNG as CFURL, nil),
		      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
			throw ScriptError.imageReadFailed("Failed to read PNG: \(configuration.sourcePNG.path)")
		}

		let sourceWidth = sourceImage.width
		let sourceHeight = sourceImage.height
		guard sourceWidth == 1024, sourceHeight == 1024 else {
			throw ScriptError.invalidDimensions(width: sourceWidth, height: sourceHeight)
		}

		try fileManager.createDirectory(at: iconComposerAssetsDirectory, withIntermediateDirectories: true, attributes: nil)
		try fileManager.createDirectory(at: appIconSetDirectory, withIntermediateDirectories: true, attributes: nil)

		if !fileManager.fileExists(atPath: iconComposerJSON.path) {
			try iconComposerJSONTemplate.write(to: iconComposerJSON, atomically: true, encoding: .utf8)
		}
		if !fileManager.fileExists(atPath: appIconSetContentsJSON.path) {
			try appIconContentsJSONTemplate.write(to: appIconSetContentsJSON, atomically: true, encoding: .utf8)
		}

		if fileManager.fileExists(atPath: iconComposerSourcePNG.path) {
			try fileManager.removeItem(at: iconComposerSourcePNG)
		}
		try fileManager.copyItem(at: configuration.sourcePNG, to: iconComposerSourcePNG)

		let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
		for variant in legacyVariants {
			try renderLegacyVariant(
				sourceImage: sourceImage,
				size: variant.size,
				insetScale: configuration.legacyInsetScale,
				colorSpace: colorSpace,
				outputURL: appIconSetDirectory.appendingPathComponent(variant.filename)
			)
		}

		let insetString = String(format: "%.2f", Double(configuration.legacyInsetScale))
		print("Updated macOS icon sources.")
		print("  Source PNG: \(configuration.sourcePNG.path)")
		print("  Output root: \(configuration.outputRoot.path)")
		print("  Tahoe/Icon Composer source: \(iconComposerSourcePNG.path)")
		print("  Legacy fallback inset: \(insetString)")
		print("  Legacy AppIcon set: \(appIconSetDirectory.path)")
	}

	private static func renderLegacyVariant(
		sourceImage: CGImage,
		size: Int,
		insetScale: CGFloat,
		colorSpace: CGColorSpace,
		outputURL: URL
	) throws {
		guard let context = CGContext(
			data: nil,
			width: size,
			height: size,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			throw ScriptError.contextCreationFailed(size: size)
		}

		context.interpolationQuality = .high
		context.clear(CGRect(x: 0, y: 0, width: size, height: size))

		let target = CGFloat(size) * insetScale
		let rect = CGRect(
			x: (CGFloat(size) - target) / 2,
			y: (CGFloat(size) - target) / 2,
			width: target,
			height: target
		)
		context.draw(sourceImage, in: rect)

		guard let outputImage = context.makeImage() else {
			throw ScriptError.contextCreationFailed(size: size)
		}
		let bitmap = NSBitmapImageRep(cgImage: outputImage)
		guard let data = bitmap.representation(using: .png, properties: [:]) else {
			throw ScriptError.contextCreationFailed(size: size)
		}
		try data.write(to: outputURL)
	}
}

do {
	let configuration = try UpdateMacOSAppIconScript.parseArguments(CommandLine.arguments)
	try UpdateMacOSAppIconScript.run(configuration)
} catch {
	fputs("error: \(error.localizedDescription)\n", stderr)
	exit(1)
}
