//
//  BuzzkillApp.swift
//  Buzzkill
//
//  Main entry point for the app.
//

import AppKit
import Foundation
import OSLog
import Sparkle
import SwiftUI

extension OSLog {
  static let subsystem = Bundle.main.bundleIdentifier!
}

@main
struct BuzzkillApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

extension BuzzkillApp {
  enum Constants {
    static let name = "Buzzkill"
    static let version: String = {
      if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
        return version
      }
      return "Unknown"
    }()
    static let urlScheme = "buzzkill"
    static let descriptionMarkdown = """
      A [Skalon](https://skalon.com) project.

      Fly graphics by [Elthen's Pixel Art Shop](https://itch.io/profile/elthen). Thanks for the awesome sprite sheet!
      """
    static let overlayWindowIdentifier = NSUserInterfaceItemIdentifier("BuzzkillOverlayWindow")
  }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var overlayWindow: NSWindow?
  var statusBarController: StatusBarController?
  let updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Ensure we remain a no-dock app even under odd launch states.
    NSApp.setActivationPolicy(.accessory)
    statusBarController = StatusBarController(updater: updaterController.updater)
    setupOverlayWindow()

    // Ensure App Shortcuts are registered.
    if #available(macOS 13.0, *) {
      BuzzkillShortcuts.updateAppShortcutParameters()
    }
  }

  private func setupOverlayWindow() {
    guard let screen = NSScreen.main else {
      return
    }

    // Create overlay window.
    overlayWindow = NSWindow(
      // Use full screen frame to allow flies to render everywhere, including behind the notch.
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    overlayWindow?.identifier = BuzzkillApp.Constants.overlayWindowIdentifier
    overlayWindow?.isOpaque = false
    overlayWindow?.backgroundColor = NSColor.clear
    // Keep above other apps (including full-screen) by using status bar level.
    overlayWindow?.level = .statusBar
    // Allow clicks to pass through to other apps.
    overlayWindow?.ignoresMouseEvents = true
    overlayWindow?.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]
    overlayWindow?.isMovable = false
    overlayWindow?.isRestorable = false
    overlayWindow?.hidesOnDeactivate = false

    // Set the content view within the overlay window.
    let contentView = ClickableHostingView(rootView: OverlayContentView())
    overlayWindow?.contentView = contentView
    overlayWindow?.orderFront(nil)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  // MARK: - URL Handling

  func application(_ application: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty else {
      return
    }

    for url in urls {
      guard url.scheme?.lowercased() == BuzzkillApp.Constants.urlScheme else {
        continue
      }

      // Support forms like `buzzkill://open` or `buzzkill:open`.
      let hostOrPath =
        (url.host?.lowercased() ?? "").isEmpty ? url.path.lowercased() : url.host!.lowercased()
      if hostOrPath == "open" || hostOrPath == "/open" {
        statusBarController?.openStatusPanel()
      }
    }
  }
}
