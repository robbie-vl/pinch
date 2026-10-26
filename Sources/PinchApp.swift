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

    Settings {
      SettingsView()
    }
  }
}
