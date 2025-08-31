//
//  FlySprite.swift
//  Buzzkill
//
//  Fly sprite sheet handling.
//

import AppKit
import Foundation
import OSLog

// MARK: - Fly Sprite Loader

class FlySprite {
  static let shared = FlySprite()
  static let logger = Logger(
    subsystem: OSLog.subsystem,
    category: String(describing: FlySprite.self)
  )

  private var spriteCache: [String: NSImage] = [:]
  private var spriteSheet: NSImage?

  private init() {
    loadSpriteSheet()
  }

  private func loadSpriteSheet() {
    spriteSheet = NSImage(named: "Fly")
    if spriteSheet == nil {
      Self.logger.critical("Could not load Fly sprites from asset catalog")
      fatalError()
    }
  }

  func getFlySprite(frame: Int) -> NSImage {
    let cacheKey = "fly_\(frame)"
    if let cached = spriteCache[cacheKey] {
      return cached
    }

    let sprite = extractFlySprite(frame: frame)
    spriteCache[cacheKey] = sprite
    return sprite
  }

  private func extractFlySprite(frame: Int) -> NSImage {
    guard let spriteSheet = spriteSheet else {
      Self.logger.critical("Sprite sheet is not loaded")
      fatalError()
    }

    let spriteSize = CGSize(width: 32, height: 32)
    let extractedSprite = NSImage(size: spriteSize)
    extractedSprite.lockFocus()

    // Calculate sprite position in the sheet; want row 1 from top-left, so use row 5 from
    // bottom-left.
    let frameX = CGFloat(frame) * 32
    let frameY = CGFloat(4) * 32  // Row 1 from top-left = Row 5 from bottom-left (index 4).
    let sourceRect = CGRect(x: frameX, y: frameY, width: 32, height: 32)
    let destRect = CGRect(x: 0, y: 0, width: 32, height: 32)

    // Draw the sprite portion from the sheet.
    spriteSheet.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)

    extractedSprite.unlockFocus()
    return extractedSprite
  }
}
