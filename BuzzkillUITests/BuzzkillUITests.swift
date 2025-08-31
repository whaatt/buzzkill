//
//  BuzzkillUITests.swift
//  BuzzkillUITests
//
//  Created by Sanjay Kannan on 7/6/25.
//

import XCTest

final class BuzzkillUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    // Put teardown code here.
  }

  @MainActor
  func testExample() throws {
    let app = XCUIApplication()
    app.launch()
  }

  @MainActor
  func testLaunchPerformance() throws {
    // This measures how long it takes to launch your application.
    measure(metrics: [XCTApplicationLaunchMetric()]) {
      XCUIApplication().launch()
    }
  }
}
