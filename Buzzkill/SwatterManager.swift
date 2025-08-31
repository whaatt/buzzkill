//
//  SwatterManager.swift
//  Buzzkill
//
//  Manager class for the logical swatter state and its geometry.
//

import AppKit
import Foundation
import SwiftUI

struct AnimatedConeState: Equatable {
  var cone: SwatCone
  var rotationAngle: Angle = .zero
  var opacity: Double = 1.0
  var stretch: CGFloat = 0.0
  var stretchIntensity: CGFloat = 0.0
}

// MARK: - Swatter Manager

@MainActor
final class SwatterManager: ObservableObject {
  // Constants.
  private let maxRadius: CGFloat = 200.0
  private let minRadius: CGFloat = 200.0
  private let radiusDistanceScale: CGFloat = 0.9
  /// Total angular width of the threat cone (in radians).
  private let arcAngle: CGFloat = CGFloat.pi / 3  // ≈ 45°.
  private let baseSwatDuration: Double = 0.4
  private let fadeOutDuration: Double = 0.2
  // TODO: Maybe track this as a fly suspicion property?
  private let recentSwatHalfLife: TimeInterval = 10.0  // Swat count halves every 10 seconds.
  private let maxRecentSwatsToConsider = 10

  // Drag state.
  @Published var isDragging: Bool = false
  @Published var stretch: CGFloat = 0.0
  @Published var stretchIntensity: CGFloat = 0.0
  var swatOrigin: CGPoint = CGPoint.zero
  var swatCurrent: CGPoint = CGPoint.zero
  var swatRadius: CGFloat = 0.0
  private(set) var recentSwatCount: Double = 0.0
  private var lastSwatTime: Date?
  private(set) var swatReleaseTime: Date?

  // Animation state.
  @Published var isVisible: Bool = false
  @Published var animatedConeState: AnimatedConeState?

  // Reference to the fly manager so we can swat flies.
  private weak var flyManager: FlyManager?

  /// The cone that flies should be scared of *after* the drag has ended.
  private var finalStrikeConeSaved: SwatCone?

  /// The vector being dragged (`current - origin`). This is updated continuously while dragging
  /// and frozen when the drag ends so that the strike animation can reference the final vector.
  private var dragVector: CGVector = .zero

  /// Returns the cone representing the *current* drag state (or `nil` if not dragging).
  var draggedCone: SwatCone? {
    guard isDragging else {
      return nil
    }
    let distance = hypot(dragVector.dx, dragVector.dy)
    guard distance > 1.0 else {
      return nil
    }

    let direction = CGVector(dx: dragVector.dx / distance, dy: dragVector.dy / distance)
    return SwatCone(
      origin: swatOrigin,
      direction: direction,
      radius: swatRadius,
      arcAngle: arcAngle,
      stretch: 1.0 + stretch
    )
  }

  /// The invisible, mirrored cone used for building suspicion in flies while dragging.
  var mirroredThreatCone: SwatCone? {
    guard let cone = draggedCone else {
      return nil
    }

    // Flip the direction to target flies on the opposite side of the origin.
    let mirroredDirection = CGVector(dx: -cone.direction.dx, dy: -cone.direction.dy)
    return SwatCone(
      origin: cone.origin,
      direction: mirroredDirection,
      radius: cone.radius,
      arcAngle: cone.arcAngle,
      stretch: cone.stretch
    )
  }

  /// The single source of truth for the cone that flies should be scared of.
  var activeThreatCone: SwatCone? {
    // While dragging, the threat is the invisible mirrored cone.
    if isDragging {
      return mirroredThreatCone
    }
    // After dragging, the threat is the cone being animated on the mirrored side.
    return finalStrikeConeSaved
  }

  /// Returns the cone used for the *strike* phase. This is a mirrored copy of the cone displayed
  /// while dragging, positioned at `origin + dragVector` so it lunges forward.
  func finalStrikeCone() -> SwatCone? {
    let distance = hypot(dragVector.dx, dragVector.dy)
    guard distance > 1.0 else {
      return nil
    }

    let direction = CGVector(dx: dragVector.dx / distance, dy: dragVector.dy / distance)
    let forwardOrigin = CGPoint(x: swatOrigin.x + dragVector.dx, y: swatOrigin.y + dragVector.dy)
    return SwatCone(
      origin: forwardOrigin,
      direction: direction,
      radius: swatRadius,
      arcAngle: arcAngle,
      stretch: 1.0 + stretch
    )
  }

  // MARK: - Public Interface

  func setFlyManager(_ manager: FlyManager) {
    flyManager = manager
  }

  func setVisibility(to visible: Bool) {
    isVisible = visible
    if let window = NSApp.windows.first(where: {
      $0.identifier == BuzzkillApp.Constants.overlayWindowIdentifier
    }) {
      window.ignoresMouseEvents = !visible
    }

    if !visible {
      endSwatDrag()
    }
  }

  func startSwatDrag(at position: CGPoint) {
    guard isVisible else {
      return
    }

    isDragging = true
    swatOrigin = position
    swatCurrent = position
    swatRadius = minRadius
    stretch = 0.0
    stretchIntensity = 0.0
    animatedConeState = nil
    swatReleaseTime = nil
    decayRecentSwats()
  }

  func updateSwatDrag(to position: CGPoint) {
    guard isDragging else {
      return
    }
    swatCurrent = position

    // Update cached drag vector.
    dragVector = CGVector(dx: position.x - swatOrigin.x, dy: position.y - swatOrigin.y)

    // Calculate radius based on distance from origin.
    let distance = sqrt(pow(position.x - swatOrigin.x, 2) + pow(position.y - swatOrigin.y, 2))
    // Use a power function for sub-linear scaling, creating resistance without a hard cap.
    let unclampedRadius = minRadius + pow(distance, radiusDistanceScale)
    swatRadius = max(minRadius, min(maxRadius, unclampedRadius))

    // Calculate stretch amount based on how far past the max radius we've dragged.
    stretch = max(0, unclampedRadius - maxRadius)

    // Use `atan` to smoothly map the unbounded stretch value to a 0-1 range.
    let stretchScale: CGFloat = 150.0  // Controls how quickly intensity ramps up.
    stretchIntensity = (2.0 / .pi) * atan(stretch / stretchScale)
  }

  func endSwatDrag() {
    guard isDragging else {
      return
    }

    // Capture all geometry needed *before* changing any state.
    guard let finalAnimatedCone = draggedCone,
      let finalStrikeCone = mirroredThreatCone
    else {
      isDragging = false
      return
    }

    // Change drag state.
    isDragging = false

    // Set the initial state for the animation. The cone starts by pointing along
    // the drag direction. The rotation will flip it to the opposite side.
    animatedConeState = AnimatedConeState(
      cone: finalAnimatedCone,
      rotationAngle: .zero,
      opacity: 1.0,
      stretch: stretch,
      stretchIntensity: stretchIntensity
    )

    // The threat cone during animation is the final strike cone.
    finalStrikeConeSaved = finalStrikeCone

    // The more we've stretched, the faster the swat.
    let swatDuration = baseSwatDuration / (1.0 + stretchIntensity)

    // Trigger the swat a fraction of a second before the animation completes.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64((swatDuration * 0.35) * 1_000_000_000))
      flyManager?.swatFlies(in: finalStrikeCone)
      incrementRecentSwats()
    }

    // Animate the swat with a single bouncy animation.
    withAnimation(.bouncy(duration: swatDuration)) {
      animatedConeState?.rotationAngle = .degrees(180)
      animatedConeState?.stretch = 0.0
    } completion: {
      // Ensure the animation wasn't cancelled in the meantime by the user starting a new drag.
      guard var finalState = self.animatedConeState, finalState.rotationAngle.degrees == 180 else {
        return
      }

      // Fade the cone out.
      withAnimation(.easeOut(duration: self.fadeOutDuration)) {
        finalState.opacity = 0.0
        self.animatedConeState = finalState
      } completion: {
        // Clean up animation state after the fade-out is complete.
        self.animatedConeState = nil
        self.finalStrikeConeSaved = nil
      }
    }
  }

  private func decayRecentSwats() {
    guard let lastSwat = lastSwatTime else {
      return
    }
    let timeSinceLastSwat = Date().timeIntervalSince(lastSwat)

    // Exponential decay based on a half-life.
    let lambda = log(2.0) / recentSwatHalfLife
    let decayFactor = exp(-lambda * timeSinceLastSwat)
    recentSwatCount *= decayFactor

    // If it's very small, just reset to 0 to prevent it from lingering.
    if recentSwatCount < 0.01 {
      recentSwatCount = 0
    }
  }

  private func incrementRecentSwats() {
    // Before incrementing, decay the current value to the present time.
    decayRecentSwats()
    recentSwatCount = min(Double(maxRecentSwatsToConsider), recentSwatCount + 1)
    let now = Date()
    lastSwatTime = now
    swatReleaseTime = now
  }
}
