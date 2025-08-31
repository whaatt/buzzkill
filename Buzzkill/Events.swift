//
//  Events.swift
//  Buzzkill
//
//  Strongly-typed app-wide event subjects.
//

import AppKit
import Combine
import Foundation

enum Events {
  // Settings application events.
  static let applySpawnSettings = PassthroughSubject<AppSettings.SpawnSettings, Never>()

  // Time Trial lifecycle events.
  static let startTimeTrial = PassthroughSubject<Int, Never>()
  static let stopTimeTrial = PassthroughSubject<Void, Never>()
  static let timeTrialStarted = PassthroughSubject<Date, Never>()
  static let timeTrialCountingDown = PassthroughSubject<Int, Never>()
  static let timeTrialCompleted = PassthroughSubject<Double, Never>()
  static let timeTrialAborted = PassthroughSubject<Void, Never>()

  // Fly manager events.
  static let killAllFlies = PassthroughSubject<Bool, Never>()
  static let allFliesCleared = PassthroughSubject<Void, Never>()

  // Swatter interaction events (in view-local coordinates).
  static let startSwatDrag = PassthroughSubject<CGPoint, Never>()
  static let updateSwatDrag = PassthroughSubject<CGPoint, Never>()
  static let endSwatDrag = PassthroughSubject<CGPoint, Never>()

  // Other keyboard shortcut events.
  static let toggleStatusPanel = PassthroughSubject<Void, Never>()

  // OAuth and local server events.
  static let requestOpenRouterOAuth = PassthroughSubject<Void, Never>()
  static let localOAuthServerRequestedStop = PassthroughSubject<Void, Never>()
  static let localOAuthServerReceivedQuery = PassthroughSubject<[String: String], Never>()

  // Roast event (`nil` to clear latest roast).
  static let showRoast = PassthroughSubject<String?, Never>()
}
