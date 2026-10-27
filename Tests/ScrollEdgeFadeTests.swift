import SwiftUI
import XCTest

@testable import Pinch

final class ScrollEdgeFadeTests: XCTestCase {
  private let contentSize = CGSize(width: 440, height: 336)
  private let containerSize = CGSize(width: 440, height: 180)

  private func fadedEdges(atOffset y: CGFloat) -> Edge.Set {
    ScrollEdgeFade.fadedEdges(
      for: ScrollGeometry(
        contentOffset: CGPoint(x: 0, y: y),
        contentSize: contentSize,
        contentInsets: EdgeInsets(),
        containerSize: containerSize
      )
    )
  }

  func testFadesOnlyTheBottomAtTheTop() {
    XCTAssertEqual(fadedEdges(atOffset: 0), .bottom)
  }

  func testFadesBothEdgesMidway() {
    XCTAssertEqual(fadedEdges(atOffset: 80), [.top, .bottom])
  }

  func testFadesOnlyTheTopAtTheEnd() {
    XCTAssertEqual(fadedEdges(atOffset: 156), .top)
  }

  // Offsets observed after scrolling a real popover: AppKit settles a hair short of each end.
  func testIgnoresFloatingPointDriftAtEitherEnd() {
    XCTAssertEqual(fadedEdges(atOffset: 155.99999999999784), .top)
    XCTAssertEqual(fadedEdges(atOffset: 3e-12), .bottom)
  }

  func testDoesNotFadeContentThatFits() {
    let geometry = ScrollGeometry(
      contentOffset: .zero,
      contentSize: CGSize(width: 440, height: 120),
      contentInsets: EdgeInsets(),
      containerSize: containerSize
    )

    XCTAssertEqual(ScrollEdgeFade.fadedEdges(for: geometry), [])
  }
}
