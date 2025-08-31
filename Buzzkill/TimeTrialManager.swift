//
//  TimeTrialManager.swift
//  Buzzkill
//
//  Manager class for the Time Trial lifecycle.
//

import AppKit
import Combine
import Foundation

@MainActor
final class TimeTrialManager: ObservableObject {
  enum State: Equatable {
    case idle
    case countingDown(start: Date)
    case running(start: Date)
  }

  @Published private(set) var state: State = .idle

  // TODO: Migrate `FlyManager` calls to events.
  private weak var flyManager: FlyManager?
  private var activeInitialCount: Int?
  private var countdownTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  func setup(flyManager: FlyManager) {
    self.flyManager = flyManager
    observeNotifications()
  }

  // MARK: - Notification Handling

  private func observeNotifications() {
    Events.startTimeTrial
      .sink { [weak self] initial in
        self?.start(initialCount: initial)
      }
      .store(in: &cancellables)

    Events.stopTimeTrial
      .sink { [weak self] _ in
        self?.abort()
      }
      .store(in: &cancellables)

    Events.applySpawnSettings
      .sink { [weak self] spawn in
        guard let self else {
          return
        }
        guard case .idle = self.state else {
          if spawn.mode != .none {
            Events.stopTimeTrial.send(())
          }
          return
        }
      }
      .store(in: &cancellables)

    Events.allFliesCleared
      .sink { [weak self] _ in
        self?.onAllFliesCleared()
      }
      .store(in: &cancellables)
  }

  // MARK: - Time Trial Lifecycle

  func start(initialCount: Int) {
    guard case .idle = state else {
      return
    }
    guard let flyManager = flyManager else {
      return
    }

    // Reset environment.
    Events.killAllFlies.send(false)
    activeInitialCount = initialCount

    // Force spawn mode to None (to avoid weird states when the time trial ends).
    var updated = AppSettings.shared.spawn
    updated.mode = .none
    AppSettings.shared.spawn = updated
    flyManager.applySpawnSettings(mode: .none, initialCount: 0, maxCount: 0, interval: 0)

    // 3-2-1-Go countdown before timing starts.
    // The timer begins right when "Go!" appears.
    state = .countingDown(start: Date())
    countdownTask?.cancel()
    countdownTask = Task { @MainActor in
      do {
        for i in (1...3).reversed() {
          Events.timeTrialCountingDown.send(i)
          try await Task.sleep(nanoseconds: 1_000_000_000)
          guard !Task.isCancelled, case .countingDown = state else {
            return
          }
        }

        let startTime = Date()
        state = .running(start: startTime)
        Events.timeTrialCountingDown.send(0)
        Events.timeTrialStarted.send(startTime)
        flyManager.spawnInitial(count: initialCount)
      } catch {
        return
      }
    }
  }

  func abort() {
    switch state {
    case .running, .countingDown:
      break
    default:
      return
    }

    // Cancel any pending countdown task.
    countdownTask?.cancel()
    countdownTask = nil

    // Reset environment.
    Events.killAllFlies.send(false)
    Events.timeTrialAborted.send(())
    activeInitialCount = nil
    state = .idle
  }

  func onAllFliesCleared() {
    guard case let .running(start) = state else {
      return
    }
    let elapsed = Date().timeIntervalSince(start)

    // Update per-initial-count records.
    var timeTrial = AppSettings.shared.timeTrial
    let key = activeInitialCount ?? timeTrial.initialCount
    var recordForFlyCount = timeTrial.recordsByInitialCount[key] ?? .init(last: nil, pr: nil)
    recordForFlyCount.last = elapsed
    if let existingPR = recordForFlyCount.pr {
      recordForFlyCount.pr = min(existingPR, elapsed)
    } else {
      recordForFlyCount.pr = elapsed
    }
    timeTrial.recordsByInitialCount[key] = recordForFlyCount
    AppSettings.shared.timeTrial = timeTrial

    // Reset environment.
    state = .idle
    activeInitialCount = nil
    Events.timeTrialCompleted.send(elapsed)
  }
}
