//
//  InputManager.swift
//  Buzzkill
//
//  Small wrapper around shortcut monitors to track swatter activation state and toggle the status
//  panel on double-tap.
//

import AppKit
import CoreGraphics
import Foundation
import KeyboardShortcuts

@MainActor
final class InputManager: ObservableObject {
  @Published var isActivationPressed = false

  private var originalCursor: NSCursor?
  private var lastActivationKeyUpAt: Date?
  private let doubleTapWindow: TimeInterval = 0.35

  init() {
    // Listen to user-defined shortcut using KeyboardShortcuts.
    KeyboardShortcuts.onKeyDown(for: .swatterActivation) { [weak self] in
      guard let self else {
        return
      }
      self.isActivationPressed = true
      self.setCrosshairCursor()
    }
    KeyboardShortcuts.onKeyUp(for: .swatterActivation) { [weak self] in
      guard let self else {
        return
      }
      self.isActivationPressed = false
      self.restoreOriginalCursor()

      // Handle double-tap to toggle status panel.
      let now = Date()
      if let last = self.lastActivationKeyUpAt, now.timeIntervalSince(last) <= self.doubleTapWindow
      {
        Events.toggleStatusPanel.send(())
        self.lastActivationKeyUpAt = nil
      } else {
        self.lastActivationKeyUpAt = now
      }
    }
  }

  private func setCrosshairCursor() {
    originalCursor = NSCursor.current
    NSCursor.crosshair.set()
  }

  private func restoreOriginalCursor() {
    (originalCursor ?? NSCursor.arrow).set()
    originalCursor = nil
  }
}
