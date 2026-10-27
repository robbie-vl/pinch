import AppKit
import SwiftUI

@main
struct PinchApp: App {
  @State private var store = ContainerStore()

  private static let menuBarIcon = HermitGlyph.menuBarImage()

  init() {
    // `swift run` has no app bundle, so mirror the packaged app's LSUIElement behavior in development.
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(store: store)
    } label: {
      Image(nsImage: Self.menuBarIcon)
    }
    .menuBarExtraStyle(.window)

    WindowGroup(for: ContainerLogsTarget.self) { $target in
      if let target {
        ContainerLogsView(target: target)
      }
    }
    .defaultSize(width: 760, height: 480)
    // Opened from a container row only: not at launch, not from File ▸ New Window (⌘N), which
    // would open one with no container, and not restored for containers that may be gone by
    // the next launch.
    .defaultLaunchBehavior(.suppressed)
    .commandsRemoved()
    .restorationBehavior(.disabled)

    Settings {
      SettingsView()
    }
  }
}
