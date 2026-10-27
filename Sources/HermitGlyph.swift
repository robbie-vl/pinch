import AppKit
import SwiftUI

/// The app's mascot: a hermit crab that has moved into a shipping container.
///
/// Drawn on an 18-point grid so the menu bar glyph lands on whole points. The full-colour
/// app icon (`Resources/AppIcon.icon`) uses the same geometry, split into layers.
struct HermitGlyph: Shape {
  /// How far the eyes have drawn back into the shell, from 0 (out) to 1 (hidden).
  var retraction: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let shell = Path(
      roundedRect: CGRect(x: 1, y: Self.shellTop, width: 16, height: 8.8), cornerRadius: 1.4
    )
    .subtracting(Self.ribs)
    let eyes = Self.circle(x: 5.1, y: 3.15, radius: 1.85)
      .union(Self.circle(x: 12.6, y: 2.25, radius: 1.85))
      .subtracting(
        Self.circle(x: 5.75, y: 3.15, radius: 0.8)
          .union(Self.circle(x: 13.25, y: 2.25, radius: 0.8)))
    let stalks = Self.lines([(6.3, 7, 5.3, 4.2), (11.7, 7, 12.4, 3.4)], width: 1.4)
    // Cut off at the shell's top edge, so retracting eyes sink into the shell rather than
    // sliding down across it. Fully out, the cut only trims stalk the shell already covers.
    // Subtracting rather than intersecting: CoreGraphics returns the whole clip rectangle when
    // intersecting at zero offset, which would draw the resting glyph as a solid block.
    let lookout = eyes.union(stalks)
      .offsetBy(dx: 0, dy: retraction * Self.eyeReach)
      .subtracting(Path(CGRect(x: 0, y: Self.shellTop, width: 18, height: 18 - Self.shellTop)))
    let legs = Self.lines(
      [(4, 15.6, 3.1, 17.3), (7, 15.6, 6.6, 17.3), (11, 15.6, 11.4, 17.3), (14, 15.6, 14.9, 17.3)],
      width: 1.3)

    let scale = min(rect.width, rect.height) / 18
    let transform = CGAffineTransform(
      translationX: rect.midX - 9 * scale,
      y: rect.midY - 9 * scale
    )
    .scaledBy(x: scale, y: scale)
    return shell.union(lookout).union(legs).applying(transform)
  }

  /// A template image so the menu bar tints it for light, dark, and highlighted states.
  static func menuBarImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else {
        return false
      }
      context.addPath(HermitGlyph().path(in: rect).cgPath)
      context.fillPath()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Pinch"
    return image
  }

  private static let shellTop: CGFloat = 6.6

  /// From the top of the higher eye down to the shell's top edge.
  private static let eyeReach: CGFloat = shellTop - 0.4

  private static let ribs = [4.1, 7.03, 9.97, 12.9].reduce(into: Path()) { path, x in
    path.addRect(CGRect(x: x, y: 8.3, width: 1, height: 5.4))
  }

  private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
  }

  private static func lines(
    _ segments: [(CGFloat, CGFloat, CGFloat, CGFloat)],
    width: CGFloat
  ) -> Path {
    var path = Path()
    for (x1, y1, x2, y2) in segments {
      path.move(to: CGPoint(x: x1, y: y1))
      path.addLine(to: CGPoint(x: x2, y: y2))
    }
    return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
  }
}
