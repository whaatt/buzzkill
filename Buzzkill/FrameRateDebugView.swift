//
//  FrameRateDebugView.swift
//  Buzzkill
//
//  Debug view for FPS.
//

import AppKit
import SwiftUI

struct FrameRateDebugView: View {
  @StateObject private var frameRateModel: FrameRateModel

  init(smoothingFactor: Double = 0.1) {
    _frameRateModel = StateObject(wrappedValue: FrameRateModel(smoothingFactor: smoothingFactor))
  }

  var body: some View {
    Text("FPS: \(Int(frameRateModel.framesPerSecondSmoothed.rounded()))")
      .font(.system(size: 12, weight: .semibold, design: .monospaced))
      .foregroundColor(.white)
      .shadow(color: .black.opacity(0.8), radius: 4)
      .padding(8)
      .background(Color.black.opacity(0.25))
      .cornerRadius(6)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onAppear { frameRateModel.start() }
      .onDisappear { frameRateModel.stop() }
  }
}

final class FrameRateModel: ObservableObject {
  @Published var framesPerSecondSmoothed: Double = 0

  private let smoothingFactor: Double
  private var displayLink: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0

  init(smoothingFactor: Double = 0.1) {
    self.smoothingFactor = smoothingFactor
  }

  func start() {
    stop()
    guard
      let window = NSApp.windows.first(where: {
        $0.identifier == BuzzkillApp.Constants.overlayWindowIdentifier
      })
    else {
      return
    }

    displayLink = window.displayLink(target: self, selector: #selector(tick(_:)))
    displayLink?.add(to: .main, forMode: .common)
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    framesPerSecondSmoothed = 0
    lastTimestamp = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    if lastTimestamp == 0 {
      lastTimestamp = link.timestamp
      return
    }

    let deltaSeconds = link.timestamp - lastTimestamp
    let frameRateInstantaneous = 1.0 / deltaSeconds
    framesPerSecondSmoothed =
      framesPerSecondSmoothed * smoothingFactor + frameRateInstantaneous * (1.0 - smoothingFactor)
    lastTimestamp = link.timestamp
  }
}
