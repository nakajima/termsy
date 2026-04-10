import SwiftUI

#if canImport(UIKit)
	import UIKit

	typealias PlatformColor = UIColor
#elseif canImport(AppKit)
	import AppKit

	typealias PlatformColor = NSColor
#endif

extension PlatformColor {
	convenience init(hex: String) {
		var rgb: UInt64 = 0
		Scanner(string: hex).scanHexInt64(&rgb)
		let red = CGFloat((rgb >> 16) & 0xFF) / 255
		let green = CGFloat((rgb >> 8) & 0xFF) / 255
		let blue = CGFloat(rgb & 0xFF) / 255
		#if canImport(UIKit)
			self.init(red: red, green: green, blue: blue, alpha: 1)
		#elseif canImport(AppKit)
			self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
		#endif
	}
}
