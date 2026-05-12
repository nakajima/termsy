#if canImport(UIKit)
//
//  TerminalScrollPhysics.swift
//  Termsy
//
//  Pure state + math for terminal scroll behavior: momentum decay,
//  smooth-scroll target/presentation animation, and the suppression
//  flag that hides the smooth-scroll offset when remote output arrives.
//  No UI, no ghostty, no rendering — the host TerminalView reads
//  presentationOffsetY, calls the methods below, and acts on the result.
//

import CoreGraphics
import Foundation

@MainActor
final class TerminalScrollPhysics {
	enum MomentumTickResult {
		case idle
		case delta(CGPoint, TerminalScrollSettings.InputKind)
		case ended(TerminalScrollSettings.InputKind)
	}

	private(set) var momentumInputKind: TerminalScrollSettings.InputKind?
	private(set) var presentationOffsetY: CGFloat = 0

	private var momentumVelocity = CGPoint.zero
	private var accumulatedOffsetY: CGFloat = 0
	private var targetOffsetY: CGFloat = 0
	private var isSuppressedUntilNextGesture = false

	private let momentumVelocityThreshold: CGFloat = 50
	private let momentumDecelerationPerFrame: CGFloat = 0.92
	private let smoothScrollAnimationSpeed: CGFloat = 18

	func suppressUntilNextGesture() {
		isSuppressedUntilNextGesture = true
	}

	func clearSuppression() {
		isSuppressedUntilNextGesture = false
	}

	func noteScrollAccumulation(delta: CGPoint, cellHeight: CGFloat) {
		guard !isSuppressedUntilNextGesture else { return }
		guard cellHeight > 0 else { return }
		accumulatedOffsetY -= delta.y
		targetOffsetY = Self.wrappedOffset(for: accumulatedOffsetY, cellHeight: cellHeight)
	}

	/// Starts a momentum run. Returns false if velocity is below threshold —
	/// caller should skip the wheel-began event and release smooth-scroll state.
	func beginMomentum(velocity: CGPoint, inputKind: TerminalScrollSettings.InputKind) -> Bool {
		guard
			abs(velocity.x) > momentumVelocityThreshold
				|| abs(velocity.y) > momentumVelocityThreshold
		else {
			releaseSmoothScroll()
			return false
		}
		momentumVelocity = velocity
		momentumInputKind = inputKind
		return true
	}

	func advanceMomentum(deltaTime: CGFloat) -> MomentumTickResult {
		guard let inputKind = momentumInputKind else { return .idle }

		let frameScale = max(deltaTime * 60, 0)
		let deceleration = CGFloat(pow(Double(momentumDecelerationPerFrame), Double(frameScale)))
		momentumVelocity.x *= deceleration
		momentumVelocity.y *= deceleration

		if
			abs(momentumVelocity.x) < momentumVelocityThreshold,
			abs(momentumVelocity.y) < momentumVelocityThreshold
		{
			momentumVelocity = .zero
			momentumInputKind = nil
			releaseSmoothScroll()
			return .ended(inputKind)
		}

		return .delta(
			CGPoint(x: momentumVelocity.x * deltaTime, y: momentumVelocity.y * deltaTime),
			inputKind
		)
	}

	func advanceSmoothScrollPresentation(deltaTime: CGFloat) {
		let alpha = min(1, deltaTime * smoothScrollAnimationSpeed)
		presentationOffsetY += (targetOffsetY - presentationOffsetY) * alpha
		if abs(presentationOffsetY - targetOffsetY) < 0.1 {
			presentationOffsetY = targetOffsetY
		}
	}

	/// Clears accumulator and target, but leaves presentationOffsetY to animate down.
	func releaseSmoothScroll() {
		accumulatedOffsetY = 0
		targetOffsetY = 0
	}

	/// Zeros everything immediately — used when remote output arrives or display stops.
	func snapPresentationToTerminal() {
		accumulatedOffsetY = 0
		targetOffsetY = 0
		presentationOffsetY = 0
	}

	/// Stops momentum + snaps smooth scroll. Returns the input kind of any
	/// active momentum so the caller can send a final wheel-stop event to ghostty.
	@discardableResult
	func cancelForInteraction() -> TerminalScrollSettings.InputKind? {
		let endedKind = momentumInputKind
		momentumVelocity = .zero
		momentumInputKind = nil
		snapPresentationToTerminal()
		return endedKind
	}

	private static func wrappedOffset(for value: CGFloat, cellHeight: CGFloat) -> CGFloat {
		guard cellHeight > 0 else { return 0 }
		var remainder = value.truncatingRemainder(dividingBy: cellHeight)
		let halfCellHeight = cellHeight / 2
		if remainder > halfCellHeight {
			remainder -= cellHeight
		} else if remainder < -halfCellHeight {
			remainder += cellHeight
		}
		return remainder
	}
}
#endif
