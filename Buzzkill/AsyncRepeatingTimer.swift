//
//  AsyncRepeatingTimer.swift
//  Buzzkill
//
//  A Swift Concurrency equivalent to a repeating `Timer`.
//

import Foundation

/// A Swift Concurrency equivalent to a repeating `Timer`.
/// Runs on the actor you call `start` from (defaults to `@MainActor`).
final class AsyncRepeatingTimer {
  private var task: Task<Void, Never>?
  private let interval: Duration
  private let action: @Sendable () async -> Void

  init(interval: Duration, action: @escaping @Sendable () async -> Void) {
    self.interval = interval
    self.action = action
  }

  /// Starts the timer. Cancels any existing task.
  func start() {
    invalidate()
    task = Task {
      while !Task.isCancelled {
        await action()
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// Cancels the timer.
  func invalidate() {
    task?.cancel()
    task = nil
  }

  deinit {
    invalidate()
  }
}
