import SwiftUI
import XCTest

@testable import Pinch

final class HermitGlyphTests: XCTestCase {
  private let grid = CGRect(x: 0, y: 0, width: 18, height: 18)

  func testEyesStandAboveTheShellAtRest() {
    let glyph = HermitGlyph().path(in: grid)

    XCTAssertEqual(glyph.boundingRect.minY, 0.4, accuracy: 0.01)
    // Open space beside the eyes stays empty.
    XCTAssertFalse(glyph.contains(CGPoint(x: 0.5, y: 0.5)))
  }

  func testFullyRetractedEyesDisappearIntoTheShell() {
    let bounds = HermitGlyph(retraction: 1).path(in: grid).boundingRect

    XCTAssertEqual(bounds.minY, 6.6, accuracy: 0.01)
    XCTAssertEqual(bounds.maxY, HermitGlyph().path(in: grid).boundingRect.maxY, accuracy: 0.01)
  }
}
