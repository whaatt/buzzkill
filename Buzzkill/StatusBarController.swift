//
//  StatusBarController.swift
//  Buzzkill
//
//  Views and controller for the status bar item and panel.
//

import AppKit
import Combine
import CryptoKit
import KeyboardShortcuts
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class StatusBarController: NSObject, ObservableObject {
  @Published var statusItem: NSStatusItem
  var updater: SPUUpdater

  // Dimensions are hard-coded in configuration methods.
  private var panel: NSPanel?
  private var hostingController: NSHostingController<StatusBarContentView>?
  private var cancellables = Set<AnyCancellable>()
  private var globalEventMonitor: Any?
  private var settleTask: Task<Void, Never>?
  private var lastMeasuredContentSize: CGSize = .zero

  // OAuth temporary state (API key stored in `AppSettings`)
  private var localOAuthServer: LocalOAuthServer?
  private var pendingOAuthState: String?
  private var pendingCodeVerifier: String?
  @Published var roastOAuthErrorMessage: String?

  // MARK: - Initialization

  init(updater: SPUUpdater) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.updater = updater
    super.init()

    configureButton()
    configurePanel()
    observeNotifications()
  }

  private func observeNotifications() {
    // Reposition panel when status item window moves (e.g. menu bar hiding or showing).
    if let buttonWindow = statusItem.button?.window {
      NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: buttonWindow)
        .sink { [weak self] _ in
          self?.scheduleSettledReposition()
        }
        .store(in: &cancellables)
      NotificationCenter.default.publisher(
        for: NSWindow.didResizeNotification,
        object: buttonWindow
      )
      .sink { [weak self] _ in
        self?.scheduleSettledReposition()
      }
      .store(in: &cancellables)
    }
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        self?.scheduleSettledReposition()
      }
      .store(in: &cancellables)

    // Close panel when a time trial starts.
    Events.startTimeTrial
      .sink { [weak self] _ in
        self?.detachAndHidePanel()
      }
      .store(in: &cancellables)

    // Close panel when the active macOS Space changes.
    NSWorkspace.shared.notificationCenter.publisher(
      for: NSWorkspace.activeSpaceDidChangeNotification
    )
    .sink { [weak self] _ in
      self?.detachAndHidePanel()
    }
    .store(in: &cancellables)

    // Close panel when a swat drag starts.
    Events.startSwatDrag
      .sink { [weak self] _ in
        self?.detachAndHidePanel()
      }
      .store(in: &cancellables)

    // Toggle panel on double-tap of activation shortcut.
    Events.toggleStatusPanel
      .sink { [weak self] _ in
        self?.togglePanel(nil)
      }
      .store(in: &cancellables)

    // Handle quirk with KeyboardShortcuts alert window.
    NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        Task { @MainActor in
          guard let self = self, let panel = self.panel else {
            return
          }
          panel.level = .statusBar
        }
      }
      .store(in: &cancellables)

    // Handle redirected queries to finish the OpenRouter OAuth flow.
    Events.localOAuthServerReceivedQuery
      .sink { [weak self] query in
        self?.finishOpenRouterOAuth(for: query)
      }
      .store(in: &cancellables)

    // Handle requests from the UI to start the OpenRouter OAuth flow.
    Events.requestOpenRouterOAuth
      .sink { [weak self] _ in
        self?.startOpenRouterOAuth()
      }
      .store(in: &cancellables)
  }

  // MARK: - View Host Configuration

  private func configureButton() {
    if let button = statusItem.button {
      let flyEmoji = "🪰"
      let font = NSFont.systemFont(ofSize: 14)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.controlTextColor,
      ]
      let size = flyEmoji.size(withAttributes: attributes)
      let image = NSImage(size: size)
      image.lockFocus()
      flyEmoji.draw(at: .zero, withAttributes: attributes)
      image.unlockFocus()
      image.isTemplate = false

      button.image = image
      button.imagePosition = .imageOnly
      button.toolTip = "Buzzkill"
      button.action = #selector(togglePanel(_:))
      button.target = self
    }
  }

  private func configurePanel() {
    // Create an activating panel that floats at the status bar level.
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: .zero),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.becomesKeyOnlyIfNeeded = true
    panel.worksWhenModal = true

    // Create SwiftUI content.
    let hostingController = NSHostingController(rootView: StatusBarContentView(model: self))
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    self.hostingController = hostingController

    // Create a container view to hold the SwiftUI content.
    let containerView = NSView()
    containerView.translatesAutoresizingMaskIntoConstraints = false

    // Embed the SwiftUI content to expand inside the container view.
    containerView.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    // Create background view with vibrancy effect to hold the container view.
    let backgroundView = NSVisualEffectView(frame: NSRect(origin: .zero, size: .zero))
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    if #available(macOS 13.0, *) {
      backgroundView.material = .popover
    } else {
      backgroundView.material = .menu
    }
    backgroundView.state = .active

    // Embed the container view to expand inside the background view.
    backgroundView.addSubview(containerView)
    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      containerView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      containerView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
    ])

    // Create an outer container view at the top level of the panel (used for clipping all content
    // to rounded corners). This holds the background view.
    let outerContainerView = NSView(frame: NSRect(origin: .zero, size: .zero))
    outerContainerView.translatesAutoresizingMaskIntoConstraints = false
    outerContainerView.wantsLayer = true
    outerContainerView.layer?.cornerRadius = 9
    outerContainerView.layer?.masksToBounds = true

    // Embed the background view to expand inside the outer container view.
    outerContainerView.addSubview(backgroundView)
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: outerContainerView.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: outerContainerView.trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: outerContainerView.topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: outerContainerView.bottomAnchor),
    ])

    // Set the panel to hold the outer container view.
    // Hierarchy: Panel -> Outer Container -> Background -> Container -> Content.
    panel.contentView = outerContainerView
    self.panel = panel

    // Run an initial size and position calculation.
    if let button = statusItem.button {
      sizeAndPositionPanel(relativeTo: button, duringConfiguration: true)
    }
  }

  // MARK: - Panel Management

  private func sizeAndPositionPanel(
    relativeTo button: NSStatusBarButton,
    duringConfiguration: Bool = false
  ) {
    guard let panel = panel else {
      return
    }
    guard let contentView = panel.contentView else {
      return
    }
    guard let window = button.window else {
      return
    }
    guard let screen = window.screen ?? NSScreen.main else {
      return
    }

    // Useful layout rects and constants.
    let frameRect = screen.frame
    let visibleRect = screen.visibleFrame
    let buttonWindowRect = button.convert(button.bounds, to: nil)
    let buttonScreenRect = window.convertToScreen(buttonWindowRect)
    // Status bar and notch weirdness can cause the panel to be too close to the top.
    // Double the margin if there is a large top inset (suggesting a notch).
    let isProbableNotch = frameRect.maxY - visibleRect.maxY >= 16
    let panelOutsideMargin: CGFloat = isProbableNotch ? 12 : 6
    let desktopSpaceOffset: CGFloat = 1

    // Constrain the panel content to the maximum available space it has to render, then allow it
    // to grow to the extent it wants to. Record that height so we can size the panel.
    let maxHeightBelowButton = max(
      0,
      buttonScreenRect.minY - visibleRect.minY - 2 * panelOutsideMargin - desktopSpaceOffset
    )
    let heightConstraint = contentView.heightAnchor.constraint(
      lessThanOrEqualToConstant: maxHeightBelowButton
    )
    heightConstraint.isActive = true
    contentView.layoutSubtreeIfNeeded()
    let newPanelHeight = contentView.fittingSize.height
    heightConstraint.isActive = false

    // Center panel under the status item horizontally (clamped to the visible frame).
    let preferredX = round(buttonScreenRect.midX - panel.frame.size.width / 2)
    let x = max(visibleRect.minX, min(preferredX, visibleRect.maxX - panel.frame.size.width))

    // Place the panel relative to the status bar button with some margin. Ensure that the top of
    // the panel is on the visible screen.
    let preferredY =
      buttonScreenRect.minY - newPanelHeight - panelOutsideMargin - desktopSpaceOffset
    let maxY = visibleRect.maxY - newPanelHeight - panelOutsideMargin - desktopSpaceOffset
    let y = min(maxY, preferredY)

    // Set the panel's position and dimensions.
    panel.setFrame(NSRect(x: x, y: y, width: 540, height: newPanelHeight), display: false)

    // Attach panel to the status bar button.
    if panel.parent == nil, !duringConfiguration {
      window.addChildWindow(panel, ordered: .above)
    }
  }

  private func scheduleSettledReposition() {
    guard let button = statusItem.button, let panel = panel, panel.isVisible else {
      return
    }
    // Task to reposition the panel after top bar animations finish.
    settleTask?.cancel()
    settleTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2 seconds.
      guard let self = self else {
        return
      }
      self.sizeAndPositionPanel(relativeTo: button)
    }
  }

  private func showPanel(relativeTo button: NSStatusBarButton) {
    guard let panel = panel else {
      return
    }

    // Set panel geometry and bring to front.
    sizeAndPositionPanel(relativeTo: button)
    panel.orderFrontRegardless()
    panel.makeFirstResponder(nil)

    // Schedule a settle reposition after top bar animations finish.
    scheduleSettledReposition()
  }

  func contentSizeDidChange(_ newSize: CGSize) {
    // Avoid redundant work if the content size has not changed.
    if newSize == lastMeasuredContentSize {
      return
    }
    lastMeasuredContentSize = newSize
    guard isPanelVisible, let button = statusItem.button else {
      return
    }
    // Recompute panel size/position to match new content.
    showPanel(relativeTo: button)
  }

  private func detachAndHidePanel() {
    guard let panel = panel else {
      return
    }
    if panel.isVisible {
      panel.orderOut(nil)
    }
  }

  // MARK: - Notification Selectors

  @objc private func togglePanel(_ sender: AnyObject?) {
    if isPanelVisible {
      hidePanel()
    } else {
      showPanelAndMonitor()
    }
  }

  // MARK: - Public API

  func openStatusPanel() {
    if !isPanelVisible {
      showPanelAndMonitor()
    }
  }

  private var isPanelVisible: Bool {
    panel?.isVisible ?? false
  }

  private func showPanelAndMonitor() {
    guard let button = statusItem.button else {
      return
    }
    showPanel(relativeTo: button)
    startEventMonitorsForPanel()
  }

  private func hidePanel() {
    detachAndHidePanel()
    stopEventMonitorsForPanel()
  }

  // MARK: - Event Monitoring

  private func startEventMonitorsForPanel() {
    stopEventMonitorsForPanel()
    // Global monitor catches clicks outside the app entirely.
    globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.detachAndHidePanel()
    }
  }

  private func stopEventMonitorsForPanel() {
    if let global = globalEventMonitor {
      NSEvent.removeMonitor(global)
      globalEventMonitor = nil
    }
  }
}

// MARK: - OAuth Utilities

extension StatusBarController {
  private func startOpenRouterOAuth() {
    // PKCE OAuth per OpenRouter docs: https://openrouter.ai/docs/use-cases/oauth-pkce.
    if let existingLocalOAuthServer = localOAuthServer {
      existingLocalOAuthServer.stop()
    }
    localOAuthServer = LocalOAuthServer()
    roastOAuthErrorMessage = nil

    // Open the OpenRouter OAuth page in a background task.
    Task { @MainActor in
      guard
        let callbackURL = await localOAuthServer?.start(
          onRequest: { query in
            Events.localOAuthServerReceivedQuery.send(query)
          })
      else {
        return
      }

      // Generate a new OAuth state and PKCE verifier.
      let newOAuthState = UUID().uuidString
      pendingOAuthState = newOAuthState
      let codeVerifier = Self.generateCodeVerifier()
      pendingCodeVerifier = codeVerifier
      let codeChallenge = Self.generateCodeChallengeS256(from: codeVerifier)

      // Build and open the OAuth URL.
      var urlComponents = URLComponents()
      urlComponents.scheme = "https"
      urlComponents.host = "openrouter.ai"
      urlComponents.path = "/auth"
      urlComponents.queryItems = [
        URLQueryItem(name: "callback_url", value: callbackURL),
        URLQueryItem(name: "code_challenge", value: codeChallenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: newOAuthState),
      ]
      if let url = urlComponents.url {
        NSWorkspace.shared.open(url)
      }
    }
  }

  private func finishOpenRouterOAuth(for query: [String: String]) {
    let receivedOAuthState = query["state"]
    let receivedAuthorizationCode = query["code"]
    guard receivedOAuthState == pendingOAuthState else {
      self.roastOAuthErrorMessage =
        "Authorization state mismatch. Please try again."
      return
    }
    guard let receivedAuthorizationCode else {
      self.roastOAuthErrorMessage =
        "Authorization code missing. Please try again."
      return
    }
    guard let codeVerifier = self.pendingCodeVerifier else {
      self.roastOAuthErrorMessage =
        "Internal error (no verifier). Please try again."
      return
    }

    // Exchange the authorization code for an API key in a background task.
    Task { @MainActor in
      var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let body: [String: Any] = [
        "code": receivedAuthorizationCode,
        "code_verifier": codeVerifier,
        "code_challenge_method": "S256",
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
          self.roastOAuthErrorMessage =
            "Failed to reach OpenRouter. Please try again."
          return
        }

        // Set Roast Mode configuration.
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if let key = jsonObject?["key"] as? String {
          var roast = AppSettings.shared.roast
          roast.apiKey = key
          AppSettings.shared.roast = roast
          self.roastOAuthErrorMessage = nil
        } else {
          self.roastOAuthErrorMessage =
            "OpenRouter did not return a token. Please try again."
        }
      } catch {
        self.roastOAuthErrorMessage =
          "Unknown network error. Please try again."
        return
      }
    }
  }

  // MARK: - PKCE Helpers

  private static func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 64)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let data = Data(bytes)
    return base64Url(data.base64EncodedString())
  }

  private static func generateCodeChallengeS256(from verifier: String) -> String {
    let data = Data(verifier.utf8)
    let digest = SHA256.hash(data: data)
    return base64Url(Data(digest).base64EncodedString())
  }

  private static func base64Url(_ base64: String) -> String {
    return base64.replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

// MARK: - Core SwiftUI Content

struct StatusBarContentView: View {
  @ObservedObject private var model: StatusBarController
  @ObservedObject private var settings = AppSettings.shared
  @FocusState private var isRecorderFocused: Bool

  @State private var automaticallyChecksForUpdates: Bool
  @State private var automaticallyDownloadsUpdates: Bool
  @State private var countdownValue: Int?
  @State private var isTimeTrialActive: Bool = false
  @State private var showingAbout: Bool = false
  @State private var timeTrialStart: Date?

  init(model: StatusBarController) {
    self.model = model
    self.automaticallyChecksForUpdates = model.updater.automaticallyChecksForUpdates
    self.automaticallyDownloadsUpdates = model.updater.automaticallyDownloadsUpdates
  }

  var body: some View {
    ZStack {
      VStack {
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
              Text("Buzzkill")
                .font(.title)
                .fontWeight(.bold)
              Spacer()
              Button("Quit") {
                NSApp.terminate(nil)
              }
              .hoverAccentButtonSmall()
            }

            // Main action buttons.
            VStack(alignment: .leading, spacing: 8) {
              HoverSegmentedPicker(
                selection: $settings.spawn.mode,
                options: AppSettings.SpawnMode.allCases,
                isEnabled: !isTimeTrialActive
              ) { mode in
                Text(mode == .auto ? "Auto-Spawn" : "Off")
                  .frame(maxWidth: .infinity)
              }
              Button {
                if isTimeTrialActive || (countdownValue ?? 0) > 0 {
                  Events.stopTimeTrial.send(())
                } else {
                  Events.startTimeTrial.send(settings.timeTrial.initialCount)
                }
              } label: {
                Text(
                  isTimeTrialActive || (countdownValue ?? 0) > 0
                    ? "Stop Time Trial" : "Start Time Trial"
                )
                .frame(maxWidth: .infinity)
              }
              .controlSize(.large)
              .hoverAccentButtonLarge()
              Button {
                Events.killAllFlies.send(true)
              } label: {
                Text("Go Nuclear")
                  .frame(maxWidth: .infinity)
              }
              .disabled(isTimeTrialActive)
              .controlSize(.large)
              .hoverAccentButtonLarge(isDestructive: true)
            }

            Divider()

            // Master volume slider.
            HStack {
              Image(systemName: "speaker.slash.fill")
              Spacer()
              Slider(
                value: Binding(
                  get: { Double(settings.audio.masterVolume) },
                  set: { settings.audio.masterVolume = Float($0) }
                ), in: 0...1
              )
              Spacer()
              Image(systemName: "speaker.wave.2.fill")
            }

            Divider()

            // Swatter activation shortcut (via `KeyboardShortcuts`).
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Swatter Binding:\t\t")
                KeyboardShortcuts.Recorder(
                  for: .swatterActivation
                )
                .focused($isRecorderFocused)
                .onChange(of: isRecorderFocused) { _, focused in
                  if !focused && KeyboardShortcuts.Name.swatterActivation.shortcut == nil {
                    KeyboardShortcuts.reset(.swatterActivation)
                  }
                }
                .overlay(
                  RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue, lineWidth: isRecorderFocused ? 2 : 0)
                )
                Spacer()
                Text("[2X quickly to toggle panel.]")
                  .foregroundColor(.secondary)
              }
            }

            Divider()

            // Spawn settings.
            DisclosureGroup(
              isExpanded: Binding(
                get: { settings.disclosureGroup.autoSpawnExpanded },
                set: { settings.disclosureGroup.autoSpawnExpanded = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text("Initial Count: **\(settings.spawn.initialCount)**\t\t")
                  Slider(
                    value: Binding(
                      get: { Double(settings.spawn.initialCount) },
                      set: { settings.spawn.initialCount = Int($0) }
                    ), in: 1...40
                  )
                }
                HStack {
                  Text("Max Count: **\(settings.spawn.maxCount)**\t\t")
                  Slider(
                    value: Binding(
                      get: { Double(settings.spawn.maxCount) },
                      set: { settings.spawn.maxCount = Int($0) }
                    ), in: 1...40
                  )
                }
                HStack {
                  Text(
                    "Interval Seconds: **\(Int(settings.spawn.intervalSeconds))**\t"
                  )
                  Slider(
                    value: Binding(
                      get: { Double(settings.spawn.intervalSeconds) },
                      set: { settings.spawn.intervalSeconds = Double(Int($0)) }
                    ), in: 1...300
                  )
                }
              }
              .disabled(isTimeTrialActive)
            } label: {
              Text("Auto-Spawn").font(.subheadline).bold()
            }
            .disclosureGroupStyle(CustomDisclosureGroupStyle())

            Divider()

            // Time Trial settings and statistics.
            DisclosureGroup(
              isExpanded: Binding(
                get: { settings.disclosureGroup.timeTrialExpanded },
                set: { settings.disclosureGroup.timeTrialExpanded = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text("Initial Count: **\(settings.timeTrial.initialCount)**\t\t")
                  Slider(
                    value: Binding(
                      get: { Double(settings.timeTrial.initialCount) },
                      set: { settings.timeTrial.initialCount = Int($0) }
                    ), in: 1...40
                  )
                  .disabled(isTimeTrialActive || (countdownValue ?? 0) > 0)
                }
                // Per-count stats.
                let rec = settings.timeTrial.recordsByInitialCount[settings.timeTrial.initialCount]
                let last = rec?.last ?? 0
                let pr = rec?.pr ?? 0
                Text(
                  "Last Time: **\(last != 0 ? formatDuration(seconds: last) : "N/A")**"
                )
                .padding(.top, 3)
                Text(
                  "Best Time: **\(pr != 0 ? formatDuration(seconds: pr) : "N/A")**"
                )
                .padding(.top, 5)
              }
            } label: {
              Text("Time Trial").font(.subheadline).bold()
            }
            .disclosureGroupStyle(CustomDisclosureGroupStyle())

            Divider()

            // Roast Mode settings.
            DisclosureGroup(
              isExpanded: Binding(
                get: { settings.disclosureGroup.roastModeExpanded },
                set: { settings.disclosureGroup.roastModeExpanded = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 8) {
                if (settings.roast.apiKey ?? "").isEmpty {
                  Button {
                    Events.requestOpenRouterOAuth.send(())
                  } label: {
                    Text("Configure Roast Mode").frame(maxWidth: .infinity)
                  }
                  .controlSize(.large)
                  .hoverAccentButtonLarge()
                  .disabled(isTimeTrialActive)
                  if let msg = model.roastOAuthErrorMessage, !msg.isEmpty {
                    Text(msg)
                      .foregroundColor(.secondary)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                } else {
                  Button(role: .destructive) {
                    var roast = settings.roast
                    roast.apiKey = nil
                    roast.isEnabled = false
                    settings.roast = roast
                  } label: {
                    Text("Destroy Roast Mode Configuration").frame(maxWidth: .infinity)
                  }
                  .controlSize(.large)
                  .hoverAccentButtonLarge(isDestructive: true)
                  Button(role: .destructive) {
                    if !settings.roast.isEnabled {
                      // Prompt for screen capture permission when enabling.
                      let ok = RoastModeManager().authorizeScreenCapture()
                      if !ok {
                        return
                      }
                      settings.roast.isEnabled = true
                    } else {
                      settings.roast.isEnabled = false
                    }
                  } label: {
                    Text(
                      settings.roast.isEnabled
                        ? "Stop Roasting"
                        : "Start Roasting → Transmits Screen Contents"
                    )
                    .foregroundColor(settings.roast.isEnabled ? .red : .primary)
                    .frame(maxWidth: .infinity)
                  }
                  .disabled(isTimeTrialActive)
                  .controlSize(.large)
                  .hoverAccentButtonLarge(isDestructive: !settings.roast.isEnabled)
                  .padding(.bottom, 5)
                  HStack {
                    let freq = Int(settings.roast.frequencySeconds)
                    Text("Interval Seconds: **\(freq)**\t")
                    Slider(
                      value: Binding(
                        get: { settings.roast.frequencySeconds },
                        set: { settings.roast.frequencySeconds = Double(Int($0)) }
                      ),
                      in: AppSettings.Defaults
                        .roastMinIntervalSeconds...AppSettings.Defaults.roastMaxIntervalSeconds,
                    )
                    .disabled(isTimeTrialActive)
                  }
                }
              }
            } label: {
              Text("Roast Mode (macOS 15+)").font(.subheadline).bold()
            }
            .disclosureGroupStyle(CustomDisclosureGroupStyle())

            Divider()

            // Sound toggles.
            DisclosureGroup(
              isExpanded: Binding(
                get: { settings.disclosureGroup.soundsExpanded },
                set: { settings.disclosureGroup.soundsExpanded = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 8) {
                Toggle("Fly Movement", isOn: $settings.audio.flyEnabled)
                  .hoverAccentCheckbox()
                Toggle("Swatter Drag", isOn: $settings.audio.swatterDragEnabled)
                  .hoverAccentCheckbox()
                Toggle("Swatter Hit", isOn: $settings.audio.splatEnabled)
                  .hoverAccentCheckbox()
                Toggle("Fly Death", isOn: $settings.audio.deathEnabled)
                  .hoverAccentCheckbox()
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
              Text("Sounds").font(.subheadline).bold()
            }
            .disclosureGroupStyle(CustomDisclosureGroupStyle())

            Divider()

            // System settings.
            DisclosureGroup(
              isExpanded: Binding(
                get: { settings.disclosureGroup.systemExpanded },
                set: { settings.disclosureGroup.systemExpanded = $0 }
              )
            ) {
              VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at login", isOn: $settings.system.launchAtLogin)
                  .onChange(of: settings.system.launchAtLogin) { oldValue, newValue in
                    configureLaunchAtLogin(
                      desiredEnabled: newValue,
                      previousEnabled: oldValue
                    )
                  }
                  .hoverAccentCheckbox()
                  .disabled(isTimeTrialActive)
                Toggle("Show debug elements", isOn: $settings.system.showDebugElements)
                  .onChange(of: settings.system.showDebugElements) { _, newValue in
                    settings.system.showDebugElements = newValue
                  }
                  .hoverAccentCheckbox()
                  .disabled(isTimeTrialActive)
                Toggle("Check for updates automatically", isOn: $automaticallyChecksForUpdates)
                  .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    model.updater.automaticallyChecksForUpdates = newValue
                  }
                  .hoverAccentCheckbox()
                  .disabled(isTimeTrialActive)
                Toggle("Download updates automatically", isOn: $automaticallyDownloadsUpdates)
                  .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                    model.updater.automaticallyDownloadsUpdates = newValue
                  }
                  .hoverAccentCheckbox()
                  .disabled(isTimeTrialActive)
              }
            } label: {
              Text("System").font(.subheadline).bold()
            }
            .disclosureGroupStyle(CustomDisclosureGroupStyle())

            Divider()

            // Reset and About buttons.
            VStack(alignment: .leading, spacing: 8) {
              Button(role: .destructive) {
                settings.resetAllSettings()
                // Also reset the global keyboard shortcut so the recorder reflects Option + Z.
                KeyboardShortcuts.Name.swatterActivation.shortcut = .init(.z, modifiers: [.option])
              } label: {
                Text("Reset All Settings")
                  .frame(maxWidth: .infinity)
              }
              .controlSize(.large)
              .hoverAccentButtonLarge(isDestructive: true)
              Button(role: .destructive) {
                settings.resetAllData()
              } label: {
                Text("Reset All Records")
                  .frame(maxWidth: .infinity)
              }
              .controlSize(.large)
              .disabled(isTimeTrialActive)
              .hoverAccentButtonLarge(isDestructive: true)
              Button {
                model.updater.checkForUpdates()
              } label: {
                Text("Check For Updates")
                  .frame(maxWidth: .infinity)
              }
              .controlSize(.large)
              .hoverAccentButtonLarge()
              Button {
                showingAbout = true
              } label: {
                Text("About")
                  .frame(maxWidth: .infinity)
              }
              .controlSize(.large)
              .hoverAccentButtonLarge()
            }
          }
          .padding(16)
          .background(
            GeometryReader { proxy in
              Color.clear.onChange(of: proxy.size) { _, newSize in
                model.contentSizeDidChange(newSize)
              }
            }
          )
        }
      }
      if showingAbout {
        // Dimmed background to capture outside taps.
        Color.black.opacity(0.25)
          .ignoresSafeArea()
          .onTapGesture {
            showingAbout = false
          }
        // Centered pop-up.
        VStack {
          AboutView(onClose: {
            showingAbout = false
          })
        }
        .frame(width: 380, height: 280)
        .background(
          RoundedRectangle(cornerRadius: 9)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
      }
    }
    .onAppear {
      applySpawnSettingsToRuntime()
      syncLaunchAtLoginFromSystem()
    }
    .onReceive(
      settings.$spawn
        .removeDuplicates()
        .debounce(for: .milliseconds(0), scheduler: RunLoop.main)
    ) { _ in
      if !isTimeTrialActive {
        applySpawnSettingsToRuntime()
      }
    }
    .onReceive(Events.startTimeTrial) { _ in
      isTimeTrialActive = true
    }
    .onReceive(Events.stopTimeTrial) { _ in
      isTimeTrialActive = false
      timeTrialStart = nil
      countdownValue = nil
    }
    .onReceive(Events.timeTrialAborted) { _ in
      isTimeTrialActive = false
      timeTrialStart = nil
      countdownValue = nil
    }
    .onReceive(Events.timeTrialCompleted) { _ in
      isTimeTrialActive = false
      timeTrialStart = nil
      countdownValue = nil
    }
    .onReceive(Events.timeTrialStarted) { start in
      timeTrialStart = start
    }
    .onReceive(Events.timeTrialCountingDown) { value in
      countdownValue = value
    }
  }

  private func configureLaunchAtLogin(
    desiredEnabled: Bool,
    previousEnabled: Bool
  ) {
    if #available(macOS 13.0, *) {
      // Avoid redundant calls if system state already matches desired state.
      let isCurrentlyEnabled = (SMAppService.mainApp.status == .enabled)
      if isCurrentlyEnabled == desiredEnabled {
        return
      }
      do {
        if desiredEnabled {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        // Revert toggle on failure to reflect actual system state.
        settings.system.launchAtLogin = previousEnabled
      }
    } else {
      // Not supported on older macOS via this API; revert state.
      settings.system.launchAtLogin = previousEnabled
    }
  }

  private func syncLaunchAtLoginFromSystem() {
    if #available(macOS 13.0, *) {
      settings.system.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
  }

  private func applySpawnSettingsToRuntime() {
    Events.applySpawnSettings.send(settings.spawn)
  }

  private func formatDuration(seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = seconds - Double(mins * 60)
    return String(format: "%02d:%05.2f", mins, secs)
  }
}

// MARK: - About View

struct AboutView: View {
  var onClose: (() -> Void)? = nil
  private var appIcon: NSImage {
    if let icon = NSApp.applicationIconImage {
      return icon
    }
    return NSImage(size: NSSize(width: 128, height: 128))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 16) {
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .frame(width: 64, height: 64)
        VStack(alignment: .leading) {
          Text(BuzzkillApp.Constants.name).font(.title2).fontWeight(.bold)
          Text(BuzzkillApp.Constants.version).foregroundStyle(.secondary)
        }
      }

      Divider()

      ScrollView {
        Text(.init(BuzzkillApp.Constants.descriptionMarkdown))
      }
      .padding(.top, 16)
      HStack {
        Spacer()
        Button("Close") {
          if let onClose = onClose {
            onClose()
          } else {
            NSApp.keyWindow?.close()
          }
        }
        .keyboardShortcut(.cancelAction)
        .controlSize(.large)
        .hoverAccentButtonLarge()
      }
    }
    .padding(16)
  }
}

// MARK: - Hover Accent Utilities

private struct HoverAccent: ViewModifier {
  var cornerRadius: CGFloat = 8
  var strokeWidth: CGFloat = 2
  var fillOpacity: Double = 0.08
  var contentPadding: CGFloat = 0
  var color: NSColor = .controlAccentColor

  @State private var isHovered: Bool = false
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    let accent = Color(nsColor: color)
    return
      content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .inset(by: -contentPadding)
          .fill(accent.opacity((isHovered && isEnabled) ? fillOpacity : 0))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .inset(by: -contentPadding)
          .stroke((isHovered && isEnabled) ? accent : .clear, lineWidth: strokeWidth)
      )
      .onHover { hovering in
        isHovered = hovering && isEnabled
      }
  }
}

extension View {
  fileprivate func hoverAccent(
    cornerRadius: CGFloat = 8,
    strokeWidth: CGFloat = 2,
    fillOpacity: Double = 0.08,
    contentPadding: CGFloat = 0,
    color: NSColor = .controlAccentColor
  ) -> some View {
    modifier(
      HoverAccent(
        cornerRadius: cornerRadius,
        strokeWidth: strokeWidth,
        fillOpacity: fillOpacity,
        contentPadding: contentPadding,
        color: color
      )
    )
  }

  // Convenience presets to avoid repeating parameter sets.
  func hoverAccentButtonLarge(isDestructive: Bool = false) -> some View {
    hoverAccent(
      cornerRadius: 8,
      strokeWidth: 0,
      fillOpacity: 0.2,
      color: isDestructive ? .systemRed : .controlAccentColor
    )
  }

  fileprivate func hoverAccentButtonSmall() -> some View {
    hoverAccent(
      cornerRadius: 6,
      strokeWidth: 0,
      fillOpacity: 0.2,
      color: .systemPink
    )
  }

  fileprivate func hoverAccentCheckbox() -> some View {
    hoverAccent(cornerRadius: 1, strokeWidth: 0, fillOpacity: 0.2, contentPadding: 4)
  }
}

// MARK: - Hover Segmented Picker

struct HoverSegmentedPicker<Selection: Hashable, Content: View>: View {
  @Binding var selection: Selection
  let options: [Selection]
  var isEnabled: Bool = true
  let content: (Selection) -> Content

  @Environment(\.isEnabled) private var environmentEnabled

  var body: some View {
    // Create a lighter version of the accent color without using opacity (non-selected buttons
    // should not be visible behind their overlap with the selected button).
    let selectedColor = Color(
      nsColor: NSColor.controlAccentColor.blended(
        withFraction: 0.2, of: .white
      ) ?? NSColor.controlAccentColor
    )
    ZStack {
      HStack(spacing: -12) {
        ForEach(options, id: \.self) { option in
          let isSelected = option == selection
          Group {
            if isSelected {
              Button {
                selection = option
              } label: {
                content(option)
                  .font(.system(size: NSFont.systemFontSize))
                  .foregroundColor(Color.white)
                  .offset(y: -1)
              }
              .buttonStyle(.borderless)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(selectedColor)
              )
            } else {
              Button {
                selection = option
              } label: {
                content(option)
                  .font(.system(size: NSFont.systemFontSize))
              }
              .buttonStyle(.bordered)
              .controlSize(.large)
            }
          }
          .frame(maxWidth: .infinity)
          .hoverAccentButtonLarge()
          .opacity((isEnabled && environmentEnabled) ? 1.0 : 0.5)
          .disabled(!(isEnabled && environmentEnabled))
          // Give the selected button a higher `zIndex` so it appears on top.
          .zIndex(isSelected ? 1 : 0)
        }
      }
    }
  }
}

// MARK: - Disclosure Group Custom Style

struct NoTapAnimationStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onTapGesture(perform: configuration.trigger)
  }
}

struct CustomDisclosureGroupStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack {
          configuration.label
          Spacer()
          Image(systemName: "chevron.down")
            .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
        }
      }
      .buttonStyle(NoTapAnimationStyle())
      .padding(16)
      .contentShape(Rectangle())
      .onTapGesture {
        configuration.isExpanded.toggle()
      }
      .padding(-16)
      if configuration.isExpanded {
        configuration.content
      }
    }
  }
}
