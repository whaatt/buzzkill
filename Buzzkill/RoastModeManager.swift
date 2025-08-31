//
//  RoastModeManager.swift
//  Buzzkill
//
//  Manages Roast Mode lifecycle (a timer, screen captures, OpenRouter calls, and roasts).
//

import AppKit
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

@MainActor
final class RoastModeManager: ObservableObject {
  static let logger = Logger(
    subsystem: OSLog.subsystem,
    category: String(describing: RoastModeManager.self)
  )

  struct RoastOutput: Codable {
    let description: String
    let tweet: String
  }

  // MARK: - Constants

  private enum Constants {
    static let bufferCapacity: Int = 10
    static let minInterval: Double = AppSettings.Defaults.roastMinIntervalSeconds
    static let maxInterval: Double = AppSettings.Defaults.roastMaxIntervalSeconds
    static let jitterFraction: Double = 0.15  // ±15% jitter.
    static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let model = "openai/gpt-5"
    static let prompt: String = """
      You are user `dril` on X (Twitter). You are given a screenshot of a user's desktop, as well
      as a list of previous descriptions and tweets. Analyze the screenshot and write:
      - `description`: A neutral description of what the user is doing (not in character)
      - `tweet`: A tweet about what you see

      Return strict JSON with keys: `description` and `tweet`. No extra keys or text.

      Some helpful hints:
      - Try not to repeat yourself (use `tweet` context to help)
      - Use `description` context to help you understand the user and refer to things over time
        (if it's relevant to the tweet, but don't go out of your way to do so)
      - Don't overindex on peripheral content in the screenshot or content in the `description` and
        `tweet` context
      """
  }

  // MARK: - State

  private var cancellables = Set<AnyCancellable>()
  private var timerTask: Task<Void, Never>?
  private var descriptionBuffer: [String] = []
  private var roastBuffer: [String] = []
  private var bufferIndex: Int = 0
  private var isRunning: Bool = false

  // MARK: - Setup

  func setup() {
    observe()
    applySettingsAndMaybeStart()
  }

  private func observe() {
    // Pause during time trial.
    Events.timeTrialStarted
      .sink { [weak self] _ in
        self?.stop()
      }
      .store(in: &cancellables)
    Events.timeTrialAborted
      .sink { [weak self] _ in
        self?.applySettingsAndMaybeStart()
      }
      .store(in: &cancellables)
    Events.timeTrialCompleted
      .sink { [weak self] _ in
        self?.applySettingsAndMaybeStart()
      }
      .store(in: &cancellables)

    // React to settings changes.
    AppSettings.shared.$roast
      .removeDuplicates()
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        self?.applySettingsAndMaybeStart()
      }
      .store(in: &cancellables)
  }

  // MARK: - Roast Mode Lifecycle

  private func applySettingsAndMaybeStart() {
    let roast = AppSettings.shared.roast
    guard roast.apiKey != nil, !(roast.apiKey ?? "").isEmpty else {
      stop()
      return
    }
    if roast.isEnabled {
      start(interval: clampInterval(roast.frequencySeconds))
    } else {
      stop()
    }
  }

  private func start(interval: Double) {
    guard !isRunning else {
      return
    }
    isRunning = true
    scheduleTimer(interval: interval)
  }

  private func stop() {
    isRunning = false
    timerTask?.cancel()
    timerTask = nil
    Events.showRoast.send(nil)
  }

  private func scheduleTimer(interval: Double) {
    timerTask?.cancel()
    let jitter = interval * Constants.jitterFraction
    let next = max(
      Constants.minInterval,
      min(Constants.maxInterval, interval + Double.random(in: -jitter...jitter))
    )
    let delayNanos = UInt64((next * 1_000_000_000).rounded())
    timerTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delayNanos)
      guard !Task.isCancelled, let self else {
        return
      }
      await self.performRoastCycle()
    }
  }

  /// Tries to perform a roast and then schedules a timer for the next roast.
  private func performRoastCycle() async {
    // Skip if disabled or no key.
    let roast = AppSettings.shared.roast
    guard roast.isEnabled, roast.apiKey != nil, !(roast.apiKey ?? "").isEmpty else {
      return
    }
    if authorizeScreenCapture() {
      await generateAndApplyRoast()
    }
    let interval = clampInterval(AppSettings.shared.roast.frequencySeconds)
    if isRunning {
      scheduleTimer(interval: interval)
    }
  }

  private func generateAndApplyRoast() async {
    guard
      let window = NSApp.windows.first(where: {
        $0.identifier == BuzzkillApp.Constants.overlayWindowIdentifier
      })
    else {
      return
    }
    guard let screen = window.screen else {
      return
    }
    guard let imageBase64PNG = await takeScreenshotAsBase64PNG(screen: screen) else {
      return
    }
    guard let apiKey = AppSettings.shared.roast.apiKey else {
      return
    }

    let messages = buildMessages(base64PNG: imageBase64PNG)
    let body: [String: Any] = [
      "model": Constants.model,
      "messages": messages,
      "response_format": ["type": "json_object"],
      "reasoning": [
        "effort": "minimal",
        "exclude": true,
      ],
    ]

    var request = URLRequest(url: Constants.openRouterEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        Self.logger.error(
          "Roast response is not an HTTPURLResponse: \(response, privacy: .public)"
        )
        return
      }
      guard (200..<300).contains(http.statusCode) else {
        Self.logger.error(
          "Roast response is not a 2XX status code: \(http.statusCode, privacy: .public)"
        )
        // Check for invalidated API key and disable Roast Mode if necessary.
        if http.statusCode == 401 {
          AppSettings.shared.roast.apiKey = nil
          AppSettings.shared.roast.isEnabled = false
          stop()
        }
        return
      }

      Self.logger.debug("Roast response: \(String(data: data, encoding: .utf8) ?? "nil")")
      let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
      if let jsonObject, let parsed = parseRoast(from: jsonObject) {
        pushDescription(parsed.description)
        pushRoast(parsed.tweet)
        Events.showRoast.send(parsed.tweet)
      }
    } catch let error as NSError {
      Self.logger.error(
        "Failed to parse roast response: \(error.localizedDescription, privacy: .public)"
      )
      return
    }
  }

  // MARK: - Screen Capture Authorization

  func authorizeScreenCapture() -> Bool {
    if screenCaptureIsAuthorized() {
      return true
    }
    if #available(macOS 10.15, *) {
      if !AppSettings.shared.roast.didRequestScreenCaptureAccess {
        AppSettings.shared.roast.didRequestScreenCaptureAccess = true
        CGRequestScreenCaptureAccess()
      } else {
        // Fall back to app-driven prompt if we requested via the system prompt before.
        promptForScreenCaptureAuthorization()
      }
    }
    return false
  }

  func screenCaptureIsAuthorized() -> Bool {
    if #available(macOS 10.15, *) {
      return CGPreflightScreenCaptureAccess()
    } else {
      return false
    }
  }

  func promptForScreenCaptureAuthorization() {
    let alert = NSAlert()
    alert.messageText = "Permission Required"
    alert.informativeText = """
      Please allow Buzzkill to capture your screen in System Settings.
      """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Cancel")

    // Hide panel and show permission prompt.
    if let panel = NSApp.windows.first(where: { $0 is NSPanel }) as? NSPanel {
      // TODO: Keep a more explicit reference to `StatusBarController` and use it here.
      panel.orderOut(nil)
    }
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      ) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  // MARK: - Screen Capture

  private func takeScreenshotAsBase64PNG(screen: NSScreen) async -> String? {
    guard #available(macOS 15.0, *) else {
      return nil
    }

    do {
      guard
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else {
        return nil
      }
      let displayID = CGDirectDisplayID(truncating: screenNumber)
      let content = try await SCShareableContent.current
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        return nil
      }

      // Exclude Buzzkill elements from the screenshot.
      let selfApplications = content.applications.filter { app in
        if let selfBid = Bundle.main.bundleIdentifier, app.bundleIdentifier == selfBid {
          return true
        }
        return app.processID == pid_t(getpid())
      }
      let contentFilter = SCContentFilter(
        display: display,
        excludingApplications: selfApplications,
        exceptingWindows: []
      )

      // Configure the underlying ScreenCaptureKit stream.
      let configuration = SCStreamConfiguration()
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = true
      configuration.width = Int(CGDisplayPixelsWide(displayID))
      configuration.height = Int(CGDisplayPixelsHigh(displayID))

      // Simplified image capture API in macOS 14 and newer.
      let cgImage = try await SCScreenshotManager.captureImage(
        contentFilter: contentFilter,
        configuration: configuration
      )
      let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
      guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        return nil
      }
      let base64 = pngData.base64EncodedString()
      // Debug: Save PNG and Base64 to an app-writable directory.
      // let fm = FileManager.default
      // let baseURL =
      //   fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      //   ?? fm.temporaryDirectory
      // let debugDir =
      //   baseURL
      //   .appendingPathComponent("Buzzkill", isDirectory: true)
      //   .appendingPathComponent("DebugScreenshots", isDirectory: true)
      // let timestamp = Int(Date().timeIntervalSince1970)
      // do {
      //   try fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
      //   let pngURL = debugDir.appendingPathComponent("screenshot_\(timestamp).png")
      //   do {
      //     try pngData.write(to: pngURL)
      //     Self.logger.debug("Saved debug screenshot to: \(pngURL.path)")
      //   } catch let error as NSError {
      //     Self.logger.error("Failed to write debug screenshot PNG: \(error.localizedDescription)")
      //   }
      //   let txtURL = debugDir.appendingPathComponent("screenshot_\(timestamp).txt")
      //   do {
      //     try base64.write(to: txtURL, atomically: true, encoding: .utf8)
      //     Self.logger.debug("Saved debug base64 to: \(txtURL.path)")
      //   } catch let error as NSError {
      //     Self.logger.error("Failed to write debug base64: \(error.localizedDescription)")
      //   }
      // } catch let error as NSError {
      //   Self.logger.error("Failed to prepare debug directory: \(error.localizedDescription)")
      // }
      return base64
    } catch {
      return nil
    }
  }

  // MARK: - Roast Generation

  private func buildMessages(base64PNG: String) -> [[String: Any]] {
    let descriptionContext: String
    if descriptionBuffer.isEmpty {
      descriptionContext = "No prior context."
    } else {
      descriptionContext = descriptionBuffer.joined(separator: "\n")
    }
    let roastContext: String
    if roastBuffer.isEmpty {
      roastContext = "No prior context."
    } else {
      roastContext = roastBuffer.joined(separator: "\n")
    }
    let system: [String: Any] = [
      "role": "system",
      "content": loadPromptText(),
    ]
    let user: [String: Any] = [
      "role": "user",
      "content": [
        [
          "type": "text",
          "text":
            "Recent descriptions (newest last; interval is \(AppSettings.shared.roast.frequencySeconds)):\n\(descriptionContext)",
        ],
        [
          "type": "text",
          "text":
            "Recent roasts (newest last; interval is \(AppSettings.shared.roast.frequencySeconds) seconds):\n\(roastContext)",
        ],
        [
          "type": "image_url",
          "image_url": "data:image/png;base64,\(base64PNG)",
        ],
      ],
    ]
    return [system, user]
  }

  private func parseRoast(from json: [String: Any]) -> RoastOutput? {
    // Expect `choices[0].message.content` as JSON string.
    guard let choices = json["choices"] as? [[String: Any]],
      let first = choices.first,
      let message = first["message"] as? [String: Any]
    else {
      return nil
    }
    if let content = message["content"] as? String,
      let data = content.data(using: .utf8),
      let out = try? JSONDecoder().decode(RoastOutput.self, from: data)
    {
      return out
    }
    return nil
  }

  // MARK: - Context Buffer Management

  private func pushDescription(_ text: String) {
    if descriptionBuffer.count < Constants.bufferCapacity {
      descriptionBuffer.append(text)
    } else {
      descriptionBuffer[bufferIndex % Constants.bufferCapacity] = text
      bufferIndex = (bufferIndex + 1) % Constants.bufferCapacity
    }
  }

  private func pushRoast(_ text: String) {
    if roastBuffer.count < Constants.bufferCapacity {
      roastBuffer.append(text)
    } else {
      roastBuffer[bufferIndex % Constants.bufferCapacity] = text
      bufferIndex = (bufferIndex + 1) % Constants.bufferCapacity
    }
  }

  // MARK: - Prompt Loading

  private func getPromptFileURL() -> URL {
    let fileManager = FileManager.default
    let baseURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let appDirectoryName = Bundle.main.bundleIdentifier ?? "Buzzkill"
    return
      baseURL
      .appendingPathComponent(appDirectoryName, isDirectory: true)
      .appendingPathComponent("prompt.txt", isDirectory: false)
  }

  private func loadPromptText() -> String {
    let defaultPrompt = Constants.prompt
    let fileManager = FileManager.default
    let fileURL = getPromptFileURL()
    Self.logger.debug("Prompt file URL: \(fileURL, privacy: .public)")

    // Ensure the parent directory exists.
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch let error as NSError {
      Self.logger.error(
        "Failed to create directory for prompt file: \(error.localizedDescription, privacy: .public)"
      )
      // If we cannot ensure the directory, fall back to the default prompt.
      return defaultPrompt
    }

    // If the file doesn't exist, create it with the default prompt.
    if !fileManager.fileExists(atPath: fileURL.path) {
      do {
        try defaultPrompt.write(to: fileURL, atomically: true, encoding: .utf8)
      } catch let error as NSError {
        Self.logger.error(
          "Failed to write default prompt to file: \(error.localizedDescription, privacy: .public)"
        )
      }
      return defaultPrompt
    }

    // If the file exists, read its contents; fall back to default on failure or empty prompt.
    do {
      let contents = try String(contentsOf: fileURL, encoding: .utf8)
      let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? defaultPrompt : contents
    } catch let error as NSError {
      Self.logger.error(
        "Failed to read prompt from file: \(error.localizedDescription, privacy: .public)"
      )
      return defaultPrompt
    }
  }

  // MARK: - Helpers

  private func clampInterval(_ value: Double) -> Double {
    return max(Constants.minInterval, min(Constants.maxInterval, value))
  }
}
