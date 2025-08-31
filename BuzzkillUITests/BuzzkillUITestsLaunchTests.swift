//
//  BuzzkillUITestsLaunchTests.swift
//  BuzzkillUITests
//
//  Created by Sanjay Kannan on 7/6/25.
//

import XCTest

final class BuzzkillUITestsLaunchTests: XCTestCase {
  override class var runsForEachTargetApplicationUIConfiguration: Bool {
    true
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunch() throws {
    let app = XCUIApplication()
    app.launch()

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Launch Screen"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
