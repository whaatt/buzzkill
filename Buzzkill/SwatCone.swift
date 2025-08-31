///
//  SwatCone.swift
//  Buzzkill
//
//  Geometric representation of a swat cone.
//

import AppKit
import Foundation

/// Represents the geometric strike or threat zone for a swat action.
/// A cone is defined by an `origin` (vertex), a unit‐length `direction` vector pointing along
/// the center of the cone, a `radius` (maximum reach) and an `arcAngle` in **radians** for the
/// total width of the cone (i.e. an `arcAngle` of π/3 spans 60° total, ±30° from the center
/// line).
struct SwatCone: Equatable {
  /// The vertex of the cone (usually the swat anchor point).
  let origin: CGPoint
  /// A **normalized** vector indicating the center‐line direction of the cone.
  let direction: CGVector
  /// Maximum reach of the cone measured from the origin, in points.
  let radius: CGFloat
  /// Total angular width of the cone in **radians**.
  let arcAngle: CGFloat
  /// The amount of "stretch" applied to the cone, where 1.0 is no stretch.
  let stretch: CGFloat

  /// Returns `true` if the provided point lies within the bounds of the cone.
  func contains(point: CGPoint) -> Bool {
    // Vector from origin to the point.
    let v = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
    let distance = hypot(v.dx, v.dy)
    guard distance <= radius && distance > 0.0 else {
      // Either too far away or exactly at origin.
      return distance == 0.0 ? true : false
    }

    // Normalize `v` for angle comparison.
    let vNorm = CGVector(dx: v.dx / distance, dy: v.dy / distance)
    // Dot product gives `cos(theta)` where `theta` is the angle between vectors.
    let cosTheta = vNorm.dx * direction.dx + vNorm.dy * direction.dy
    // Prevent floating‐point domain errors.
    let clamped = max(min(cosTheta, 1.0), -1.0)
    let theta = acos(clamped)
    return theta <= arcAngle / 2.0
  }
}
