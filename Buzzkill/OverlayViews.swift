//
//  OverlayViews.swift
//  Buzzkill
//
//  Core views for the swat field overlay.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Fly View

struct FlyView: View {
  @ObservedObject var fly: Fly
  @State private var randomPastel: Color =
    Color(
      hue: [
        .random(in: 0.1...0.2),
        .random(in: 0.45...0.55),
        .random(in: 0.75...0.85),
      ].randomElement()!,
      saturation: 1.0,
      brightness: 1.0
    )

  var body: some View {
    let spriteImage: NSImage = FlySprite.shared.getFlySprite(frame: fly.wingFrame)

    Group {
      // Draw goop splatter particles.
      Canvas { context, size in
        // A blur creates a metaball-like effect.
        context.addFilter(.blur(radius: 10))
        for particle in fly.goopParticles {
          let rect = CGRect(
            x: particle.position.x - particle.size / 2.0,
            y: particle.position.y - particle.size / 2.0,
            width: particle.size,
            height: particle.size)
          context.fill(
            Ellipse().path(in: rect),
            with: .color(randomPastel)
          )
        }
      }
      .drawingGroup()
      .opacity(fly.goopOpacity)
      .blendMode(.difference)

      if fly.isAlive {
        let scale: CGFloat = 2.0
        ZStack(alignment: .topTrailing) {
          // Adaptive shadow for visibility on all backgrounds.
          ZStack {
            // Dark shadow for light backgrounds.
            Image(nsImage: spriteImage)
              .interpolation(.none)
              .scaleEffect(x: fly.facingRight ? scale : -scale, y: scale)
              .blur(radius: 3)
              .offset(x: -1, y: -1)
              .opacity(0.6)

            // Light "glow" shadow for dark backgrounds.
            Image(nsImage: spriteImage)
              .interpolation(.none)
              .scaleEffect(x: fly.facingRight ? scale : -scale, y: scale)
              .blur(radius: 3)
              .offset(x: -1, y: -1)
              .blendMode(.screen)
              .opacity(0.6)
          }

          // Main fly sprite with high saturation.
          // Tint the sprite based on suspicion level.
          let suspicion = fly.suspicionLevel
          let tintColor = Color(
            red: 1.0,
            green: 1.0 - suspicion,
            blue: 1.0 - suspicion
          )
          Image(nsImage: spriteImage)
            .interpolation(.none)
            .scaleEffect(x: fly.facingRight ? scale : -scale, y: scale)
            .saturation(1.8 + suspicion * 1.5)
            .colorMultiply(tintColor)

          // Display suspicion level for debugging.
          // Text(String(format: "%.0f%%", fly.suspicionLevel * 100))
          //   .font(.system(size: 15, weight: .bold))
          //   .foregroundColor(.white)
          //   .shadow(color: .black, radius: 1)
          //   .offset(y: 20)
        }
        .frame(width: spriteImage.size.width * scale, height: spriteImage.size.height * scale)
        .position(fly.position)
        .animation(.none, value: fly.rotation)

        if let roast = fly.roastText {
          let anchor = CGPoint(
            x: fly.position.x,
            y: fly.position.y - (spriteImage.size.height * scale) / 2.0
          )
          AnchoredRoastBubble(text: roast, anchor: anchor)
            .transition(.opacity)
        }
      }
    }
  }
}

// MARK: - Swatter View

struct SwatterView: View {
  @ObservedObject var swatterManager: SwatterManager
  @State private var gradientStartTime: TimeInterval?

  var body: some View {
    if swatterManager.isDragging {
      // While dragging, we create a temporary cone state with 0 rotation.
      guard let draggedCone = swatterManager.draggedCone else {
        return AnyView(EmptyView())
      }
      let coneState = AnimatedConeState(
        cone: draggedCone,
        rotationAngle: .zero,
        opacity: 1.0,
        stretch: swatterManager.stretch,
        stretchIntensity: swatterManager.stretchIntensity
      )
      return AnyView(
        buildSwatterBody(coneState: coneState)
          .position(coneState.cone.origin)
      )
    } else if let coneState = swatterManager.animatedConeState {
      // When animating, we use the dedicated state object from the manager.
      return AnyView(
        buildSwatterBody(coneState: coneState)
          .position(coneState.cone.origin)
      )
    } else {
      return AnyView(EmptyView())
    }
  }

  @ViewBuilder
  private func buildSwatterBody(coneState: AnimatedConeState) -> some View {
    let rotationAxis = (
      x: -coneState.cone.direction.dy, y: coneState.cone.direction.dx, z: CGFloat(0.0)
    )
    let stretchIntensity = coneState.stretchIntensity
    let isBackside = coneState.rotationAngle.degrees > 90

    // Make the fill transparent when the swatter is on its backside.
    let fillOpacity = isBackside ? 0.0 : 0.2
    let fillColor = Color(
      red: 1.0,
      green: 1.0 - (0.8 * stretchIntensity),
      blue: 1.0 - (0.8 * stretchIntensity),
      opacity: fillOpacity
    )

    TimelineView(.animation) { timeline in
      // Create a value that ranges from 0.0 to 1.0 over 0.4 seconds.
      let currentTime = timeline.date.timeIntervalSinceReferenceDate
      let pulseWidth: CGFloat = 0.2
      let shimmerBuffer = pulseWidth / 2
      let shimmerStart =
        min(
          1.0,
          max(0.0, (currentTime - (gradientStartTime ?? currentTime)) / 0.4)
        ) - pulseWidth
      let shimmerEnd = shimmerStart + pulseWidth

      // A gradient that pulses along the cone's radial axis.
      let backsideGradient = LinearGradient(
        gradient: Gradient(stops: [
          .init(color: Color.black, location: 0.0),
          .init(
            color: Color.black,
            location: max(0.0, shimmerStart - shimmerBuffer)
          ),
          .init(
            color: Color.white,
            location: max(0.0, shimmerStart)
          ),
          .init(
            color: Color.white,
            location: min(1.0, shimmerEnd)
          ),
          .init(
            color: Color.black,
            location: min(1.0, shimmerEnd + shimmerBuffer)
          ),
          .init(color: Color.black, location: 1.0),
        ]),
        startPoint: .center,
        endPoint: UnitPoint(
          x: 0.5 + coneState.cone.direction.dx,
          y: 0.5 + coneState.cone.direction.dy
        )
      )
      let lineColor: AnyShapeStyle = isBackside ? .init(backsideGradient) : .init(Color.black)

      // We use a ZStack to layer the fill and stroke for the mesh.
      ZStack {
        // The filled-in background of the cone.
        ConeShape(
          direction: coneState.cone.direction,
          radius: coneState.cone.radius,
          arcAngle: coneState.cone.arcAngle,
          stretch: coneState.stretch
        )
        .fill(fillColor)

        // The mesh outline of the cone.
        ConeShape(
          direction: coneState.cone.direction,
          radius: coneState.cone.radius,
          arcAngle: coneState.cone.arcAngle,
          stretch: coneState.stretch
        )
        .stroke(lineColor, lineWidth: 3)
      }
      .frame(width: coneState.cone.radius * 2, height: coneState.cone.radius * 2)
      .contentShape(
        ConeShape(
          direction: coneState.cone.direction,
          radius: coneState.cone.radius,
          arcAngle: coneState.cone.arcAngle,
          stretch: coneState.stretch
        )
      )
      .rotation3DEffect(
        coneState.rotationAngle,
        axis: rotationAxis,
        anchor: .center
      )
      .opacity(coneState.opacity)
    }
    .onChange(
      of: isBackside,
      { _, newIsBackside in
        if newIsBackside && gradientStartTime == nil {
          gradientStartTime = Date().timeIntervalSinceReferenceDate
        }
      })
  }
}

// MARK: - ConeShape

struct ConeShape: Shape {
  let direction: CGVector
  var radius: CGFloat
  let arcAngle: CGFloat
  var stretch: CGFloat = 0.0

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get {
      AnimatablePair(radius, stretch)
    }

    set {
      radius = CGFloat(newValue.first)
      stretch = CGFloat(newValue.second)
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()

    let center = CGPoint(x: rect.midX, y: rect.midY)
    let centerAngle = atan2(direction.dy, direction.dx)
    let halfAngle = arcAngle / 2.0
    let startAngle = centerAngle - halfAngle
    let arcResolution = 20  // Number of segments to approximate the curve.

    // Helper to calculate the position of a point on the stretched cone.
    func getStretchedPoint(angle: CGFloat, forRadius: CGFloat) -> CGPoint {
      // Calculate how far along the arc the current angle is (0.0 to 1.0).
      let normalizedPositionInArc = (angle - startAngle) / arcAngle
      // Use a sine curve to make the stretch factor 0 at the edges and 1 in the middle.
      let stretchFactor = sin(normalizedPositionInArc * .pi)
      // Apply the stretch to the radius.
      let stretchedRadius = forRadius + stretch * stretchFactor

      return CGPoint(
        x: center.x + stretchedRadius * cos(angle),
        y: center.y + stretchedRadius * sin(angle)
      )
    }

    // Draw the main cone shape by plotting the outer boundary.
    path.move(to: center)
    for i in 0...arcResolution {
      let ratio = CGFloat(i) / CGFloat(arcResolution)
      let angle = startAngle + arcAngle * ratio
      path.addLine(to: getStretchedPoint(angle: angle, forRadius: radius))
    }
    path.closeSubpath()

    // Draw concentric arcs for the mesh.
    let numArcs = 8
    for i in 1..<numArcs {
      let arcRadius = radius * (CGFloat(i) / CGFloat(numArcs))

      // Move to the start of the inner arc.
      path.move(to: getStretchedPoint(angle: startAngle, forRadius: arcRadius))

      // Plot the inner arc.
      for j in 1...arcResolution {
        let ratio = CGFloat(j) / CGFloat(arcResolution)
        let angle = startAngle + arcAngle * ratio
        path.addLine(to: getStretchedPoint(angle: angle, forRadius: arcRadius))
      }
    }

    // Draw radial lines for the mesh.
    let numLines = 5
    if numLines > 1 {
      for i in 1..<numLines {
        let ratio = CGFloat(i) / CGFloat(numLines)
        let angle = startAngle + arcAngle * ratio

        path.move(to: center)
        path.addLine(to: getStretchedPoint(angle: angle, forRadius: radius))
      }
    }

    // Path now consists of cone and mesh.
    return path
  }
}

// MARK: - Roast Bubble Views

struct SpeechBubbleShape: Shape {
  var cornerRadius: CGFloat = 10
  var tailSize: CGSize = CGSize(width: 14, height: 10)
  var tailOffset: CGFloat = 24

  func path(in rectBase: CGRect) -> Path {
    var rect = rectBase
    rect.size.height -= tailSize.height
    var path = Path(roundedRect: rect, cornerRadius: cornerRadius)

    let tailBaseY = rect.maxY
    let tip = CGPoint(
      x: rect.minX + tailOffset + tailSize.width / 2,
      y: tailBaseY + tailSize.height
    )
    let left = CGPoint(x: rect.minX + tailOffset, y: tailBaseY)
    let right = CGPoint(x: rect.minX + tailOffset + tailSize.width, y: tailBaseY)
    path.move(to: left)
    path.addLine(to: tip)
    path.addLine(to: right)
    path.closeSubpath()
    return path
  }
}

extension String {
  func widthUsingFont(_ nsFont: NSFont? = nil) -> CGFloat {
    let nsFont = nsFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let container = AttributeContainer([.font: nsFont])
    let attributedString = AttributedString(self, attributes: container)
    let nsAttributedString = NSAttributedString(attributedString)
    let size = nsAttributedString.size()
    return size.width
  }
}

private struct RoastBubble: View {
  let text: String

  // Hack to force hugging of text by its parent until we reach a width cap.
  @State private var naturalTextWidth: CGFloat = 250

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(.custom("Tahoma", size: 14))
        .foregroundColor(.primary)
        .onAppear {
          naturalTextWidth = text.widthUsingFont(NSFont(name: "Tahoma", size: 14))
        }
        .onChange(of: text) { _, _ in
          naturalTextWidth = text.widthUsingFont(NSFont(name: "Tahoma", size: 14))
        }
    }
    .frame(
      width: min(max(naturalTextWidth, 35), 250),
      alignment: .leading
    )
    .padding(.all, 12)
    // Account for tail height.
    .padding(.bottom, 10)
    .background(
      SpeechBubbleShape()
        .fill(Color(red: 252.0 / 255.0, green: 250.0 / 255.0, blue: 207.0 / 255.0))
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
    )
  }
}

// Positions a `RoastBubble`` so that its tail tip aligns with a given anchor point.
private struct AnchoredRoastBubble: View {
  let text: String
  let anchor: CGPoint

  // Keep these in sync with the `RoastBubble` background shape.
  private let tailSize: CGSize = CGSize(width: 14, height: 10)
  private let tailOffset: CGFloat = 24

  @State private var bubbleSize: CGSize = .zero

  var body: some View {
    RoastBubble(text: text)
      .background(
        GeometryReader { proxy in
          Color.clear
            .preference(key: BubbleSizePreferenceKey.self, value: proxy.size)
        }
      )
      .onPreferenceChange(BubbleSizePreferenceKey.self) { newSize in
        bubbleSize = newSize
      }
      .position(bubbleCenter)
  }

  private var bubbleCenter: CGPoint {
    guard bubbleSize.width > 0 && bubbleSize.height > 0 else {
      return anchor
    }
    let tailTipX = tailOffset + (tailSize.width / 2.0)
    let dx = (bubbleSize.width / 2.0) - tailTipX
    let dy = -(bubbleSize.height / 2.0) + (tailSize.height / 2.0)
    return CGPoint(x: anchor.x + dx, y: anchor.y + dy)
  }
}

private struct BubbleSizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

// MARK: - Overlay Content View

/// A custom `NSHostingView` that captures mouse clicks and drags.
/// Wraps the `OverlayContentView`.
class ClickableHostingView<Content: View>: NSHostingView<Content> {
  override func mouseDown(with event: NSEvent) {
    // We don't call super.mouseDown(with: event) here. This "consumes" the event, preventing it
    // from propagating to other system services (like the "hide all windows" shortcut when Option
    // is held).

    // Convert event position in window to local view coordinates.
    let position = convert(event.locationInWindow, from: nil)

    // Post a notification that a swat drag started at the cursor's location.
    Events.startSwatDrag.send(position)
  }

  override func mouseDragged(with event: NSEvent) {
    // Convert event position in window to local view coordinates.
    let position = convert(event.locationInWindow, from: nil)

    // Post a notification that the swat drag is being updated.
    Events.updateSwatDrag.send(position)
  }

  override func mouseUp(with event: NSEvent) {
    // Convert event position in window to local view coordinates.
    let position = convert(event.locationInWindow, from: nil)

    // Post a notification that the swat drag ended.
    Events.endSwatDrag.send(position)
  }
}

/// Main overlay view wrapped by `ClickableHostingView`.
struct OverlayContentView: View {
  // Cross-references between managers are set on view initialization.
  @StateObject private var swatterManager = SwatterManager()
  @StateObject private var flyManager = FlyManager()
  @StateObject private var inputManager = InputManager()
  @StateObject private var soundManager = SoundManager()
  @StateObject private var timeTrialManager = TimeTrialManager()
  @StateObject private var roastManager = RoastModeManager()
  @StateObject private var intentsManager = IntentsManager.shared

  @State private var timeTrialResultSeconds: Double?
  @State private var timeTrialCountdownValue: Int?
  @State private var timeTrialStart: Date?

  var body: some View {
    let isSwatterActive = inputManager.isActivationPressed

    ZStack {
      Color.clear
        .ignoresSafeArea()
      ForEach(flyManager.flies) { fly in
        FlyView(fly: fly)
      }
      if swatterManager.isDragging || swatterManager.animatedConeState != nil {
        SwatterView(swatterManager: swatterManager)
      }

      // Final elapsed time after time trial ends.
      if let result = timeTrialResultSeconds {
        Text(formatTime(result))
          .font(.system(size: 56, weight: .bold, design: .monospaced))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.8), radius: 6)
      }

      // Live elapsed time while time trial is active.
      if let start = timeTrialStart, timeTrialCountdownValue == nil {
        TimelineView(.animation) { timeline in
          let elapsed = timeline.date.timeIntervalSince(start)
          Text(formatTime(elapsed))
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.8), radius: 6)
            .padding(.top, 40)
            .frame(maxHeight: .infinity, alignment: .top)
        }
      }

      // Countdown value before time trial starts.
      if let countdownValueCurrent = timeTrialCountdownValue {
        Text(countdownValueCurrent == 0 ? "Go!" : "\(countdownValueCurrent)")
          .font(.system(size: 72, weight: .heavy))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.9), radius: 8)
      }
    }
    .onAppear {
      // Set initial state.
      swatterManager.setVisibility(to: isSwatterActive)

      // Establish cross-references (cannot be done in property wrapper).
      flyManager.setSwatterManager(swatterManager)
      swatterManager.setFlyManager(flyManager)
      soundManager.setup(flyManager: flyManager, swatterManager: swatterManager)
      timeTrialManager.setup(flyManager: flyManager)
      intentsManager.setup(flyManager: flyManager, timeTrialManager: timeTrialManager)
      roastManager.setup()

      // Apply current settings at startup.
      applySpawnSettings(AppSettings.shared.spawn)
    }
    .onChange(of: isSwatterActive) { _, newValue in
      swatterManager.setVisibility(to: newValue)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Drag notifications.
    .onReceive(Events.startSwatDrag) { position in
      guard isSwatterActive else {
        return
      }
      swatterManager.startSwatDrag(at: position)
    }
    .onReceive(Events.updateSwatDrag) { position in
      guard isSwatterActive else {
        return
      }
      swatterManager.updateSwatDrag(to: position)
      flyManager.scareFlies(from: position)
    }
    .onReceive(Events.endSwatDrag) { _ in
      guard isSwatterActive else {
        return
      }
      swatterManager.endSwatDrag()
    }
    // Hover notifications for scaring flies.
    .onContinuousHover { phase in
      switch phase {
      case .active(let location):
        flyManager.scareFlies(from: location)
      case .ended:
        break
      }
    }
    // Settings-driven hooks.
    .onReceive(Events.applySpawnSettings) { spawn in
      applySpawnSettings(spawn)
    }
    .onReceive(Events.timeTrialCompleted) { seconds in
      timeTrialResultSeconds = seconds
      timeTrialStart = nil
      Task {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await MainActor.run {
          withAnimation(.easeOut(duration: 0.5)) {
            timeTrialResultSeconds = nil
          }
        }
      }
    }
    .onReceive(Events.timeTrialAborted) { _ in
      timeTrialStart = nil
      withAnimation(.easeOut(duration: 0.2)) {
        timeTrialCountdownValue = nil
      }
    }
    .onReceive(Events.timeTrialCountingDown) { val in
      withAnimation(.spring()) {
        timeTrialCountdownValue = val
      }
      if val == 0 {
        Task {
          try? await Task.sleep(nanoseconds: 600_000_000)
          await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
              timeTrialCountdownValue = nil
            }
          }
        }
      }
    }
    .onReceive(Events.timeTrialStarted) { start in
      timeTrialStart = start
    }
    .onReceive(Events.stopTimeTrial) { _ in
      timeTrialStart = nil
    }
  }
}

extension OverlayContentView {
  fileprivate func applySpawnSettings(_ settings: AppSettings.SpawnSettings) {
    flyManager.applySpawnSettings(
      mode: settings.mode,
      initialCount: settings.initialCount,
      maxCount: settings.maxCount,
      interval: settings.intervalSeconds
    )
  }

  fileprivate func formatTime(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = seconds - Double(mins * 60)
    return String(format: "%02d:%05.2f", mins, secs)
  }
}
